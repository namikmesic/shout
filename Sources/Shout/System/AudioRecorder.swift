import AVFoundation
import CoreAudio
import AudioToolbox
import ShoutKit

/// Captures microphone audio with AVAudioEngine and converts it to 16 kHz mono Float32 on the fly.
final class AudioRecorder: @unchecked Sendable {
    struct InputDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isBuiltIn: Bool
        let isBluetooth: Bool
    }

    enum RecorderError: LocalizedError {
        case noInput, deviceUnavailable, startFailed(String)
        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone is available."
            case .deviceUnavailable: "The selected microphone is not connected."
            case .startFailed(let s): "Could not start the microphone: \(s)"
            }
        }
    }

    /// Called on the main thread ~25 times per second with a 0...1 level.
    var onLevel: ((Float) -> Void)?
    /// Called on the main thread if the microphone delivers only digital silence for several seconds, or
    /// no audio at all even after a restart.
    var onDeadMicrophone: (() -> Void)?

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastBufferAt = Date()
    private var lastLevelTime = Date.distantPast
    private var zeroRunSamples = 0
    /// Quietest recent level in dB: the meter is relative to the room, not absolute.
    private var noiseFloorDB: Float = -50
    private var deadReported = false      // guarded by `lock`: set from the tap thread and the main thread
    /// Bumped by `start()` and `stop()` (under `lock`): a tap block still running from an earlier
    /// recording drops its buffer instead of appending to the next one.
    private var generation = 0
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private(set) var isRecording = false
    private(set) var startedAt = Date()
    private var deviceUID: String?
    private var observer: NSObjectProtocol?
    private var watchdog: Timer?
    /// Engine restarts in this recording (configuration changes, no audio); after `maxRestarts` the
    /// microphone is reported dead.
    private var restarts = 0
    private static let maxRestarts = 3
    /// A configuration-change restart waiting for the burst of changes to settle.
    private var pendingRestart: DispatchWorkItem?
    /// How long a start waits for the meeting microphone to let go of the device.
    static let releaseWait: TimeInterval = 0.3

    var duration: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(samples.count) / 16_000 }

    /// Call on the main thread. Waits (at most `releaseWait`) while the Scribe is still releasing its
    /// voice-processing microphone: starting under that teardown would be reconfigured at once and cost
    /// the first words.
    func start(deviceUID: String?) throws {
        if isRecording { _ = stop() }
        if !MicrophoneRelease.shared.wait(timeout: Self.releaseWait) {
            NSLog("Shout: the meeting microphone is still being released; starting dictation anyway")
        }
        lock.lock()
        samples = []; samples.reserveCapacity(16_000 * 60); lastBufferAt = Date()
        deadReported = false; generation += 1
        lock.unlock()
        zeroRunSamples = 0; noiseFloorDB = -50
        self.deviceUID = deviceUID
        restarts = 0
        try startEngine()
        startedAt = Date()
        isRecording = true
        // A device that reconfigures (the meeting microphone's voice processing being released, a headset
        // switching profile) stops the engine; one that never delivers is restarted once too.
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkAlive() }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let uid = deviceUID {
            guard let id = Self.deviceID(forUID: uid) else { throw RecorderError.deviceUnavailable }
            var dev = id
            // Without the unit the engine would silently record from the default microphone instead.
            guard let unit = input.audioUnit else { throw RecorderError.deviceUnavailable }
            let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { throw RecorderError.deviceUnavailable }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        guard let conv = AVAudioConverter(from: format, to: target) else {
            throw RecorderError.startFailed("unsupported input format \(format)")
        }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal

        let gen = lock.withLock { generation }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer, converter: conv, generation: gen)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.startFailed(error.localizedDescription)
        }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in self?.configurationChanged() }
    }

    private func stopEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// AVAudioEngine stops itself on a configuration change: start it again, keeping what was recorded so
    /// far. Changes come in bursts (a voice-processing unit released elsewhere: its teardown, then the
    /// device's format restored), so the restart waits for the burst to settle and runs once.
    private func configurationChanged() {
        guard isRecording else { return }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestart = nil
            guard self.isRecording, self.engine.map({ !$0.isRunning }) ?? true else { return }
            self.restartEngine("configuration change")
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func checkAlive() {
        guard isRecording, pendingRestart == nil else { return }
        let silentFor = Date().timeIntervalSince(lock.withLock { lastBufferAt })
        guard silentFor > 1 else { return }
        restartEngine("no audio for 1 s")
    }

    /// Restarts the engine, up to `maxRestarts` times per recording; after that the microphone is
    /// reported dead.
    private func restartEngine(_ reason: String) {
        guard restarts < Self.maxRestarts else {
            reportDead()
            return
        }
        restarts += 1
        NSLog("Shout: restarting the dictation microphone (\(reason), \(restarts) of \(Self.maxRestarts))")
        stopEngine()
        lock.withLock { lastBufferAt = Date() }
        do { try startEngine() } catch {
            NSLog("Shout: dictation microphone restart failed: \(error.localizedDescription)")
            if restarts >= Self.maxRestarts { reportDead() }
        }
    }

    private func reportDead() {
        // Restarts are spent: the watchdog has nothing left to do. The engine and the samples stay for
        // the caller's `stop()`.
        watchdog?.invalidate()
        watchdog = nil
        let first = lock.withLock { () -> Bool in defer { deadReported = true }; return !deadReported }
        if first { onDeadMicrophone?() }
    }

    /// Stops recording and returns the captured 16 kHz samples.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        watchdog?.invalidate()
        watchdog = nil
        pendingRestart?.cancel()
        pendingRestart = nil
        stopEngine()
        isRecording = false
        lock.lock(); defer { lock.unlock() }
        generation += 1
        let out = samples
        samples = []
        return out
    }

    func cancel() { _ = stop() }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, generation gen: Int) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
        let chunk = UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        samples.append(contentsOf: chunk); lastBufferAt = Date()
        lock.unlock()

        // Level metering.
        var sum: Float = 0
        var peak: Float = 0
        for s in chunk { sum += s * s; peak = max(peak, abs(s)) }
        let rms = sqrt(sum / Float(chunk.count))
        if peak == 0 { zeroRunSamples += chunk.count } else { zeroRunSamples = 0 }
        if zeroRunSamples > 16_000 * 4,
           lock.withLock({ () -> Bool in defer { deadReported = true }; return !deadReported }) {
            DispatchQueue.main.async { [weak self] in self?.onDeadMicrophone?() }
        }
        // Track the noise floor: follow quieter levels quickly, louder ones slowly (~1.5 dB/s).
        let db = 20 * log10(max(rms, 1e-7))
        let chunkSeconds = Float(chunk.count) / 16_000
        if db < noiseFloorDB { noiseFloorDB += (db - noiseFloorDB) * 0.3 }
        else { noiseFloorDB += min(db - noiseFloorDB, 1.5 * chunkSeconds) }
        noiseFloorDB = max(-70, min(-25, noiseFloorDB))
        let now = Date()
        if now.timeIntervalSince(lastLevelTime) > 0.03 {
            lastLevelTime = now
            let level = max(0, min(1, (db - noiseFloorDB - 4) / 24))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }
    }

    // MARK: Devices

    static func inputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            let transport = transportType(id)
            return InputDevice(id: id, uid: uid, name: name,
                               isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                               isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }

    static func defaultInputName() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return stringProperty(id, kAudioObjectPropertyName)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }
}

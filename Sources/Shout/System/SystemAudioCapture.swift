import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import ShoutKit

/// Captures everything the Mac plays (the other people on a call) with a Core Audio process tap:
/// a private mono global tap that excludes Shout's own sounds, read through a private aggregate device
/// that holds only the tap. Audio is delivered as 16 kHz mono Float32 with the host time of its first sample.
///
/// The setup follows Chromium's open-source tap capture: tap-only aggregate, `tapautostart` off, the aggregate's sample
/// rate pinned, a permission probe on the tap, property listeners on a private queue, and a rebuild when
/// the device dies or its rate changes. An aggregate clocked by the output device is kept as a last resort,
/// and only for an output device without a microphone that isn't Bluetooth: adding a headset to the
/// aggregate would open its microphone and switch Bluetooth headsets to call quality.
///
/// All building and teardown run on a private serial queue: creating the IOProc the first time can
/// block while macOS shows the "System Audio Recording" prompt, so that never happens on the main thread
/// (and `start()` asks for the permission first). The IOProc runs on the HAL's real-time thread and only
/// copies into a lock-free queue; a second queue drains it every 10 ms, converts and delivers.
///
/// A Core Audio service restart (coreaudiod crashed or was restarted) tears everything down and rebuilds
/// it after a 1 s settle; that is not counted as a stall.
@available(macOS 14.4, *)
final class SystemAudioCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case tap(OSStatus), aggregate(OSStatus), format, ioProc(OSStatus), start(OSStatus), permissionDenied
        var errorDescription: String? {
            switch self {
            case .tap(let s): "Could not create the system audio tap (error \(s))."
            case .aggregate(let s): "Could not create the capture device (error \(s))."
            case .format: "The system audio format is not supported."
            case .ioProc(let s), .start(let s): "Could not start system audio capture (error \(s))."
            case .permissionDenied: "System Audio Recording is turned off for Shout."
            }
        }
    }

    /// Why a rebuild is asked for; it decides the device layout (see `restart(_:completion:)`).
    enum RestartReason {
        /// No IO callbacks for a while.
        case stall
        /// Callbacks arrive but only with silence, a failed build, a permission granted late, a device
        /// change, a service restart.
        case other
    }

    private enum Layout { case tapOnly, withOutputDevice }

    /// Called on a private serial queue. Set before `start()`.
    var onSamples: (([Float], Double) -> Void)?
    /// Called on the same queue just before the first samples of every rebuild (including the ones the
    /// capture does by itself), so the receiver can place them exactly (`MeetingTrack.realign`). Set
    /// before `start()`.
    var onDiscontinuity: (() -> Void)?

    private let control = DispatchQueue(label: "shout.scribe.system-control", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "shout.scribe.system-listeners")
    private let convertQueue = DispatchQueue(label: "shout.scribe.system-convert", qos: .userInitiated)

    // Owned by `control`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var layout: Layout = .tapOnly
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var serviceListener: AudioObjectPropertyListenerBlock?
    private var running = false
    private var generation = 0
    /// Stall rebuilds in a row that each got no callback at all.
    private var consecutiveStalls = 0

    // Owned by `convertQueue`.
    private let handoff = RealtimeAudioQueue()
    private var drainTimer: DispatchSourceTimer?
    private var converter: AVAudioConverter?
    private var deliveredGeneration = -1
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    // Shared with the IO path, the listeners and the main thread.
    private let state = NSLock()
    private var sampleRate: Double = 0
    private var outputUID: String?
    private var _lastCallback: Double = 0
    private var _failure: Error?
    private var _lastRestart = Date.distantPast
    private var _builtAt = Date()
    private var _building = false
    private var _started = false
    private var _serviceRestartedAt = Date.distantPast
    private var _usesOutputDevice = false
    /// The build whose callbacks count for `lastCallbackTime`.
    private var _generation = 0
    /// Set by `stop()`: a start still waiting on the permission prompt must not build afterwards, and
    /// nothing is delivered any more.
    private var cancelled = false
    private var drops = AudioDropCounter()

    /// Last build error; nil while capture is up.
    var failure: Error? { state.withLock { _failure } }
    /// Host time of the latest audio from the IO callback (0 = none since the last build).
    var lastCallbackTime: Double { state.withLock { _lastCallback } }
    var secondsSinceRestart: TimeInterval { Date().timeIntervalSince(state.withLock { _lastRestart }) }
    /// Time since the latest build began (or, once it finished, since it finished).
    var secondsSinceBuild: TimeInterval { Date().timeIntervalSince(state.withLock { _builtAt }) }
    /// A build or rebuild is in progress (the first one can wait on the permission prompt).
    var isBuilding: Bool { state.withLock { _building } }
    /// `start()` has finished its first build attempt.
    var hasStarted: Bool { state.withLock { _started } }
    /// The current aggregate is clocked by the output device (the fallback layout).
    var usesOutputDeviceClock: Bool { state.withLock { _usesOutputDevice } }
    var secondsSinceServiceRestart: TimeInterval { Date().timeIntervalSince(state.withLock { _serviceRestartedAt }) }
    /// Audio lost because delivery fell behind the IO thread (`RealtimeAudioQueue` was full).
    var droppedSeconds: Double { state.withLock { drops.totalSeconds } }

    /// The capture is up but no IO callback has arrived for `seconds` (callbacks arrive even while
    /// nothing plays). Never true while building, before the first build finished, or within 10 s of a
    /// Core Audio service restart (that rebuild is the capture's own).
    func isStalled(after seconds: Double = 5) -> Bool {
        state.withLock {
            guard _started, !_building, _failure == nil,
                  Date().timeIntervalSince(_serviceRestartedAt) > 10 else { return false }
            if _lastCallback > 0 { return MeetingClock.now() - _lastCallback > seconds }
            return Date().timeIntervalSince(_builtAt) > seconds
        }
    }

    /// Asks for the permission if it is undecided, then builds the capture off the main thread.
    func start() async throws {
        if SystemAudioPermission.status() == .notDetermined { _ = await SystemAudioPermission.request() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            control.async { [self] in
                guard !state.withLock({ cancelled }) else { cont.resume(throwing: CancellationError()); return }
                running = true
                addServiceListener()
                startDraining()
                do { try build(); setFailure(nil); state.withLock { _started = true }; cont.resume() }
                catch { setFailure(error); state.withLock { _started = true }; cont.resume(throwing: error) }
            }
        }
    }

    /// Returns at once: nothing more is delivered (a chunk already being handed on may finish), and the
    /// tap and aggregate are torn down on the private queue. Waiting here would block the caller (the main
    /// thread) behind a build, which can sit on the permission prompt.
    func stop() {
        state.withLock { cancelled = true }
        control.async { [self] in
            running = false
            removeServiceListener()
            teardown()
            convertQueue.async { [self] in stopDraining() }
        }
    }

    deinit {
        // Normally stopped already; a capture dropped while still running is torn down here.
        if procID != nil || aggregateID != kAudioObjectUnknown || tapID != kAudioObjectUnknown { teardown() }
        removeServiceListener()
        drainTimer?.cancel()
    }

    /// Rebuilds the capture in the background. `switchLayout: true` means the capture delivers no
    /// callbacks (a stall): see `restart(_:completion:)`.
    func restart(switchLayout: Bool = false, completion: (@Sendable (Bool) -> Void)? = nil) {
        restart(switchLayout ? .stall : .other, completion: completion)
    }

    /// Rebuilds the capture in the background.
    /// - `.stall`: the same layout first; the output-device layout only after two stall rebuilds in a row
    ///   that got no callback at all, and only for an output device without a microphone that isn't
    ///   Bluetooth.
    /// - `.other`: tap-only again, so a switch to the output-device layout never sticks.
    func restart(_ reason: RestartReason, completion: (@Sendable (Bool) -> Void)? = nil) {
        state.withLock { _lastRestart = Date() }
        control.async { [self] in
            guard running else { completion?(false); return }
            let heardSinceBuild = state.withLock { _lastCallback > 0 }
            teardown()
            switch reason {
            case .stall:
                consecutiveStalls = heardSinceBuild ? 1 : consecutiveStalls + 1
                if consecutiveStalls > 2, layout == .tapOnly, Self.outputDeviceCanClock() {
                    NSLog("Shout: the system audio tap delivers nothing; clocking it from the output device")
                    layout = .withOutputDevice
                    consecutiveStalls = 0
                }
            case .other:
                consecutiveStalls = 0
                layout = .tapOnly
            }
            do { try build(); setFailure(nil); completion?(true) }
            catch {
                setFailure(error)
                NSLog("Shout: system audio restart failed: \(error.localizedDescription)")
                completion?(false)
            }
        }
    }

    private func setFailure(_ e: Error?) { state.withLock { _failure = e } }

    // MARK: Build / teardown (on `control`)

    private func build() throws {
        state.withLock { _building = true; _builtAt = Date() }
        defer { state.withLock { _building = false; _usesOutputDevice = layout == .withOutputDevice } }
        do {
            try buildOnce()
        } catch CaptureError.permissionDenied {
            throw CaptureError.permissionDenied
        } catch where layout == .tapOnly && Self.outputDeviceCanClock() {
            NSLog("Shout: tap-only capture failed (\(error.localizedDescription)); using the output device as clock")
            teardown()
            layout = .withOutputDevice
            do { try buildOnce() } catch {
                // Tap-only stays the layout to retry: the fallback is not worth keeping either.
                layout = .tapOnly
                throw error
            }
        }
    }

    private func buildOnce() throws {
        generation += 1
        let generation = self.generation
        // Exclude Shout itself (its sounds). Our process object exists once we use audio; the meeting
        // microphone is started first for that reason.
        var exclude: [AudioObjectID] = []
        if let me = Self.processObject(pid: getpid()) { exclude.append(me) }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: exclude)
        description.uuid = UUID()
        description.name = "Shout Scribe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CaptureError.tap(status) }
        tapID = tap
        guard let tapFormat = Self.tapFormat(tap) else { teardown(); throw CaptureError.format }

        do { try createAggregate(tapUID: description.uuid.uuidString) } catch { teardown(); throw error }

        // Pin the aggregate's rate to the tap's and read it back: on macOS 15+ the tap is resampled to
        // the aggregate's rate, and that is the rate the IOProc delivers.
        var rate = tapFormat.sampleRate
        var rateAddr = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectSetPropertyData(aggregateID, &rateAddr, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
        var actual: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(aggregateID, &rateAddr, 0, nil, &size, &actual) == noErr, actual > 0 { rate = actual }
        guard rate > 0 else { teardown(); throw CaptureError.format }
        state.withLock { sampleRate = rate; _lastCallback = 0; _generation = generation }

        // Called directly on the HAL's IO thread (no queue): copy into the hand-off queue and return.
        let queue = handoff
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { _, input, inputTime, _, _ in
            let time = inputTime.pointee
            let host = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : mach_absolute_time()
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // The tap's stream follows any input streams of a clock device, so it is the last buffer. A mono
            // tap delivers one channel; anything else (a device mid-switch) is dropped rather than misread,
            // but still counts as a callback.
            guard let buffer = buffers.last, buffer.mNumberChannels == 1, let data = buffer.mData else {
                queue.push(nil, count: 0, hostTime: host, sampleRate: rate, generation: generation)
                return
            }
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            queue.push(data.assumingMemoryBound(to: Float.self), count: frames, hostTime: host, sampleRate: rate, generation: generation)
        }
        guard status == noErr, let proc else { teardown(); throw CaptureError.ioProc(status) }
        procID = proc

        // Permission probe (as Chromium does): reading the tap's description and writing it back fails
        // when System Audio Recording is denied, so denial is known up front instead of from silence.
        var descAddr = Self.address(kAudioTapPropertyDescription)
        var desc: Unmanaged<CATapDescription>?
        var descSize = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let read = AudioObjectGetPropertyData(tap, &descAddr, 0, nil, &descSize, &desc)
        var write = read
        if read == noErr, let desc {
            var pointer: Unmanaged<CATapDescription>? = desc
            write = AudioObjectSetPropertyData(tap, &descAddr, 0, nil, descSize, &pointer)
            desc.release()
        }
        if read != noErr || write != noErr { teardown(); throw CaptureError.permissionDenied }

        addListeners()
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else { teardown(); throw CaptureError.start(status) }
        state.withLock { _builtAt = Date() }
    }

    private func createAggregate(tapUID: String) throws {
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Shout Scribe",
            kAudioAggregateDeviceUIDKey: "com.namikmesic.shout.scribe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // With auto-start, AudioDeviceStart blocks until some app plays audio.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        let output = Self.defaultOutputUID()
        state.withLock { outputUID = output }
        if layout == .withOutputDevice {
            // Checked again here: the default output may have changed since the layout was chosen.
            guard let output, Self.outputDeviceCanClock() else { throw CaptureError.aggregate(kAudioHardwareIllegalOperationError) }
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr, agg != kAudioObjectUnknown else { throw CaptureError.aggregate(status) }
        aggregateID = agg
    }

    /// Device death and rate changes rebuild the capture. The default-output listener only matters when
    /// the aggregate is clocked by the output device (a global tap follows every output device anyway).
    private func addListeners() {
        func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
            var addr = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            if AudioObjectAddPropertyListenerBlock(object, &addr, listenerQueue, block) == noErr {
                listeners.append((object, addr, block))
            }
        }
        let agg = aggregateID, tap = tapID
        listen(agg, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            var alive: UInt32 = 1
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = Self.address(kAudioDevicePropertyDeviceIsAlive)
            if AudioObjectGetPropertyData(agg, &addr, 0, nil, &size, &alive) == noErr, alive == 0 { self?.restart(.other) }
        }
        listen(agg, kAudioDevicePropertyNominalSampleRate) { [weak self] in
            guard let self else { return }
            var rate: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
            guard AudioObjectGetPropertyData(agg, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return }
            if rate != self.state.withLock({ self.sampleRate }) { self.restart(.other) }
        }
        // macOS 14 does not resample the tap to the aggregate's rate (fixed in 15, per Chromium): a tap
        // whose rate changes (a Bluetooth profile switch) needs a rebuild at its new rate.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14 {
            listen(tap, kAudioTapPropertyFormat) { [weak self] in
                guard let self, let format = Self.tapFormat(tap) else { return }
                if format.sampleRate != self.state.withLock({ self.sampleRate }) { self.restart(.other) }
            }
        }
        if layout == .withOutputDevice {
            listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                guard let self, Self.defaultOutputUID() != self.state.withLock({ self.outputUID }) else { return }
                self.restart(.other)
            }
        }
    }

    /// Lives for the whole capture (not per build). After a service restart every object and listener is
    /// gone (AudioHardware.h: "must be re-established"), so the capture is rebuilt from scratch, and this
    /// listener itself is registered again.
    private func addServiceListener() {
        guard serviceListener == nil else { return }
        var addr = Self.address(kAudioHardwarePropertyServiceRestarted)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.serviceRestarted() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block) == noErr {
            serviceListener = block
        }
    }

    private func removeServiceListener() {
        guard let block = serviceListener else { return }
        var addr = Self.address(kAudioHardwarePropertyServiceRestarted)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block)
        serviceListener = nil
    }

    private func serviceRestarted() {
        NSLog("Shout: Core Audio restarted; rebuilding system audio capture")
        state.withLock { _serviceRestartedAt = Date(); _lastRestart = Date() }
        control.asyncAfter(deadline: .now() + 1) { [self] in
            guard running else { return }
            state.withLock { _serviceRestartedAt = Date() }
            removeServiceListener()
            addServiceListener()
            teardown()
            consecutiveStalls = 0
            layout = .tapOnly
            do { try build(); setFailure(nil) } catch {
                // The controller's watchdog retries a failed capture.
                setFailure(error)
                NSLog("Shout: system audio rebuild after the Core Audio restart failed: \(error.localizedDescription)")
            }
        }
    }

    private func teardown() {
        for (object, address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(object, &addr, listenerQueue, block)
        }
        listeners = []
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Delivery (on `convertQueue`)

    private func startDraining() {
        convertQueue.async { [self] in
            guard drainTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: convertQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.drain() }
            timer.resume()
            drainTimer = timer
        }
    }

    private func stopDraining() {
        drainTimer?.cancel()
        drainTimer = nil
        handoff.drain { _ in }
    }

    private func drain() {
        handoff.drain { chunk in
            let time = chunk.time
            // Checked per chunk: `stop()` doesn't wait for a drain in progress.
            let (stopped, dropEpisode) = state.withLock { () -> (Bool, Bool) in
                guard !cancelled else { return (true, false) }
                if chunk.generation == _generation { _lastCallback = max(_lastCallback, time) }
                return (false, drops.record(frames: chunk.dropped, sampleRate: chunk.sampleRate, at: MeetingClock.now()))
            }
            guard !stopped else { return }
            if dropEpisode {
                NSLog("Shout: system audio lost \(Int(Double(chunk.dropped) / chunk.sampleRate * 1000)) ms: delivery fell behind")
            }
            guard chunk.samples.count > 0, chunk.sampleRate > 0 else { return }
            if chunk.generation != deliveredGeneration {
                deliveredGeneration = chunk.generation
                converter = nil
                onDiscontinuity?()
            } else if chunk.dropped > 0 {
                // Audio was lost just before this chunk: it goes to its own time, not right after the last.
                onDiscontinuity?()
            }
            if converter?.inputFormat.sampleRate != chunk.sampleRate {
                converter = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate, channels: 1)
                    .flatMap { AVAudioConverter(from: $0, to: target) }
                converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            }
            guard let converter, let out = MeetingMicCapture.convert(chunk.samples, converter: converter, target: target) else { return }
            onSamples?(out, time)
        }
    }

    // MARK: Helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func tapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
        guard tap != kAudioObjectUnknown else { return nil }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = address(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    static func defaultOutputUID() -> String? {
        defaultOutputDevice().flatMap(VoiceProcessingInput.deviceUID)
    }

    /// Whether the default output device may clock the fallback aggregate: putting a device into the
    /// aggregate opens all its streams, so one with a microphone (a headset) would start recording and a
    /// Bluetooth device would switch to its call profile (narrowband audio for the whole call).
    static func outputDeviceCanClock() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = address(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return false }
        var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr else { return false }
        return bytes == 0
    }

    /// The oracle for dead-tap detection (`SystemAudioLiveness`): whether a process other than Shout is
    /// playing audio, from Core Audio's per-process "is running output" flag. With the recorded `call`,
    /// only its own processes count when any of them uses audio (`PlaybackOracle`): another app's idle
    /// output says nothing about whether the call can be heard.
    static func isOtherAudioPlaying(call: DetectedCall? = nil) -> Bool {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return false }
        let me = getpid()
        var processes: [PlaybackOracle.Process] = []
        for object in objects {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &pidAddr, 0, nil, &pidSize, &pid) == noErr, pid != me else { continue }
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = address(kAudioProcessPropertyIsRunningOutput)
            let isRunning = AudioObjectGetPropertyData(object, &runAddr, 0, nil, &runSize, &running) == noErr && running != 0
            // Without a call, any process will do: no need to ask who it is.
            guard call != nil else {
                if isRunning { return true }
                continue
            }
            processes.append(PlaybackOracle.Process(pid: pid, parentPID: parentPID(pid), bundleID: processBundleID(object),
                                                    runningOutput: isRunning))
        }
        return PlaybackOracle.othersPlaying(processes, excluding: me, call: call)
    }

    private static func processBundleID(_ object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        let id = value.takeRetainedValue() as String
        return id.isEmpty ? nil : id
    }

    private static func parentPID(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}

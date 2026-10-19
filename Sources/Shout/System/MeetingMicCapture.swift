import AVFoundation
import Accelerate
import CoreAudio
import ShoutKit

/// The Scribe's microphone: always the system default input, with Apple's voice processing
/// (echo cancellation, noise suppression) so the call coming out of the speakers is not credited
/// to "You". Separate from the dictation recorder, which keeps the raw signal and the user's chosen mic.
/// Delivers 16 kHz mono Float32 with the host time of the first sample.
///
/// Threading: `start`/`stop` return at once. Bringing the voice-processing unit up or down (hundreds of
/// milliseconds) happens on a private serial queue, and the outcome comes back through `onRestart` on the
/// main thread. A stop is announced on `MicrophoneRelease.shared` until the unit is released, so the
/// dictation recorder can start after it. The audio thread only copies into a lock-free queue
/// (`RealtimeAudioQueue`); conversion and delivery run on a second private queue, and only audio from
/// units started for the current session reaches it.
///
/// Health: a watchdog restarts a capture that delivers no buffer for 4 s (a dead unit after a Core Audio
/// restart, an engine that stopped itself on a device change) and reports a stall through `onStall` when
/// two restarts don't help. A voice-processing unit that starts but delivers nothing counts as a failure
/// of voice processing on that device, so the raw microphone takes over. A Core Audio service restart
/// re-creates everything after a 1 s settle; voice processing failing while it settles is not counted.
final class MeetingMicCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInput, startFailed(String)
        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone is available."
            case .startFailed(let s): "Could not start the microphone: \(s)"
            }
        }
    }

    /// Called on a private queue. Read when `start` is called.
    var onSamples: (([Float], Double) -> Void)?
    /// Called on the same queue just before the first samples after every (re)start, and after audio was
    /// lost because delivery fell behind, so the receiver can place them exactly (`MeetingTrack.realign`).
    /// Read when `start` is called.
    var onDiscontinuity: (() -> Void)?
    /// Called on the main thread whenever a start or restart (the first one, a device change, the
    /// watchdog) has finished: nil when the microphone runs, else the error.
    var onRestart: ((Error?) -> Void)?
    /// Called on the main thread when restarts did not bring buffers back (the microphone isn't heard).
    var onStall: (() -> Void)?
    /// Called on the main thread when buffers flow again after `onStall`.
    var onRecovered: (() -> Void)?

    // Shared with the main thread and the delivery queue.
    private let state = NSLock()
    private var _isRunning = false
    private var _echoCancellation = false
    private var _diagnostics: [String] = []
    private var _buffers = 0
    private var _peak: Float = 0
    private var _lastBufferTime: Double = 0
    private var _stalled = false
    private typealias Session = (sink: ([Float], Double) -> Void, discontinuity: (() -> Void)?)
    /// The current session's receivers; nil once stopped, so late audio is dropped.
    private var session: Session?
    /// The first unit generation whose audio the session takes (`Int.max` until the session's own unit is
    /// starting): a stopped unit keeps producing until it is torn down on `micQueue`, and its last chunks
    /// must not reach the next session (a dictation's start in "You", or an old meeting in a new one).
    private var _acceptFrom = Int.max
    /// The unit now running: only its chunks count for the watchdog and the stats.
    private var _liveGeneration = 0
    private var drops = AudioDropCounter()
    /// Set by `start`/`stop` at once (the queue catches up later). Each call bumps `request`; work done on the
    /// queue for an older request publishes nothing.
    private var _wanted = false
    private var _wantsVoiceProcessing = true
    private var request = 0
    /// Voice-processing failures per input device UID: such a device records raw until `until` (a minute;
    /// 10 s for a failure while Core Audio settles after a restart, which isn't counted), and for good after
    /// three counted failures. Cleared per recording.
    private var vpFailures: [String: (count: Int, until: Date)] = [:]

    /// True from `start` until `stop` or a failed start (also while the unit is still coming up).
    var isRunning: Bool { state.withLock { _isRunning } }
    /// Whether echo cancellation is active (voice processing can be unavailable on some devices). While a
    /// start is in progress, what it is expected to be.
    var echoCancellation: Bool { state.withLock { _echoCancellation } }
    /// What happened at the last start (for diagnostics and the self-test).
    var diagnostics: [String] { state.withLock { _diagnostics } }
    /// Buffers delivered and their loudest sample since the last start, and the audio lost this recording
    /// because delivery fell behind.
    var bufferStats: (buffers: Int, peak: Float, droppedSeconds: Double) {
        state.withLock { (_buffers, _peak, drops.totalSeconds) }
    }
    /// Host time (`MeetingClock`) of the latest buffer since the last start; 0 = none yet.
    var lastBufferTime: Double { state.withLock { _lastBufferTime } }
    /// A stall was reported and has not recovered.
    var isStalled: Bool { state.withLock { _stalled } }

    // Owned by `micQueue`.
    private let micQueue = DispatchQueue(label: "shout.scribe.mic", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "shout.scribe.mic-listeners")
    private var generation = 0
    private var unit: VoiceProcessingInput?
    private var engine: AVAudioEngine?
    private var tapGate: TapGate?
    private var observer: NSObjectProtocol?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var boundInput: AudioDeviceID?
    private var boundOutput: AudioDeviceID?
    /// A restart waiting for notifications to settle; `force` skips the "did the devices change" check.
    /// `tag` identifies its timer (a forced restart replaces an unforced one with its own, longer settle).
    private var pendingRestart: (force: Bool, reason: String, tag: Int)?
    private var restartTag = 0
    /// Host time of the latest Core Audio service restart.
    private var serviceRestartedAt = -Double.infinity
    /// The outcome of the latest start that ran, and the request it ran for.
    private var lastStart: (request: Int, error: Error?) = (0, nil)
    private var watchdog = CaptureWatchdog(now: MeetingClock.now())
    private var watchdogTimer: DispatchSourceTimer?

    // Owned by `deliveryQueue`.
    private let deliveryQueue = DispatchQueue(label: "shout.scribe.mic-convert", qos: .userInitiated)
    private let handoff = RealtimeAudioQueue()
    private var drainTimer: DispatchSourceTimer?
    private var deliveredGeneration = -1
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    deinit {
        drainTimer?.cancel()
        watchdogTimer?.cancel()
    }

    /// A new recording: try voice processing again on every device, even where it failed before, and
    /// count lost audio from zero.
    func resetVoiceProcessingFailure() {
        state.withLock {
            vpFailures = [:]
            drops = AudioDropCounter()
        }
    }

    /// Starts (or restarts) the microphone without blocking: the work happens on a private queue and the
    /// outcome arrives through `onRestart`. Never throws (the signature is kept for existing callers); use
    /// `startAndWait` to wait for the outcome.
    func start(voiceProcessing: Bool) throws {
        requestStart(voiceProcessing: voiceProcessing)
    }

    /// `start`, returning once the microphone runs (or throwing why it doesn't; `CancellationError` when a
    /// later `start` or `stop` replaced this one first).
    func startAndWait(voiceProcessing: Bool) async throws {
        let r = requestStart(voiceProcessing: voiceProcessing)
        let error: Error? = await withCheckedContinuation { cont in
            micQueue.async { cont.resume(returning: self.lastStart.request == r ? self.lastStart.error : CancellationError()) }
        }
        if let error { throw error }
    }

    /// Returns the request number of this start.
    @discardableResult
    private func requestStart(voiceProcessing: Bool) -> Int {
        let sink = onSamples, discontinuity = onDiscontinuity
        let uid = Self.defaultInputUID()
        let r: Int = state.withLock {
            request += 1
            _wanted = true
            _wantsVoiceProcessing = voiceProcessing
            _isRunning = true
            _echoCancellation = voiceProcessing && !(uid.map { Self.skipsVoiceProcessing(vpFailures[$0]) } ?? false)
            session = sink.map { ($0, discontinuity) }
            _acceptFrom = .max
            return request
        }
        setDraining(true)
        micQueue.async { [self] in
            watchdog.reset(at: MeetingClock.now())
            startNow(for: r)
        }
        return r
    }

    /// Stops without blocking: no audio is delivered once this returns, and the unit is released on the
    /// private queue right after (announced on `MicrophoneRelease.shared` until then).
    func stop() {
        state.withLock {
            request += 1
            _wanted = false
            _isRunning = false
            _echoCancellation = false
            _stalled = false
            session = nil
            _acceptFrom = .max
        }
        MicrophoneRelease.shared.begin()
        micQueue.async { [self] in
            teardownNow()
            MicrophoneRelease.shared.end()
            // Only now: what the unit pushed until it was released is drained (and dropped, the session is
            // gone) rather than left to overflow the queue and count as the next session's lost audio.
            setDraining(false)
        }
    }

    /// Returns once the starts and stops asked for so far have been carried out (the voice-processing unit
    /// is up, or failed). Recording system audio waits for this: Shout's own audio process object, which
    /// the system tap excludes, exists once the microphone runs.
    func settled() async {
        await withCheckedContinuation { cont in micQueue.async { cont.resume() } }
    }

    /// `stop`, returning once the device is released (for a caller that needs it free at once).
    func stopAndWait() {
        stop()
        micQueue.sync {}
    }

    /// Starts the meeting microphone for a moment and reports what ran and whether audio arrived (self-test).
    static func probeUnit(seconds: Double = 1.5) async -> String {
        let m = MeetingMicCapture()
        m.onSamples = { _, _ in }
        do { try await m.startAndWait(voiceProcessing: true) } catch {
            m.stopAndWait()
            return "meeting microphone: start failed: \(describe(error)) | \(m.diagnostics.joined(separator: "; "))"
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        let s = m.bufferStats, echo = m.echoCancellation
        m.stopAndWait()
        return "meeting microphone (voice processing \(echo ? "on" : "unavailable")): \(s.buffers) buffers, peak \(String(format: "%.4f", s.peak)), "
            + "\(Int(s.droppedSeconds * 1000)) ms dropped | \(m.diagnostics.joined(separator: "; "))"
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    static func defaultInputUID() -> String? {
        VoiceProcessingInput.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap(VoiceProcessingInput.deviceUID)
    }

    private static func skipsVoiceProcessing(_ failure: (count: Int, until: Date)?) -> Bool {
        guard let failure else { return false }
        return failure.count >= 3 || Date() < failure.until
    }

    // MARK: Lifecycle (on micQueue)

    /// Whether the microphone should run, and the request a restart now belongs to.
    private var wanted: (Bool, request: Int, voiceProcessing: Bool) {
        state.withLock { (_wanted, request, _wantsVoiceProcessing) }
    }

    /// (Re)starts the microphone for `request` (nil: an internal restart for the current one).
    private func startNow(for request: Int? = nil) {
        teardownNow()
        let (wanted, current, wantsVoiceProcessing) = self.wanted
        guard wanted, request == nil || request == current else { return }
        let r = current
        generation += 1
        let gen = generation
        var diagnostics: [String] = []
        defer { state.withLock { _diagnostics = diagnostics } }
        state.withLock {
            _buffers = 0; _peak = 0; _lastBufferTime = 0
            _liveGeneration = gen
            // A session's first unit: what earlier units left in the queue is not its audio. (An internal
            // restart keeps the session's earlier audio.)
            if request != nil && self.request == r { _acceptFrom = gen }
        }

        let uid = Self.defaultInputUID()
        let failure = uid.flatMap { id in state.withLock { vpFailures[id] } }
        var echo = false
        if wantsVoiceProcessing && !Self.skipsVoiceProcessing(failure) {
            let vp = VoiceProcessingInput(queue: handoff, generation: gen)
            do {
                try vp.start()
                unit = vp
                echo = true
                boundInput = vp.inputDevice
                boundOutput = vp.outputDevice
                diagnostics.append("voice processing unit started: mono \(vp.sampleFormat) @ \(Int(vp.sampleRate)) Hz")
            } catch {
                // Some devices refuse voice processing; a plain microphone is better than none.
                recordVoiceProcessingFailure(uid)
                diagnostics.append("voice processing failed: \(Self.describe(error))")
                NSLog("Shout: voice processing unavailable (\(error.localizedDescription)); using the raw microphone")
                vp.stop()
            }
        } else if wantsVoiceProcessing {
            diagnostics.append("voice processing skipped: it failed on this microphone \(failure?.count ?? 0)×")
        }
        var result: Error?
        if unit == nil {
            do {
                try startEngine(diagnostics: &diagnostics)
                boundInput = VoiceProcessingInput.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
            } catch {
                diagnostics.append("raw microphone failed: \(Self.describe(error))")
                result = error
            }
        }
        lastStart = (r, result)
        if let result {
            // Down: the controller retries (it sees `isRunning` false).
            let current = state.withLock { () -> Bool in
                guard self.request == r else { return false }
                _wanted = false; _isRunning = false; _echoCancellation = false
                return true
            }
            if current {
                setDraining(false) // no 10 ms timer while down; the retry's `start` brings it back
                DispatchQueue.main.async { [weak self] in self?.onRestart?(result) }
            }
            return
        }
        // A stop or another start came in meanwhile: its own work follows on this queue.
        guard state.withLock({ () -> Bool in
            guard self.request == r else { return false }
            _echoCancellation = echo
            return true
        }) else { return }
        addListeners()
        startWatchdog()
        watchdog.started(buffers: 0, at: MeetingClock.now())
        DispatchQueue.main.async { [weak self] in self?.onRestart?(nil) }
    }

    /// Voice processing failed on the device with `uid`: it records raw for a minute (counted; three
    /// failures and it stays raw this recording), or for 10 s, uncounted, while Core Audio is still coming
    /// up after a restart (a failure then says nothing about the device).
    private func recordVoiceProcessingFailure(_ uid: String?) {
        guard let uid else { return }
        let settling = MeetingClock.now() - serviceRestartedAt < 10
        state.withLock {
            let count = vpFailures[uid]?.count ?? 0
            vpFailures[uid] = settling ? (count, Date().addingTimeInterval(10)) : (count + 1, Date().addingTimeInterval(60))
        }
    }

    private func teardownNow() {
        for (address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block)
        }
        listeners = []
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        pendingRestart = nil
        unit?.stop()
        unit = nil
        // The engine's tap runs on its own thread, and nothing says it has returned once the tap is removed:
        // after `close` no tap block is pushing, so the next unit is the queue's only producer.
        tapGate?.close()
        tapGate = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        boundInput = nil
        boundOutput = nil
    }

    /// Restarts once notifications have settled, coalescing a burst of them into one restart. Unless
    /// `force`, only if the default devices really changed (our own start reconfigures them too) or the
    /// engine stopped itself. A forced restart (Core Audio restarted) arriving while an unforced one waits
    /// replaces it, with its own longer settle.
    private func scheduleRestart(after delay: Double, force: Bool, _ reason: String) {
        guard wanted.0 else { return }
        if let pending = pendingRestart, !(force && !pending.force) { return }
        restartTag += 1
        let tag = restartTag
        pendingRestart = (force, reason, tag)
        micQueue.asyncAfter(deadline: .now() + delay) { [self] in
            guard let pending = pendingRestart, pending.tag == tag, wanted.0 else { return }
            pendingRestart = nil
            if !pending.force {
                let input = VoiceProcessingInput.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
                let output = VoiceProcessingInput.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
                let engineStopped = engine.map { !$0.isRunning } ?? false
                guard input != boundInput || (unit != nil && output != boundOutput) || engineStopped else { return }
            }
            NSLog("Shout: restarting the meeting microphone (\(pending.reason))")
            startNow()
        }
    }

    private func addListeners() {
        func listen(_ selector: AudioObjectPropertySelector, force: Bool, delay: Double, _ reason: String) {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let serviceRestart = selector == kAudioHardwarePropertyServiceRestarted
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.micQueue.async {
                    if serviceRestart { self.serviceRestartedAt = MeetingClock.now() }
                    self.scheduleRestart(after: delay, force: force, reason)
                }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block) == noErr {
                listeners.append((addr, block))
            }
        }
        // Follow the default microphone and speakers (the speakers are the echo reference).
        listen(kAudioHardwarePropertyDefaultInputDevice, force: false, delay: 0.3, "input device changed")
        listen(kAudioHardwarePropertyDefaultOutputDevice, force: false, delay: 0.3, "output device changed")
        // coreaudiod restarted: units, devices and listeners are all gone (AudioHardware.h); rebuild them.
        listen(kAudioHardwarePropertyServiceRestarted, force: true, delay: 1, "audio service restarted")
        if let engine {
            // AVAudioEngine stops itself on a configuration change (AVAudioEngine.h).
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                              queue: nil) { [weak self] _ in
                guard let self else { return }
                self.micQueue.async { self.scheduleRestart(after: 0.3, force: false, "configuration change") }
            }
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: micQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        watchdogTimer = timer
    }

    private func checkHealth() {
        let (wanted, _, wantsVoiceProcessing) = self.wanted
        guard wanted, pendingRestart == nil else { return }
        let buffers = state.withLock { _buffers }
        for action in watchdog.check(buffers: buffers, at: MeetingClock.now()) {
            switch action {
            case .restart:
                if unit != nil && buffers == 0 {
                    // Voice processing came up but never delivered: the raw microphone takes over (and voice
                    // processing is tried again later), instead of restarting the same silent unit for good.
                    NSLog("Shout: the voice-processing microphone delivered no audio; using the raw microphone")
                    recordVoiceProcessingFailure(boundInput.flatMap(VoiceProcessingInput.deviceUID) ?? Self.defaultInputUID())
                } else {
                    NSLog("Shout: the meeting microphone delivered no audio for a while; restarting it")
                }
                startNow()
                return
            case .reportStall:
                state.withLock { _stalled = true }
                DispatchQueue.main.async { [weak self] in self?.onStall?() }
            case .reportRecovered:
                state.withLock { _stalled = false }
                DispatchQueue.main.async { [weak self] in self?.onRecovered?() }
            }
        }
        // Recording raw because voice processing failed on this device: try it again once allowed.
        if wantsVoiceProcessing, unit == nil, let uid = Self.defaultInputUID(),
           let failure = state.withLock({ vpFailures[uid] }), !Self.skipsVoiceProcessing(failure) {
            startNow()
        }
    }

    private func startEngine(diagnostics: inout [String]) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        diagnostics.append("engine: input \(format.channelCount) ch @ \(Int(format.sampleRate)) Hz, \(format.isInterleaved ? "interleaved" : "non-interleaved")")
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        let queue = handoff, gen = generation, rate = format.sampleRate
        let scratch = Scratch(capacity: 16_384)
        let gate = TapGate()
        // Channel 0 only: a multi-microphone device can report several. The tap block runs on the engine's
        // own (not real-time) thread, so the gate may lock.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            gate.run {
                let host = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
                guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else {
                    queue.push(nil, count: 0, hostTime: host, sampleRate: rate, generation: gen)
                    return
                }
                let frames = Int(buffer.frameLength)
                let stride = buffer.stride // 1 for non-interleaved, the channel count for interleaved
                if stride == 1 { queue.push(ch[0], count: frames, hostTime: host, sampleRate: rate, generation: gen); return }
                // De-interleaved through the scratch buffer, a slice at a time (each continuing the last).
                var done = 0
                while done < frames {
                    let n = min(frames - done, scratch.capacity)
                    for i in 0..<n { scratch.pointer[i] = ch[0][(done + i) * stride] }
                    let offset = UInt64(Double(done) / rate * MeetingClock.ticksPerSecond)
                    queue.push(scratch.pointer, count: n, hostTime: host &+ offset, sampleRate: rate, generation: gen)
                    done += n
                }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            gate.close()
            input.removeTap(onBus: 0)
            throw CaptureError.startFailed(Self.describe(error))
        }
        self.engine = engine
        tapGate = gate
        diagnostics.append("engine started")
    }

    private final class Scratch: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<Float>
        let capacity: Int
        init(capacity: Int) {
            self.capacity = capacity
            pointer = .allocate(capacity: capacity)
            pointer.initialize(repeating: 0, count: capacity)
        }
        deinit { pointer.deallocate() }
    }

    /// Lets an engine tap push only until it is closed; `close` returns once no push is in progress.
    private final class TapGate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        func run(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            if open { body() }
        }
        func close() { lock.withLock { open = false } }
    }

    // MARK: Delivery (on deliveryQueue)

    /// Drains the audio thread's queue every 10 ms while a session runs.
    private func setDraining(_ on: Bool) {
        deliveryQueue.async { [self] in
            if on {
                guard drainTimer == nil else { return }
                let timer = DispatchSource.makeTimerSource(queue: deliveryQueue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(5))
                timer.setEventHandler { [weak self] in self?.drain() }
                timer.resume()
                drainTimer = timer
            } else {
                // A `start` that came in meanwhile keeps the timer (its own `setDraining(true)` may have run first).
                guard !state.withLock({ _wanted }) else { return }
                drainTimer?.cancel()
                drainTimer = nil
                handoff.drain { _ in } // what a stopped capture left behind
            }
        }
    }

    private func drain() {
        handoff.drain { chunk in
            var peak: Float = 0
            if let base = chunk.samples.baseAddress, chunk.samples.count > 0 {
                vDSP_maxmgv(base, 1, &peak, vDSP_Length(chunk.samples.count))
            }
            let time = chunk.time
            let (session, acceptFrom, dropEpisode) = state.withLock { () -> (Session?, Int, Bool) in
                // Only the unit now running counts for the watchdog and the stats.
                if chunk.generation >= _liveGeneration { _buffers += 1; _peak = max(_peak, peak); _lastBufferTime = time }
                let episode = drops.record(frames: chunk.dropped, sampleRate: chunk.sampleRate, at: MeetingClock.now())
                return (self.session, _acceptFrom, episode)
            }
            if dropEpisode {
                NSLog("Shout: the meeting microphone lost \(Int(Double(chunk.dropped) / chunk.sampleRate * 1000)) ms of audio: delivery fell behind")
            }
            // Audio from before this session's own unit (a stopped one's last chunks) goes nowhere.
            guard let session, chunk.generation >= acceptFrom, chunk.samples.count > 0, chunk.sampleRate > 0 else { return }
            if chunk.generation != deliveredGeneration {
                deliveredGeneration = chunk.generation
                converter = nil
                session.discontinuity?()
            } else if chunk.dropped > 0 {
                // Audio was lost just before this chunk: it goes to its own time, not right after the last.
                session.discontinuity?()
            }
            if converter?.inputFormat.sampleRate != chunk.sampleRate {
                converter = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate, channels: 1)
                    .flatMap { AVAudioConverter(from: $0, to: target) }
                converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            }
            guard let converter, let out = Self.convert(chunk.samples, converter: converter, target: target) else { return }
            session.sink(out, time)
        }
    }

    /// Resamples one chunk to 16 kHz (the converter keeps its filter state between chunks).
    static func convert(_ samples: UnsafeBufferPointer<Float>, converter: AVAudioConverter, target: AVAudioFormat) -> [Float]? {
        guard let base = samples.baseAddress,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = input.floatChannelData else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        ch[0].update(from: base, count: samples.count)
        let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / converter.inputFormat.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, out.frameLength > 0, let o = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: o[0], count: Int(out.frameLength)))
    }
}

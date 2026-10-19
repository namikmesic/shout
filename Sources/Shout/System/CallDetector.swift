import AppKit
import Combine
import ShoutKit

/// Detects calls from the apps holding the microphone and decides when to prompt, stop and resume.
///
/// Wiring: `MicActivityMonitor` (who holds the mic) → `CallContextProbe` (URLs and titles for browsers
/// and Slack) → `MeetingDetection.detect` → `CallSessionTracker` → `actions`. No UI here: the app shows
/// the prompt card, stopping banner and resume offer, and reports back what the user did.
@MainActor
final class CallDetector: ObservableObject {
    typealias Action = CallSessionTracker.Action
    typealias Target = CallSessionTracker.Target

    /// Why a recording stopped, as far as detection cares.
    enum StopKind {
        /// The user, or a safety net (maximum length, silence): calls holding the mic are not prompted again.
        case user
        /// The Mac went to sleep: the call may resume the meeting after wake.
        case suspended
        /// Neither declined nor resumable (fast user switch, a start that failed): the call may prompt again.
        case interrupted
    }

    /// The best call holding the mic right now (auto-start capable calls first).
    @Published private(set) var current: DetectedCall?
    /// Every detected call holding the mic.
    @Published private(set) var calls: [DetectedCall] = []

    /// Tracker decisions, delivered on the main thread.
    let actions = PassthroughSubject<Action, Never>()
    var onAction: ((Action) -> Void)?

    /// Whether the Scribe is recording. The Scribe reports starts and stops itself, synchronously,
    /// with `recordingStarted` and `recordingStopped` (what the recording follows, why it stopped).
    var isRecording: Bool { recording }
    /// True while someone is speaking in the recording (mic or system audio). Sampled at every check.
    var speechActive: (() -> Bool)?
    /// The calendar occurrence a call belongs to (`MeetingDetection.eventKey`); set by the app.
    var eventKey: ((DetectedCall) -> String?)?
    /// Show prompts for new calls ("Automatically detect any call").
    var promptsEnabled: Bool {
        get { tracker.promptsEnabled }
        set { tracker.promptsEnabled = newValue; updateMonitoring() }
    }
    /// Stop recordings when their call ends ("Stop Scribe when a call ends").
    var autoStopEnabled: Bool {
        get { tracker.autoStopEnabled }
        set { tracker.autoStopEnabled = newValue; updateMonitoring() }
    }
    /// Also treat browsers and Slack holding the mic without meeting evidence as (non-auto-start) calls.
    var includeUnconfirmed = false

    /// Meeting URLs stay usable this long after they were last seen in a browser (the meeting tab may be
    /// in the background by the time the browser takes the mic).
    static let urlCacheTTL: TimeInterval = 300
    /// A browser call confirmed with a meeting URL is read again this often while it holds the mic.
    static let reprobeConfirmed: TimeInterval = 15
    static let tickInterval: TimeInterval = 0.5
    /// Poll cadence while nothing needs detection (prompts off, no recording to follow).
    static let silentPollInterval: TimeInterval = 30

    private let monitor = MicActivityMonitor()
    private let probe = CallContextProbe()
    private var tracker = CallSessionTracker()
    private var recording = false
    private var running = false
    /// Calls confirmed with a meeting URL or code for a holder process, kept while that process holds the mic.
    private var confirmed: [pid_t: (call: DetectedCall, at: Date)] = [:]
    /// Recently seen meeting URLs per browser bundle ID (lowercased).
    private var meetingURLs: [String: [String: Date]] = [:]
    private var slackHuddle = SlackHuddleMarker()
    private var generation = 0
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastEvidenceProbe = Date.distantPast

    init() {
        monitor.onCheck = { [weak self] holders in self?.process(holders) }
        monitor.onDefaultInputChanged = { [weak self] in self?.tracker.inputDeviceChanged(at: Date()) }
        monitor.onServiceRestarted = { [weak self] in self?.tracker.audioServiceRestarted(at: Date()) }
    }

    var isSupported: Bool { MicActivityMonitor.isSupported }
    /// The call the current recording follows, if any.
    var boundCall: DetectedCall? { tracker.boundCall }
    /// The call the prompt is for, while it is up.
    var promptedCall: DetectedCall? { tracker.promptedCall }
    /// The call of the recording that last stopped by itself or by sleep, while it may still resume.
    var endedCall: DetectedCall? { tracker.endedCall }

    func start() {
        guard !running else { return }
        running = true
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tracker.systemDidWake(at: Date()) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.appTerminated(pid) } }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier, bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { if let pid, let bundleID { self?.appActivated(pid: pid, bundleID: bundleID) } }
        })
        monitor.start()
        updateMonitoring()
    }

    func stop() {
        guard running else { return }
        running = false
        monitor.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        ticker?.invalidate()
        ticker = nil
        generation += 1
        confirmed = [:]
        calls = []
        current = nil
        // Hide anything on screen; a fresh tracker keeps nothing from this run.
        emit((tracker.promptedCall != nil ? [.dismissPrompt] : []) + (tracker.isRecording ? [.cancelStopping] : []))
        let settings = (tracker.promptsEnabled, tracker.autoStopEnabled)
        tracker = CallSessionTracker()
        (tracker.promptsEnabled, tracker.autoStopEnabled) = settings
        if recording { _ = tracker.recordingStarted(at: Date()) }
    }

    // MARK: Recording

    /// The call a recording starting now would follow (see `CallSessionTracker.callToBind`).
    func callForRecording(_ target: Target) -> DetectedCall? { tracker.callToBind(target) }

    /// A recording started, following `call` (or the one `callForRecording(target)` gives). Returns the
    /// call it follows; without one it takes a call that belongs to `target` when it appears.
    @discardableResult
    func recordingStarted(call: DetectedCall? = nil, target: Target = Target()) -> DetectedCall? {
        guard !recording else { return tracker.boundCall }
        recording = true
        emit(tracker.recordingStarted(call: call, target: target, at: Date()))
        updateMonitoring()
        return tracker.boundCall
    }

    func recordingStopped(_ kind: StopKind = .user, at date: Date = Date()) {
        guard recording else { return }
        recording = false
        switch kind {
        case .user: emit(tracker.recordingStopped(at: date))
        case .suspended: emit(tracker.recordingSuspended(at: date))
        case .interrupted: emit(tracker.recordingStopped(at: date, latch: false))
        }
        updateMonitoring()
    }

    // MARK: User responses

    /// The user closed the prompt (×).
    func promptDismissed() { tracker.promptDeclined(at: Date()); updateTicker() }
    /// "Snooze for 2 min".
    func promptSnoozed() { tracker.promptSnoozed(at: Date()); updateTicker() }
    /// The prompt's timeout pauses while held (pointer on the card, screen locked).
    func holdPrompt(_ held: Bool) { tracker.holdPrompt(held, at: Date()) }
    /// "Keep going" on the stopping banner.
    func keepGoing() { emit(tracker.keepGoing(at: Date())) }
    /// [Stop] on the stopping banner: the auto-stop happens now (emits `.stop`). False when no call is followed.
    @discardableResult
    func expediteStop() -> Bool {
        let list = tracker.expediteStop(at: Date())
        emit(list)
        return !list.isEmpty
    }
    /// The stopping banner is not on screen (refused, or replaced): the stop is handed back.
    func stopHandedBack() { emit(tracker.stopHandedBack(at: Date())) }
    /// The offered resume could not happen: prompt for the call instead.
    func resumeFailed() { emit(tracker.resumeFailed(at: Date())) }

    // MARK: Pipeline

    /// Accessibility is read only when something needs it: prompts on, or (prompts off) while auto-stop follows
    /// a recording: the recorded call's own app, or any browser and Slack while the recording still looks for
    /// its call; and the app of a call that stopped by itself, so it can resume.
    private func readsContext(for holder: MicHolder) -> Bool {
        if promptsEnabled { return true }
        if recording && autoStopEnabled, tracker.boundCall.map({ $0.pid == holder.appPID }) ?? true { return true }
        return tracker.endedCall?.pid == holder.appPID
    }

    private func process(_ holders: [MicHolder]) {
        let now = Date()
        confirmed = confirmed.filter { pid, _ in holders.contains { $0.pid == pid } }
        var found: [DetectedCall] = []
        var needContext: [(MicHolder, Bool)] = []
        for holder in holders {
            let kind = MeetingDetection.kind(of: holder)
            if let hit = confirmed[holder.pid], kind != .browser || now.timeIntervalSince(hit.at) < Self.reprobeConfirmed {
                found.append(hit.call)
                continue
            }
            switch kind {
            case .ignored: continue
            case .meetingApp: if let c = MeetingDetection.detect(holder: holder, context: nil) { found.append(c) }
            case .browser, .slack:
                guard readsContext(for: holder) else { continue }
                needContext.append((holder, kind == .browser))
            }
        }
        generation += 1
        let gen = generation
        guard !needContext.isEmpty else { return deliver(found) }
        Task { @MainActor in
            var all = found
            for (holder, browser) in needContext {
                var ctx = await probe.context(pid: holder.appPID, browser: browser)
                // A newer check (or `stop`) superseded this one while Accessibility was being read: the newer
                // one reads again (from the probe's cache), and a stale result must not seed `confirmed`.
                guard gen == generation, running else { return }
                if browser { ctx = remember(ctx, bundleID: holder.appBundleID) }
                else if let title = ctx?.windowTitles.first,
                        NSWorkspace.shared.frontmostApplication?.processIdentifier == holder.appPID {
                    slackHuddle.note(windowTitle: title, at: Date())
                }
                // A re-read keeps the meeting already recorded or prompted in this app ahead of another meeting's
                // tab opened beside it.
                let known = [tracker.boundCall, tracker.promptedCall].compactMap { $0 }
                    .first { $0.pid == holder.appPID && $0.meetingCode != nil }
                if let c = MeetingDetection.detect(holder: holder, context: ctx, includeUnconfirmed: includeUnconfirmed,
                                                   slackHuddleSeen: !browser && slackHuddle.isFresh(at: Date()),
                                                   preferCode: known?.meetingCode) {
                    // Weak results (no URL or code, or not enough to auto-start) are read again next time.
                    if c.qualifiesForAutoStart && (c.url != nil || c.meetingCode != nil) { confirmed[holder.pid] = (c, Date()) }
                    all.append(c)
                }
            }
            deliver(all)
        }
    }

    private func deliver(_ found: [DetectedCall]) {
        // The same app can hold the mic from several processes; keep the most specific result.
        var unique: [DetectedCall] = []
        for var c in found {
            c.eventKey = eventKey?(c)
            if let i = unique.firstIndex(where: { $0.isSameCall(as: c) }) {
                if c.improves(on: unique[i]) { unique[i] = c }
            } else {
                unique.append(c)
            }
        }
        if unique != calls { calls = unique }
        let best = unique.first { $0.qualifiesForAutoStart } ?? unique.first
        if best != current { current = best }
        sampleSpeech()
        emit(tracker.observe(unique, at: Date()))
        if let bound = tracker.boundCall, !unique.contains(where: { $0.isSameCall(as: bound) }) { gatherStopEvidence(for: bound) }
        updateMonitoring()
    }

    /// After the recorded call's app released the mic: did the app quit, or is the meeting window gone?
    private func gatherStopEvidence(for call: DetectedCall) {
        if !MicActivityMonitor.isAlive(call.pid) || NSRunningApplication(processIdentifier: call.pid)?.isTerminated == true {
            emit(tracker.corroborate(.appQuit, at: Date()))
            return
        }
        guard Date().timeIntervalSince(lastEvidenceProbe) >= 2 else { return }
        lastEvidenceProbe = Date()
        let browser = MeetingDetection.kind(bundleID: call.bundleID) == .browser
        Task { @MainActor in
            let ctx = await probe.context(pid: call.pid, browser: browser, maxAge: 0)
            guard running, let bound = tracker.boundCall, bound.isSameCall(as: call),
                  MeetingDetection.isCallStillVisible(call, context: ctx) == false else { return }
            emit(tracker.corroborate(.windowGone, at: Date()))
        }
    }

    private func appTerminated(_ pid: pid_t) {
        guard let bound = tracker.boundCall, bound.pid == pid else { return }
        // Only counts once the holder is gone; the next check will notice.
        emit(tracker.corroborate(.appQuit, at: Date()))
        monitor.checkNow()
    }

    /// A browser came to the front: note its meeting URLs, so a meeting tab later moved to the
    /// background still identifies the call. Slack in front: note whether it shows a huddle.
    private func appActivated(pid: pid_t, bundleID: String) {
        guard promptsEnabled else { return }
        switch MeetingDetection.kind(bundleID: bundleID) {
        case .browser:
            Task { @MainActor in
                let ctx = await probe.context(pid: pid, browser: true)
                _ = remember(ctx, bundleID: bundleID)
            }
        case .slack:
            Task { @MainActor in
                guard let title = await probe.context(pid: pid, browser: false)?.windowTitles.first else { return }
                slackHuddle.note(windowTitle: title, at: Date())
            }
        default:
            break
        }
    }

    /// Adds the context's meeting URLs to the cache and the cached ones to the context.
    private func remember(_ ctx: MeetingContext?, bundleID: String) -> MeetingContext? {
        guard var ctx else { return nil }
        let key = bundleID.lowercased()
        let now = Date()
        var cached = (meetingURLs[key] ?? [:]).filter { now.timeIntervalSince($0.value) < Self.urlCacheTTL }
        for url in ctx.urls where MeetingDetection.platform(forURL: url) != nil { cached[url] = now }
        meetingURLs[key] = cached.isEmpty ? nil : cached
        ctx.recentURLs = cached.sorted { $0.value > $1.value }.map(\.key).filter { !ctx.urls.contains($0) }
        return ctx
    }

    // MARK: Ticking and output

    /// Poll cadence and the bound app's fast watch follow what detection is needed for.
    private func updateMonitoring() {
        let following = recording && autoStopEnabled
        monitor.setPollInterval(!(promptsEnabled || following) ? Self.silentPollInterval : (recording ? 3 : 5))
        monitor.watch(appPID: following ? tracker.boundCall?.pid : nil)
        updateTicker()
    }

    private func sampleSpeech() {
        if speechActive?() == true { tracker.lastSpeechAt = Date() }
    }

    private func emit(_ list: [Action]) {
        for action in list {
            onAction?(action)
            actions.send(action)
        }
        updateTicker()
    }

    private func updateTicker() {
        if tracker.needsTick && running {
            guard ticker == nil else { return }
            let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sampleSpeech()
                    self.emit(self.tracker.tick(at: Date()))
                }
            }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } else {
            ticker?.invalidate()
            ticker = nil
        }
    }
}

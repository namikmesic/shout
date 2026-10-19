import Foundation

/// Watches a running capture's buffer counter: one that stops delivering (a dead voice-processing unit
/// after a Core Audio restart, an engine that stopped itself on a device change) is restarted, and if
/// restarts don't bring audio back the stall is reported so the user can be told.
///
/// Feed it once a second from the capture's own queue. Times are host-clock seconds (`MeetingClock`).
public struct CaptureWatchdog: Sendable {
    public enum Action: Equatable, Sendable {
        case restart
        /// Restarts did not help: tell the user the microphone isn't being heard.
        case reportStall
        /// Audio is flowing again after a reported stall.
        case reportRecovered
    }

    /// No new buffer for this long means the capture is dead (Chromium's AliveChecker uses 5–12 s).
    public var stallSeconds: Double = 4
    /// Restarts without audio before the stall is reported.
    public var reportAfter = 2
    /// Longest wait between restarts once they keep failing.
    public var maxBackoff: Double = 30

    private var lastCount = 0
    private var lastProgress: Double
    private var restarts = 0
    public private(set) var stallReported = false

    public init(now: Double) { lastProgress = now }

    /// The capture was (re)started with its counter at `buffers`: judge it only after `stallSeconds`.
    public mutating func started(buffers: Int = 0, at now: Double) {
        lastCount = buffers
        lastProgress = now
    }

    /// The capture was stopped on purpose (dictation, Stop): forget the failures, including a stall that
    /// was reported (the capture clears its own flag then), so a restarted capture that is still dead is
    /// reported again.
    public mutating func reset(at now: Double) {
        restarts = 0
        lastCount = 0
        stallReported = false
        lastProgress = now
    }

    public mutating func check(buffers: Int, at now: Double) -> [Action] {
        if buffers != lastCount {
            lastCount = buffers
            lastProgress = now
            restarts = 0
            if stallReported { stallReported = false; return [.reportRecovered] }
            return []
        }
        // Back off once restarts keep failing: 4, 4, 8, 16, 30 s.
        let wait = min(maxBackoff, stallSeconds * pow(2, Double(max(0, restarts - 1))))
        guard now - lastProgress >= wait else { return [] }
        var actions: [Action] = []
        if restarts >= reportAfter && !stallReported {
            stallReported = true
            actions.append(.reportStall)
        }
        restarts += 1
        lastProgress = now
        actions.append(.restart)
        return actions
    }
}

/// Dead-tap detection while the System Audio Recording permission says "allowed": a tap can deliver
/// nothing but exact zeros although other apps are playing (Wispr Flow rebuilds such a tap on a similar
/// ladder). The oracle for "something is playing" is Core Audio's per-process "is running output" flag
/// (`PlaybackOracle`: the call's own processes when they are known, else any process except Shout); with
/// nothing playing, silence is just a quiet call and nothing happens.
///
/// - Silent for 10 s while others play → rebuild the tap (same layout).
/// - At most 3 rebuilds per episode (1 if the tap never delivered audio this leg), 0 / 10 / 30 s apart,
///   each followed by 10 s of verification; audio coming back resets the budget (2 times per leg).
/// - Budget spent and others still playing → show the notice, then keep retrying 30, 60, … 600 s apart
///   (at most 10 times). Audio coming back, or nothing playing any more, clears the notice.
/// - A tap heard since its last rebuild is presumed alive: an app that keeps its output running with exact
///   zeros (the other side muted, everyone listening to the user) looks just like a dead tap. Its silence
///   is suspected only after 60 s and gets one rebuild and the keep-alive retries, never the notice.
public struct SystemAudioLiveness: Sendable {
    public enum Action: Equatable, Sendable { case none, rebuild, showSilentNotice, clearSilentNotice }

    public struct Config: Sendable {
        public var suspectSeconds: Double = 10
        /// How long a tap heard since its last rebuild must stay silent before it is suspected.
        public var provenSuspectSeconds: Double = 60
        public var maxRebuilds = 3
        public var backoff: [Double] = [0, 10, 30]
        public var verifySeconds: Double = 10
        public var credits = 2
        public var rearm: [Double] = [30, 60, 120, 240, 480, 600]
        public var maxRearms = 10
        public init() {}
    }

    private enum Phase: Equatable {
        case watching
        case verifying(since: Double)
        case exhausted(next: Double, rearms: Int)
    }

    public let config: Config
    public private(set) var noticeShown = false
    private var phase = Phase.watching
    private var suspectSince: Double?
    private var episodeRebuilds = 0
    /// The current episode began on a tap heard since its last rebuild (most likely a quiet call).
    private var episodeProven = false
    private var lastRebuild = -Double.infinity
    private var creditsLeft: Int

    public init(config: Config = Config()) {
        self.config = config
        creditsLeft = config.credits
    }

    /// Once a second while recording (skip it while the tap is stalled or rebuilding: that is a different
    /// failure). `zeroRunSeconds`, `lastHeard` (host time of the latest non-silent audio) and `heardAny` come
    /// from the system track's stats; `othersPlaying` is the oracle (only needed while the track is silent).
    public mutating func tick(now: Double, zeroRunSeconds: Double, lastHeard: Double?, heardAny: Bool,
                              othersPlaying: Bool) -> Action {
        if case .verifying(let since) = phase, let lastHeard, lastHeard >= since {
            // Audio since the rebuild: recovered.
            phase = .watching
            if creditsLeft > 0 { creditsLeft -= 1; episodeRebuilds = 0 }
        }
        if zeroRunSeconds < 1 {
            suspectSince = nil
            if case .exhausted = phase { phase = .watching; episodeRebuilds = 0 }
            if noticeShown { noticeShown = false; return .clearSilentNotice }
            return .none
        }
        if case .verifying(let since) = phase, now - since >= config.verifySeconds { phase = .watching } // failed
        switch phase {
        case .verifying:
            return .none
        case .exhausted(let next, let rearms):
            if !othersPlaying {
                suspectSince = nil
                if noticeShown { noticeShown = false; return .clearSilentNotice }
                return .none
            }
            if !noticeShown && !episodeProven { noticeShown = true; return .showSilentNotice }
            guard now >= next, rearms < config.maxRearms else { return .none }
            let delay = config.rearm[min(rearms + 1, config.rearm.count - 1)]
            phase = .exhausted(next: now + delay, rearms: rearms + 1)
            lastRebuild = now
            return .rebuild
        case .watching:
            guard othersPlaying else { suspectSince = nil; return .none }
            if suspectSince == nil && episodeRebuilds == 0 {
                // A new episode: was this tap heard since it was last rebuilt?
                episodeProven = lastHeard.map { $0 > lastRebuild } ?? false
            }
            let since = suspectSince ?? now
            suspectSince = since
            guard now - since >= (episodeProven ? config.provenSuspectSeconds : config.suspectSeconds) else { return .none }
            let budget = episodeProven ? 1 : heardAny ? config.maxRebuilds : 1
            guard episodeRebuilds < budget else {
                phase = .exhausted(next: now + config.rearm[0], rearms: 0)
                // A tap that was working is most likely hearing a quiet call: keep-alive retries, no notice.
                if episodeProven { return .none }
                noticeShown = true
                return .showSilentNotice
            }
            guard now - lastRebuild >= config.backoff[min(episodeRebuilds, config.backoff.count - 1)] else { return .none }
            episodeRebuilds += 1
            lastRebuild = now
            phase = .verifying(since: now)
            return .rebuild
        }
    }
}

/// The "is something playing" oracle for `SystemAudioLiveness`, from Core Audio's process objects. When
/// the recorded call's own processes are among them, only they count: another app keeping an idle output
/// running (a web page's audio context) says nothing about whether the call can be heard.
public enum PlaybackOracle {
    public struct Process: Sendable, Equatable {
        public var pid: Int32
        /// The process that launched it (an app's helper), 0 if unknown.
        public var parentPID: Int32
        public var bundleID: String?
        /// `kAudioProcessPropertyIsRunningOutput`.
        public var runningOutput: Bool

        public init(pid: Int32, parentPID: Int32 = 0, bundleID: String?, runningOutput: Bool) {
            self.pid = pid
            self.parentPID = parentPID
            self.bundleID = bundleID
            self.runningOutput = runningOutput
        }
    }

    /// Whether a process other than `me` plays audio: one of the call's processes if any of them uses
    /// audio, else any process.
    public static func othersPlaying(_ processes: [Process], excluding me: Int32, call: DetectedCall?) -> Bool {
        let others = processes.filter { $0.pid != me }
        if let call {
            let own = others.filter { belongs($0, to: call) }
            if !own.isEmpty { return own.contains(where: \.runningOutput) }
        }
        return others.contains(where: \.runningOutput)
    }

    /// The call's app, a helper it launched (Chromium, Electron and Firefox play audio from one), or a
    /// process whose bundle ID extends the app's; for Safari, WebKit's processes; for FaceTime, its
    /// conference daemon.
    static func belongs(_ p: Process, to call: DetectedCall) -> Bool {
        if p.pid == call.pid || (p.parentPID != 0 && p.parentPID == call.pid) { return true }
        guard let id = p.bundleID else { return false }
        if id == call.bundleID || id.hasPrefix(call.bundleID + ".") { return true }
        switch call.bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview": return id.hasPrefix("com.apple.WebKit.")
        case "com.apple.FaceTime": return id == "com.apple.avconferenced"
        default: return false
        }
    }
}

/// Lets one microphone user wait, briefly, until another has let go of the device. The Scribe stops its
/// voice-processing unit on its own queue, which takes a while; the dictation recorder starting under it
/// would be reconfigured mid-start (an `AVAudioEngineConfigurationChange` restart that costs the first
/// words).
public final class MicrophoneRelease: @unchecked Sendable {
    public static let shared = MicrophoneRelease()

    private let condition = NSCondition()
    private var pending = 0

    public init() {}

    /// A release was asked for (call where the stop is requested).
    public func begin() { condition.withLock { pending += 1 } }

    /// The device is let go (call once the stop has been carried out).
    public func end() {
        condition.withLock {
            pending = max(0, pending - 1)
            if pending == 0 { condition.broadcast() }
        }
    }

    public var isPending: Bool { condition.withLock { pending > 0 } }

    /// Waits until no release is in progress, at most `timeout` seconds. Returns false if one still is.
    @discardableResult
    public func wait(timeout: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while pending > 0 {
            if !condition.wait(until: deadline) { return pending == 0 }
        }
        return true
    }
}

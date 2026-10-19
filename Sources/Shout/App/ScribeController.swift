import AppKit
import Combine
import IOKit.pwr_mgt
@preconcurrency import UserNotifications
import ShoutKit
import ShoutLLM

/// Records meetings: the meeting microphone ("You") and system audio ("Others") as two aligned tracks
/// on disk, transcribed live with the shared speech model. Start / Stop / Resume; a stopped meeting can
/// be resumed into the same note.
@MainActor
final class ScribeController: ObservableObject {
    static var systemAudioSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    enum Notice: Hashable {
        /// No call audio yet; usually means System Audio Recording is not allowed.
        case systemAudioSilent
        /// System Audio Recording is turned off for Shout in System Settings.
        case systemAudioDenied
        case systemAudioUnavailable(String)
        case micUnavailable(String)
        case micSilent
        case noEchoCancellation
        case transcriptionFailed(String)
    }

    enum StopReason {
        case user, maxLength, noSpeech, sleep, quit, callEnded
        /// Another user took over the Mac (fast user switching).
        case userSwitch
    }

    @Published private(set) var activeMeetingID: String?
    @Published private(set) var micSpeaking = false
    @Published private(set) var systemSpeaking = false
    @Published private(set) var micPausedForDictation = false
    @Published private(set) var notices: [Notice] = []
    /// Meetings whose queued audio is still being transcribed.
    @Published private(set) var processingIDs: Set<String> = []
    /// What the summary of each meeting being summarized is doing ("Reading part 2 of 3…").
    @Published private(set) var summaryStage: [String: String] = [:]
    /// The one person the meeting app shows talking right now, while recording with speaker names on.
    @Published private(set) var liveSpeakerName: String?
    private var summaryTasks: [String: Task<Void, Never>] = [:]
    private var titleTasks: [String: Task<Void, Never>] = [:]
    private var deletions: AnyCancellable?
    /// Created with the controller, at launch: it must be the notification delegate before launch finishes.
    private let summaryNotifier: SummaryNotifier
    /// Calendar, for meeting titles and attendees.
    weak var calendar: CalendarService?
    /// Call detection (mic holders) and the auto-stop ladder.
    private(set) var detector: CallDetector?
    /// The meeting most recently stopped because its call ended or the Mac slept, for auto-resume.
    private var autoStoppedMeetingID: String?

    var isRecording: Bool { activeMeetingID != nil }
    var elapsed: TimeInterval { recordedBeforeLeg + (legStartDate.map { Date().timeIntervalSince($0) } ?? 0) }
    var micLevel: Float { micPausedForDictation ? 0 : (micTrack?.stats.level ?? 0) }
    /// Microphone start-up details and buffer counts (self-test, diagnostics).
    var micDiagnostics: [String] {
        let s = mic.bufferStats
        return mic.diagnostics + ["running \(mic.isRunning), echo cancellation \(mic.echoCancellation), buffers \(s.buffers), raw peak \(String(format: "%.4f", s.peak))"]
    }
    var systemLevel: Float { systemTrack?.stats.level ?? 0 }

    /// Opens the Notepad for a meeting; `activate` is false when it opens automatically.
    var onOpenNotepad: ((String, Bool) -> Void)?
    /// True while dictation holds the microphone (set by the app delegate).
    var isDictating: (() -> Bool)?
    /// Arranges the meeting app (by pid) and the Notepad side by side.
    var onSplitScreen: ((pid_t) -> Void)?
    /// Whether the meeting is on screen in front (main window or Notepad), so "summary ready" is not
    /// announced for it. Set by the app delegate; the default only knows the main window's page.
    var isMeetingFrontmost: ((String) -> Bool)?

    /// One recording leg (Start or Resume until Stop), and what is needed to undo it.
    private struct Leg {
        var meetingID: String
        /// Where the leg begins on the timeline, in samples.
        var startSample: Int
        /// Seq of the `resumed` marker that began it (nil for a meeting's first leg).
        var resumedSeq: Int?
        /// The meeting as it was before this leg (restored when the leg is discarded).
        var before: Meeting?
        /// The calendar occurrence the recording belongs to (`MeetingDetection.eventKey`).
        var eventKey: String?
        /// The note's stop count once this leg stopped. Its "Started by mistake?" card acts only while the
        /// note's count is still this (no Resume since).
        var stopSeq: Int?
    }

    private let settingsStore: SettingsStore
    private let store: Store
    private let hub: EngineHub
    private let flowBar: FlowBarController
    private let mic = MeetingMicCapture()
    private var systemCapture: AnyObject?
    private var micTrack: MeetingTrack?
    private var systemTrack: MeetingTrack?
    private var leg: Leg?
    /// Stopped legs waiting for their transcription: then "Started by mistake?" or "Couldn't start recording".
    private var stoppedLegs: [String: (leg: Leg, captured: Bool)] = [:]
    /// The card asking about each meeting's stopped leg ("Started by mistake?", "Couldn't start recording").
    private var legCards: [String: UUID] = [:]
    private var legStartDate: Date?
    private var recordedBeforeLeg: TimeInterval = 0
    private var tickTimer: Timer?
    private var displayAssertion: IOPMAssertionID = 0
    /// Dead-tap detection while the permission says allowed (silence while other apps play).
    private var systemLiveness = SystemAudioLiveness()
    /// Rebuilds of a tap whose permission probe failed although the permission now says allowed.
    private var deniedRebuilds = 0
    private var lastMicRetry = Date.distantPast
    /// Capture problems shown as a card once per episode (tick-driven, so a refused card is retried).
    private var micStallCardShown = false
    private var micStallCardID: UUID?
    private var storageCardShown = false
    private static let micStalledText = "It stopped sending audio. Shout keeps restarting it; check the input in System Settings › Sound."
    private static let storageFullText = "Shout can't save the meeting audio (the disk may be full). The transcript continues; audio from here on isn't kept until space is free."
    /// Meetings with a transcription failure shown and not yet followed by a good line.
    private var reportedFailure: Set<String> = []
    /// Meetings whose interrupted leg (quit or crash) was closed in this launch.
    private var recovered: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    // Safety nets (see `tick`)
    private var lastTickAt: Date?
    private var lastMicBuffers = 0
    /// Seconds the microphone has been healthy with no transcript line (Wispr Flow's silence check).
    private var silentSeconds: TimeInterval = 0
    private var legLines = 0
    private var lastLineAt: Date?
    private var lineSinceTick = false
    private var silenceCardID: UUID?
    /// The cap (seconds) the maximum-length warning was answered or shown for.
    private var maxWarnedCap: TimeInterval?
    private var checkInShown = false

    // Who is at the Mac: an auto-start countdown never runs while nobody is.
    private var screenLocked = false
    private var screensAsleep = false
    private var sessionActive = true
    private var userPresent: Bool { !screenLocked && !screensAsleep && sessionActive }

    /// The calendar event the user last joined from Shout, for 2 minutes (`CalendarMatcher.userIntentTTL`).
    private var joinIntent: (eventID: String, at: Date)?

    // Speaker names (see "Speaker names" below)
    private var speakerPoller: MeetingSpeakerPoller?
    /// What the meeting app showed during this leg; closed spans are stored every tick.
    private var speakerTimeline: SpeakerTimeline?
    /// The recording meeting's renames (name key → new name), applied to names read from now on.
    private var speakerAliases: [String: String] = [:]
    /// Where this leg begins on the timeline (sample) and on the host clock, to place readings without a hop onto
    /// the track's write queue (`MeetingTrack.position(at:)` is the same formula).
    private var legClock: (sample: Int, time: Double)?

    private lazy var transcriber = MeetingTranscriber(
        recognizer: { @MainActor in try await EngineHub.shared.currentRecognizer() },
        settings: { @MainActor in
            MeetingTranscriptionSettings(language: SettingsStore.shared.settings.forcedLanguage,
                                         vocabulary: Store.shared.vocabularyWords(),
                                         vocabularyEntries: Store.shared.vocabulary)
        },
        onResult: { [weak self] job, result in await self?.handle(job, result) })

    init(settingsStore: SettingsStore, store: Store, hub: EngineHub, flowBar: FlowBarController) {
        self.settingsStore = settingsStore
        self.store = store
        self.hub = hub
        self.flowBar = flowBar
        summaryNotifier = SummaryNotifier()
        // Work on a deleted meeting stops, whichever path deleted it.
        deletions = store.meetingDeleted.sink { [weak self] id in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.summaryTasks[id]?.cancel()
                self.titleTasks[id]?.cancel()
                if self.autoStoppedMeetingID == id { self.autoStoppedMeetingID = nil }
                // A card still asking about one of its legs has nothing left to keep or discard.
                self.stoppedLegs[id] = nil
                self.reportedFailure.remove(id)
                if let cardID = self.legCards.removeValue(forKey: id), self.isShowing(cardID) { self.dismissCard(id: cardID) }
            }
        }
        flowBar.model.onMeetingStop = { [weak self] in self?.stop() }
        flowBar.model.onMeetingOpen = { [weak self] in
            guard let self, let id = self.activeMeetingID else { return }
            self.onOpenNotepad?(id, true)
        }
        flowBar.model.meetingLevel = { [weak self] in
            guard let self else { return 0 }
            return max(self.micLevel, self.systemLevel)
        }
        // Starts and restarts finish on the microphone's own queue (they take a while); the outcome lands here.
        mic.onRestart = { [weak self] error in
            guard let self, self.isRecording else { return }
            if let error { self.addNotice(.micUnavailable(error.localizedDescription)) }
            else if !self.mic.isStalled {
                self.notices.removeAll { if case .micUnavailable = $0 { return true }; return false }
            }
            self.updateEchoNotice()
        }
        // The microphone stopped delivering and restarts didn't bring it back.
        mic.onStall = { [weak self] in
            guard let self, self.isRecording, !self.micPausedForDictation else { return }
            self.addNotice(.micUnavailable(Self.micStalledText))
            self.micStallCardShown = self.showMicStallCard()
        }
        mic.onRecovered = { [weak self] in
            guard let self else { return }
            self.notices.removeAll { $0 == .micUnavailable(Self.micStalledText) }
            if self.isShowing(self.micStallCardID) { self.dismissCard() }
            self.micStallCardShown = false
        }
        // The pointer left a card without SwiftUI reporting it: its pause ends (countdown, prompt timeout).
        flowBar.model.onPointerOutsideCard = { [weak self] id in self?.pointerLeftCard(id) }
        readScreenLocked()
        let ws = NSWorkspace.shared.notificationCenter
        // Handled right away (not after a hop), so a sleep stop ends the leg before the Mac sleeps.
        observe(ws, NSWorkspace.willSleepNotification) { $0.systemWillSleep(at: Date()) }
        observe(ws, NSWorkspace.didWakeNotification) { $0.systemDidWake() }
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true; $0.presenceChanged() }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false; $0.readScreenLocked(); $0.presenceChanged() }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.userSwitchedAway() }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) {
            $0.sessionActive = true; $0.readScreenLocked(); $0.presenceChanged()
        }
        let dnc = DistributedNotificationCenter.default()
        observe(dnc, .init("com.apple.screenIsLocked")) { $0.screenLocked = true; $0.presenceChanged() }
        observe(dnc, .init("com.apple.screenIsUnlocked")) { $0.screenLocked = false; $0.presenceChanged() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor (ScribeController) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    // MARK: Sleep, lock and user switching

    /// The meeting stopped because the Mac went to sleep, offered for resuming after wake.
    private var sleptMeetingID: String?

    /// Ends the leg at the moment of sleep. Like an auto-stop: the call is not latched, and the same call
    /// coming back after wake resumes the same note.
    private func systemWillSleep(at date: Date) {
        cancelAutoStart()
        guard let id = activeMeetingID else { return }
        stop(reason: .sleep, at: date)
        autoStoppedMeetingID = id
        sleptMeetingID = id
    }

    private func systemDidWake() {
        guard let id = sleptMeetingID else { return }
        sleptMeetingID = nil
        guard !isRecording, store.meeting(id: id) != nil else { return }
        showResumeCard(id, title: "Scribe stopped when your Mac went to sleep", subtitle: nil, symbol: "moon.zzz", seconds: 12)
    }

    /// Another user took over the Mac: stop at once. Nothing is offered afterwards (no Resume, no prompt latch).
    private func userSwitchedAway() {
        sessionActive = false
        presenceChanged()
        if isRecording { stop(reason: .userSwitch) }
    }

    /// Reads the lock state from the session itself, at launch and whenever the user may be back: the lock
    /// and unlock notifications alone can leave it wrong (a fast-user-switch round trip may post only one).
    private func readScreenLocked() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        screenLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Screen locked or asleep, or the session in the background: no countdown, and the prompt waits.
    private func presenceChanged() {
        if !userPresent { cancelAutoStart() }
        updatePromptHold()
    }

    /// Stops an auto-start countdown but keeps the card: the user decides when they are back.
    private func cancelAutoStart() {
        guard var card = flowBar.model.card, card.kind == .detected, card.onTimeout != nil else { return }
        countdownCancelled = true
        card.deadline = nil
        card.onTimeout = nil
        card.countdownText = nil
        card.pausedAt = nil
        present(card)
    }

    // MARK: Start / resume

    func start() { start(call: nil, event: nil) }

    /// "Join + Start" from a calendar event: records into a note titled after the event. An occurrence
    /// that already has a note (joined twice) continues that note.
    func start(event: UpcomingEvent) {
        noteJoinIntent(event)
        startNotes(call: nil, event: event)
    }

    /// The user opened an event's meeting link from Shout: a call detected in the next 2 minutes belongs to it.
    func noteJoinIntent(_ event: UpcomingEvent) {
        joinIntent = (event.id, Date())
    }

    /// Continues the note of `event`'s occurrence when it has one, else starts a new note.
    private func startNotes(call: DetectedCall?, event: UpcomingEvent?) {
        if isRecording {
            if let id = activeMeetingID { onOpenNotepad?(id, true) }
            return
        }
        // A note that has used up the maximum length can't continue; the occurrence gets a new one.
        if let event, let existing = store.meeting(calendarEventID: event.externalID, occurrenceStart: event.occurrenceStart),
           !hasUsedMaxLength(existing) {
            resume(existing.id, call: call, event: event)
            return
        }
        start(call: call, event: event)
    }

    /// Whether a note has used up the maximum length. As in Wispr Flow, the limit counts the whole note (every
    /// leg's audio), and such a note is not resumed ("This meeting has used its full recording length").
    func hasUsedMaxLength(_ m: Meeting) -> Bool {
        // A leg a quit or crash left open is not in `recordedMs` until it is recovered; the audio files say.
        let files = m.audioPath.map { MeetingArchive.length(in: URL(fileURLWithPath: $0)) } ?? 0
        let seconds = Double(max(m.recordedMs * 16, files)) / 16_000
        return seconds >= Self.maxLengthCap(minutes: settingsStore.settings.scribeMaxMinutes)
    }

    /// Everything a start depends on is passed in (not kept in properties), so a start that waits for
    /// the microphone prompt, or fails, never leaks into the next one.
    private func start(call explicitCall: DetectedCall?, event: UpcomingEvent?) {
        guard !isRecording else { if let id = activeMeetingID { onOpenNotepad?(id, true) }; return }
        guard checkReady(retry: { [weak self] in self?.start(call: explicitCall, event: event) }) else { return }
        let id = UUID().uuidString
        let folder = AppPaths.meetingFolder(id)
        // The archiver keeps its hands off a folder being recorded. Both tracks first: no note is written
        // unless recording can begin.
        guard MeetingArchiver.shared.prepareForRecording(folder: folder), let tracks = openTracks(folder) else {
            try? FileManager.default.removeItem(at: folder)
            showCouldNotStart(leg: nil) { [weak self] in self?.start(call: explicitCall, event: event) }
            return
        }
        // An event start follows only that event's call: one already in it, or one of its service that starts next.
        var target = event.map(Self.target(for:)) ?? CallDetector.Target()
        let call = explicitCall ?? detector?.callForRecording(target)
        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = call?.bundleID ?? front?.bundleIdentifier
        let app = call.map(\.displayName) ?? MeetingApps.name(for: bundleID)
        store.createMeeting(Meeting(id: id, createdAt: Date(), startedAt: Date(), status: .recording, audioPath: folder.path,
                                    sourceApp: app, sourceBundleID: app == nil ? nil : bundleID))
        if let linked = linkCalendarEvent(meetingID: id, event: event, call: call, bundleID: bundleID) {
            target.eventKey = MeetingDetection.eventKey(linked)
            target.eventEnd = linked.end
        }
        autoStoppedMeetingID = nil
        beginLeg(Leg(meetingID: id, startSample: 0, eventKey: target.eventKey), tracks: tracks, call: call, target: target,
                 waitForCall: call == nil && event != nil)
    }

    private static func target(for event: UpcomingEvent) -> CallDetector.Target {
        CallDetector.Target(eventKey: MeetingDetection.eventKey(event), eventEnd: event.end,
                            platform: event.conferenceService.map(MeetingPlatform.init(service:)))
    }

    // MARK: Call detection

    /// Connects call detection: prompts for new calls, optional auto-start, the "Scribe stopping"
    /// banner when the recorded call ends, and auto-resume when it comes back.
    func attach(detector: CallDetector) {
        self.detector = detector
        detector.speechActive = { [weak self] in (self?.micSpeaking ?? false) || (self?.systemSpeaking ?? false) }
        detector.eventKey = { [weak self] call in
            self?.calendarMatch(for: call, includingIntent: false).map { MeetingDetection.eventKey($0.event) }
        }
        detector.onAction = { [weak self] action in self?.handle(action) }
        applyDetectionSettings(settingsStore.settings)
        detector.start()
    }

    func applyDetectionSettings(_ s: AppSettings) {
        detector?.promptsEnabled = s.scribeDetectCalls
        detector?.autoStopEnabled = s.scribeAutoStop
        detector?.includeUnconfirmed = s.scribeDetectCalls
        // Echo cancellation switched during a recording: voice processing gets another chance (it may have
        // failed before), and the meeting microphone restarts with it now, or after dictation.
        if isRecording, s.scribeEchoCancellation != lastEchoSetting {
            lastEchoSetting = s.scribeEchoCancellation
            mic.resetVoiceProcessingFailure()
            if !micPausedForDictation { startMic() }
        }
        // Auto-stop turned off: nothing it started may still stop the recording.
        if !s.scribeAutoStop {
            if flowBar.model.card?.kind == .stopping { dismissCard(); detector?.keepGoing() }
            if isShowing(silenceCardID) { dismissCard() }
        }
    }

    /// The setting `startMic()` last applied.
    private var lastEchoSetting = true

    private func handle(_ action: CallDetector.Action) {
        switch action {
        case .prompt(let call):
            guard !isRecording else { return }
            showDetected(call)
        case .dismissPrompt:
            pendingPrompt = nil
            dismissCard(kind: .detected)
            withdrawNewNoteOffer()
        case .showStopping(let deadline):
            guard isRecording else { return }
            var card = FlowCard(kind: .stopping, title: "Scribe stopping", subtitle: "The call ended",
                                symbol: "stop.circle", primary: "Stop", secondary: "Keep going", deadline: deadline)
            let cardID = card.id
            // [Stop] only brings the auto-stop forward: Resume and auto-resume still apply.
            card.onPrimary = { [weak self] in
                guard let self, self.detector?.expediteStop() != true else { return }
                self.dismissCard(id: cardID)
                self.stop(reason: .callEnded)
            }
            card.onSecondary = { [weak self] in self?.dismissCard(id: cardID); self?.detector?.keepGoing() }
            card.onDismiss = card.onSecondary
            // Never a stop without a visible warning: a banner that can't be shown hands the stop back.
            card.onSuperseded = { [weak self] in self?.detector?.stopHandedBack() }
            if !present(card) { detector?.stopHandedBack() }
        case .cancelStopping:
            dismissCard(kind: .stopping)
        case .stop:
            guard let id = activeMeetingID else { return }
            guard flowBar.model.card?.kind == .stopping else { detector?.stopHandedBack(); return }
            dismissCard(kind: .stopping)
            stop(reason: .callEnded)
            autoStoppedMeetingID = id
            showResumeCard(id, title: "Scribe stopped", subtitle: "The call ended", symbol: "checkmark.circle", seconds: 8)
        case .offerResume(let call):
            guard !isRecording, let id = autoStoppedMeetingID, resume(id, call: call, event: nil) else {
                autoStoppedMeetingID = nil
                detector?.resumeFailed()
                return
            }
            dismissCard(kind: .resume)
            flowBar.flash("Resumed your notes", kind: .info, seconds: 2)
        }
    }

    // MARK: Detected-call card

    /// A prompt that could not be shown yet (a Resume card, the stopping banner or an alert had the slot). Its
    /// timeout waits meanwhile, and starts over when it is shown.
    private var pendingPrompt: DetectedCall? { didSet { if (oldValue == nil) != (pendingPrompt == nil) { updatePromptHold() } } }
    /// The call of the "Meeting detected" card on screen.
    private var detectedCall: DetectedCall?
    /// The user stopped this prompt's countdown (menu opened, screen locked): it never restarts.
    private var countdownCancelled = false
    private var hoveringPrompt = false
    /// The meeting a Resume card on screen is for.
    private var resumeCardMeetingID: String?

    /// "Meeting detected", titled after the calendar event the call belongs to. With auto-start on (and
    /// someone at the Mac), a 10-second countdown starts the Scribe. It never takes the slot from a
    /// Resume card or the stopping banner: it waits, and a call from the stopped meeting's app is offered
    /// on the Resume card as "Start new note".
    private func showDetected(_ call: DetectedCall) {
        guard !isRecording else { return }
        let current = flowBar.model.card
        if let current, [.resume, .stopping, .alert].contains(current.kind) {
            pendingPrompt = call
            if current.kind == .resume, let id = resumeCardMeetingID, isFromSameApp(call, meetingID: id) { offerNewNote(call) }
            return
        }
        pendingPrompt = nil
        let match = calendarMatch(for: call)
        let event = match?.event
        let updating = current?.kind == .detected && detectedCall?.isSameCall(as: call) == true
        if !updating { countdownCancelled = false }
        let auto = !countdownCancelled && mayAutoStart(call, match: match)
        var card = updating ? current! : FlowCard(kind: .detected, title: "", primary: "Start Scribe")
        card.title = event?.displayTitle ?? "Meeting detected"
        card.subtitle = event != nil ? "Meeting detected" : call.displayName
        card.bundleID = call.bundleID
        card.secondary = "Not now"
        card.menu = (event?.conferenceURL != nil ? ["Join meeting", "Start Scribe"] : [])
            + ["Snooze for 2 min", "Start Scribe automatically", "Notification settings"]
        card.checkedMenu = settingsStore.settings.scribeAutoStart ? ["Start Scribe automatically"] : []
        // Card actions only ever remove this card: one picked from its menu after another card took the slot
        // must not take that card away unanswered.
        let cardID = card.id
        let begin: () -> Void = { [weak self] in
            guard let self, !self.isRecording else { return }
            self.dismissCard(id: cardID)
            self.startNotes(call: call, event: event)
        }
        card.onPrimary = begin
        if auto {
            // A countdown already running keeps its deadline when the card is updated.
            if card.onTimeout == nil || card.deadline == nil { card.deadline = Date().addingTimeInterval(10); card.startedAt = Date() }
            card.onTimeout = begin
            card.countdownText = "starting in %d s"
        } else {
            card.deadline = nil
            card.onTimeout = nil
            card.countdownText = nil
        }
        card.onSecondary = { [weak self] in self?.dismissCard(id: cardID); self?.detector?.promptDismissed() }
        card.onDismiss = card.onSecondary
        card.onMenuOpen = { [weak self] in self?.cancelAutoStart() }
        card.onMenu = { [weak self] item in
            guard let self else { return }
            switch item {
            case "Join meeting":
                if let event, let url = event.conferenceURL { self.noteJoinIntent(event); NSWorkspace.shared.open(url) }
            case "Start Scribe":
                begin()
            case "Snooze for 2 min":
                self.dismissCard(id: cardID)
                self.detector?.promptSnoozed()
            case "Start Scribe automatically":
                self.settingsStore.settings.scribeAutoStart.toggle()
                if let prompted = self.detector?.promptedCall, prompted.isSameCall(as: call) { self.showDetected(prompted) }
            case "Notification settings":
                AppRouter.shared.settingsTab = .scribe
                (NSApp.delegate as? AppDelegate)?.openMainWindow(page: "settings")
            default:
                break
            }
        }
        card.onSuperseded = { [weak self] in self?.pendingPrompt = call }
        detectedCall = call
        present(card)
    }

    /// Auto-start needs (as in Wispr Flow): the setting, onboarding done, someone at the Mac, nothing
    /// recording, the microphone allowed and system audio not refused, the speech model, and a call that
    /// may auto-start, or a native call that belongs to a calendar event. Never for a call matched only
    /// because the user just joined an event (Join + Start handles those).
    private func mayAutoStart(_ call: DetectedCall, match: CalendarMatcher.Match?) -> Bool {
        let s = settingsStore.settings
        guard s.scribeAutoStart, s.hasCompletedOnboarding, userPresent, !isRecording, match?.type != .userIntent else { return false }
        let calendarNative = match != nil && MeetingDetection.kind(bundleID: call.bundleID) != .browser
        guard call.qualifiesForAutoStart || calendarNative else { return false }
        let perms = Permissions.shared
        perms.refresh()
        guard perms.microphone == .authorized else { return false }
        if #available(macOS 14.4, *), SystemAudioPermission.status() == .denied { return false }
        if case .missingModel = hub.speechState { return false }
        return true
    }

    /// The calendar event a call belongs to: the event the user just joined (unless `includingIntent` is
    /// false), the same meeting code, or (native Zoom) the event in progress.
    private func calendarMatch(for call: DetectedCall, includingIntent: Bool = true) -> CalendarMatcher.Match? {
        guard let events = calendar?.events, !events.isEmpty else { return nil }
        let intent = includingIntent ? recentJoinIntent : nil
        return CalendarMatcher.matchDetailed(recordingStart: Date(), callURL: call.url.flatMap(URL.init(string:)),
                                             bundleID: call.bundleID, userIntentEventID: intent?.eventID,
                                             userIntentAt: intent?.at, events: events)
    }

    private var recentJoinIntent: (eventID: String, at: Date)? {
        joinIntent.flatMap { Date().timeIntervalSince($0.at) <= CalendarMatcher.userIntentTTL ? $0 : nil }
    }

    private func isFromSameApp(_ call: DetectedCall, meetingID id: String) -> Bool {
        if id == autoStoppedMeetingID, let ended = detector?.endedCall, ended.isSameCall(as: call) { return true }
        return store.meeting(id: id)?.sourceBundleID?.lowercased() == call.bundleID.lowercased()
    }

    /// "Scribe stopped [Resume]" after an auto-stop or sleep.
    private func showResumeCard(_ id: String, title: String, subtitle: String?, symbol: String, seconds: TimeInterval) {
        var card = FlowCard(kind: .resume, title: title, subtitle: subtitle, symbol: symbol, primary: "Resume",
                            deadline: Date().addingTimeInterval(seconds))
        let cardID = card.id
        card.onPrimary = { [weak self] in self?.dismissCard(id: cardID); self?.resume(id) }
        card.onDismiss = { [weak self] in self?.dismissCard(id: cardID) }
        resumeCardMeetingID = id
        guard present(card) else { return }
        if let call = detector?.promptedCall, isFromSameApp(call, meetingID: id) {
            pendingPrompt = call
            offerNewNote(call)
        }
    }

    /// A call prompted while the Resume card is up, from the same app: offered as a new note on that card.
    private func offerNewNote(_ call: DetectedCall) {
        guard var card = flowBar.model.card, card.kind == .resume else { return }
        card.secondary = "Start new note"
        let cardID = card.id
        card.onSecondary = { [weak self] in
            guard let self, !self.isRecording else { return }
            self.dismissCard(id: cardID)
            self.start(call: call, event: self.calendarMatch(for: call)?.event)
        }
        present(card)
    }

    private func withdrawNewNoteOffer() {
        guard var card = flowBar.model.card, card.kind == .resume, card.secondary != nil else { return }
        card.secondary = nil
        card.onSecondary = {}
        present(card)
    }

    // MARK: Calendar link

    /// Names the meeting after the calendar event it belongs to (the one the user picked or just joined,
    /// the call's meeting code, or one happening now) and stores its attendees.
    @discardableResult
    private func linkCalendarEvent(meetingID id: String, event picked: UpcomingEvent?, call: DetectedCall?, bundleID: String?) -> UpcomingEvent? {
        let intent = recentJoinIntent
        let event = picked ?? calendar.flatMap {
            CalendarMatcher.match(recordingStart: Date(), callURL: call?.url.flatMap(URL.init(string:)), bundleID: bundleID,
                                  userIntentEventID: intent?.eventID, userIntentAt: intent?.at, events: $0.events)
        }
        guard let event else { return nil }
        store.setMeetingCalendarEvent(id: id, eventID: event.externalID, occurrenceStart: event.occurrenceStart,
                                      participants: event.attendees)
        if store.meeting(id: id)?.title.isEmpty == true { store.setMeetingTitle(id: id, title: event.title) }
        return event
    }

    // MARK: Resume

    /// Continues a stopped meeting: new audio is appended to the same tracks and transcript. False when
    /// nothing was resumed (the meeting is gone, something is recording, or recording can't start).
    @discardableResult
    func resume(_ id: String) -> Bool { resume(id, call: nil, event: nil) }

    @discardableResult
    private func resume(_ id: String, call explicitCall: DetectedCall?, event: UpcomingEvent?) -> Bool {
        guard !isRecording, let existing = store.meeting(id: id), let existingPath = existing.audioPath else { return false }
        guard !hasUsedMaxLength(existing) else {
            flowBar.flash("This meeting has used its full recording length", kind: .warning, action: "Settings", seconds: 4) {
                AppRouter.shared.settingsTab = .scribe
                (NSApp.delegate as? AppDelegate)?.openMainWindow(page: "settings")
            }
            return false
        }
        guard checkReady(retry: { [weak self] in self?.resume(id, call: explicitCall, event: event) }) else { return false }
        // Stops a compression of this meeting's audio and, if it was compressed, recreates the raw tracks at
        // once (the archived audio is decoded back into them in the background).
        // If that fails, recording would start at position 0, over the earlier legs.
        guard MeetingArchiver.shared.prepareForRecording(folder: URL(fileURLWithPath: existingPath)) else {
            showCouldNotStart(leg: nil) { [weak self] in self?.resume(id, call: explicitCall, event: event) }
            return false
        }
        // A leg left open by a quit or crash is closed first (marker, stop count, its tail queued for transcription).
        if existing.status == .recording || (existing.status == .processing && !processingIDs.contains(id)) { recover(existing) }
        guard var m = store.meeting(id: id), let path = m.audioPath else { return false }
        let folder = URL(fileURLWithPath: path)
        guard let tracks = openTracks(folder) else {
            showCouldNotStart(leg: nil) { [weak self] in self?.resume(id, call: explicitCall, event: event) }
            return false
        }
        let before = m
        let position = max(tracks.mic.sampleCount, tracks.system.sampleCount)
        let marker = store.addSegment(MeetingSegment(meetingID: id, source: .marker, startMs: position / 16, endMs: position / 16,
                                                     marker: .resumed, epoch: Date()))
        m.status = .recording
        m.error = nil
        store.updateMeetingState(m)

        var target = event.map(Self.target(for:)) ?? CallDetector.Target()
        target.isResume = true
        if event == nil, let eid = m.calendarEventID, let occurrence = m.calendarOccurrenceStart {
            target.eventKey = MeetingDetection.eventKey(externalID: eid, occurrenceStart: occurrence)
            target.eventEnd = calendar?.events.first { MeetingDetection.eventKey($0) == target.eventKey }?.end
        }
        // The note that just stopped by itself follows its own call again.
        if id == autoStoppedMeetingID { target.previousCall = detector?.endedCall }
        let call = explicitCall ?? detector?.callForRecording(target)
        beginLeg(Leg(meetingID: id, startSample: position, resumedSeq: marker.seq, before: before, eventKey: target.eventKey),
                 tracks: tracks, call: call, target: target, waitForCall: false)
        return true
    }

    /// `retry` runs once microphone access is granted from the system prompt.
    private func checkReady(retry: @escaping () -> Void) -> Bool {
        let perms = Permissions.shared
        perms.refresh()
        switch perms.microphone {
        case .authorized: break
        case .notDetermined:
            Task { if await perms.requestMicrophone() { retry() } }
            return false
        default:
            flowBar.flash("Scribe needs microphone access", kind: .error, action: "Fix", seconds: 4) { perms.open(.microphone) }
            return false
        }
        if case .missingModel(let name) = hub.speechState {
            flowBar.flash("\(name) is not downloaded", kind: .warning, action: "Models", seconds: 4) {
                (NSApp.delegate as? AppDelegate)?.openMainWindow(page: "models")
            }
            return false
        }
        return true
    }

    /// Opens (creating if needed) both track files of a meeting folder; nil when they can't be written.
    private func openTracks(_ folder: URL) -> (mic: MeetingTrack, system: MeetingTrack)? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return (try MeetingTrack(source: .mic, url: folder.appendingPathComponent("mic.pcm")),
                    try MeetingTrack(source: .system, url: folder.appendingPathComponent("system.pcm")))
        } catch {
            return nil
        }
    }

    private func beginLeg(_ leg: Leg, tracks: (mic: MeetingTrack, system: MeetingTrack), call: DetectedCall?,
                          target: CallDetector.Target, waitForCall: Bool) {
        let id = leg.meetingID
        let micT = tracks.mic, sysT = tracks.system
        // Both tracks start every leg at the same position.
        let start = max(micT.sampleCount, sysT.sampleCount)
        micT.pad(toLength: start); sysT.pad(toLength: start)
        let tr = transcriber
        micT.onSegment = { tr.submit(.init(meetingID: id, source: .mic, segment: $0)) }
        sysT.onSegment = { tr.submit(.init(meetingID: id, source: .system, segment: $0)) }
        let now = MeetingClock.now()
        micT.beginLeg(at: now); sysT.beginLeg(at: now)
        legClock = (start, now)
        micTrack = micT; systemTrack = sysT
        recordedBeforeLeg = Double(start) / 16_000
        legStartDate = Date()
        self.leg = leg
        // A Resume makes the stopped leg's "Started by mistake?" check stale, and earlier failures may show again.
        // A card already asking about it goes (not answered: the leg stays, and this leg's stop asks again).
        stoppedLegs[id] = nil
        if let cardID = legCards.removeValue(forKey: id), isShowing(cardID) { dismissCard(id: cardID) }
        reportedFailure.remove(id)
        activeMeetingID = id
        notices = []
        micPausedForDictation = false
        lastTickAt = nil; lastMicBuffers = mic.bufferStats.buffers; silentSeconds = 0; legLines = 0; lastLineAt = nil
        lineSinceTick = false; maxWarnedCap = nil; checkInShown = false; sleptMeetingID = nil
        systemLiveness = SystemAudioLiveness(); deniedRebuilds = 0; micStallCardShown = false; storageCardShown = false

        mic.resetVoiceProcessingFailure()
        // Microphone first: it also gives Shout the audio process object the system tap excludes.
        // If dictation holds the microphone right now, the meeting microphone waits for it to finish.
        if isDictating?() == true {
            micPausedForDictation = true
            lastEchoSetting = settingsStore.settings.scribeEchoCancellation
            store.addSegment(MeetingSegment(meetingID: id, source: .marker, startMs: start / 16, endMs: start / 16,
                                            marker: .dictated, epoch: Date()))
        } else {
            startMic()
        }
        startSystemAudio()

        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Keeps the display awake (and so the Mac) while recording, as Wispr Flow does.
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Shout is recording a meeting" as CFString, &displayAssertion)
        flowBar.model.meeting = FlowBarModel.MeetingPill(startedAt: Date().addingTimeInterval(-recordedBeforeLeg))
        flowBar.layout(animated: false)
        let bound = detector?.recordingStarted(call: call, target: target)
        speakerTimeline = SpeakerTimeline(leg: leg.resumedSeq ?? 0)
        speakerAliases = store.speakerAliases(meetingID: id)
        updateSpeakerPoller()
        if settingsStore.settings.scribeOpenNotepad {
            onOpenNotepad?(id, false)
            if settingsStore.settings.scribeSplitScreen {
                // Split screen only ever moves the recorded call's own window.
                if let pid = bound?.pid {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.onSplitScreen?(pid) }
                } else if waitForCall {
                    // Join + Start: the call app is whatever opens the link; split once its call is followed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                        guard let self, self.activeMeetingID == id, let pid = self.detector?.boundCall?.pid else { return }
                        self.onSplitScreen?(pid)
                    }
                }
            }
        }
    }

    private func startMic() {
        guard let track = micTrack else { return }
        lastMicRetry = Date()
        let echo = settingsStore.settings.scribeEchoCancellation
        lastEchoSetting = echo
        mic.onSamples = { [weak track] samples, time in track?.append(samples, at: time) }
        // Every (re)start, including the microphone's own (device change, watchdog, Core Audio restart),
        // places its first audio exactly.
        mic.onDiscontinuity = { [weak track] in track?.realign() }
        track.realign()
        // Returns at once: the voice-processing unit comes up on the microphone's queue and `onRestart`
        // reports the outcome (the dictation hand-off never waits for it).
        do { try mic.start(voiceProcessing: echo) } catch { addNotice(.micUnavailable(error.localizedDescription)) }
        updateEchoNotice()
    }

    private func startSystemAudio() {
        guard let track = systemTrack else { return }
        guard #available(macOS 14.4, *) else {
            addNotice(.systemAudioUnavailable("Recording other people needs macOS 14.4 or later. Only your microphone is recorded."))
            return
        }
        let capture = SystemAudioCapture()
        capture.onSamples = { [weak track] samples, time in track?.append(samples, at: time) }
        // Every rebuild, including the capture's own (device death, rate change, Core Audio restart),
        // places its first audio exactly.
        capture.onDiscontinuity = { [weak track] in track?.realign() }
        // Kept even when the first start fails: the watchdog retries it.
        systemCapture = capture
        let meeting = activeMeetingID
        let mic = self.mic
        // Starting asks for the permission first and builds off the main thread (the first build can
        // wait on the macOS prompt).
        Task { @MainActor [weak self] in
            do {
                // The microphone first: once it runs, Shout's audio process object exists and the tap
                // can exclude Shout's own sounds.
                await mic.settled()
                try await capture.start()
            } catch SystemAudioCapture.CaptureError.permissionDenied {
                guard self?.activeMeetingID == meeting else { return }
                self?.addNotice(.systemAudioDenied)
            } catch is CancellationError {
                return
            } catch {
                guard self?.activeMeetingID == meeting else { return }
                self?.addNotice(.systemAudioUnavailable(error.localizedDescription))
            }
            self?.permissionsRefresh()
        }
    }

    private func permissionsRefresh() { Permissions.shared.refresh() }

    /// 1 Hz: keeps system-audio capture alive.
    /// - Failed: retried every 5 s (when denied, once the permission says allowed).
    /// - No callbacks (stalled): rebuilt with the same layout; the capture moves to the output-device
    ///   layout only after two such rebuilds in a row, and only for an output device without a microphone
    ///   that isn't Bluetooth (it would pull a headset's mic into the aggregate and put it into call mode).
    /// - Only exact silence while other apps play (`SystemAudioLiveness`): rebuilt on a ladder, then a notice.
    @available(macOS 14.4, *)
    private func superviseSystemAudio(_ cap: SystemAudioCapture, stats ss: MeetingTrack.Stats, legSeconds: Double) {
        let s = settingsStore.settings
        if let failure = cap.failure {
            if case SystemAudioCapture.CaptureError.permissionDenied = failure {
                // Denied: nothing to rebuild until the user allows it; check again now and then (3 s, backing
                // off to a minute if the probe keeps failing although the permission says allowed).
                addNotice(.systemAudioDenied)
                if SystemAudioPermission.status(maxAge: 5) == .authorized,
                   cap.secondsSinceRestart >= Double(min(60, 3 << min(deniedRebuilds, 5))) {
                    deniedRebuilds += 1
                    cap.restart(.other)
                }
                return
            }
            if cap.secondsSinceRestart >= 5 { cap.restart(.other) }
            addNotice(.systemAudioUnavailable(failure.localizedDescription))
            return
        }
        notices.removeAll { if case .systemAudioUnavailable(let t) = $0 { return t != Self.storageFullText }; return false }
        deniedRebuilds = 0
        // Never while building (the first build can wait on the permission prompt) or right after a Core
        // Audio restart (the capture rebuilds itself then).
        if cap.isStalled() {
            if cap.secondsSinceRestart >= 10 { cap.restart(.stall) }
            return
        }
        // A tap that delivers only exact zeros although other apps are playing is dead.
        let othersPlaying = ss.zeroRunSeconds >= 1 && !cap.isBuilding && SystemAudioCapture.isOtherAudioPlaying(call: detector?.boundCall)
        switch systemLiveness.tick(now: MeetingClock.now(), zeroRunSeconds: ss.zeroRunSeconds, lastHeard: ss.lastNonZeroTime,
                                   heardAny: ss.nonZeroSeen, othersPlaying: othersPlaying) {
        case .rebuild:
            NSLog("Shout: system audio is silent while other apps play; rebuilding the tap")
            cap.restart(.other)
        case .showSilentNotice: addNotice(.systemAudioSilent)
        case .clearSilentNotice: notices.removeAll { $0 == .systemAudioSilent }
        case .none: break
        }
        if ss.nonZeroSeen {
            if !systemLiveness.noticeShown { notices.removeAll { $0 == .systemAudioSilent || $0 == .systemAudioDenied } }
            if s.scribeSystemAudio != .working { settingsStore.settings.scribeSystemAudio = .working }
        } else {
            // With the permission known to be granted, silence with nothing playing just means nobody has
            // spoken yet.
            let permission = SystemAudioPermission.status(maxAge: 5)
            if permission == .denied { addNotice(.systemAudioDenied) }
            else if legSeconds >= 45 && permission != .authorized && !notices.contains(.systemAudioSilent) {
                addNotice(.systemAudioSilent)
                if s.scribeSystemAudio == .unknown { settingsStore.settings.scribeSystemAudio = .silent }
            }
        }
    }

    private func updateEchoNotice() {
        notices.removeAll { $0 == .noEchoCancellation }
        if settingsStore.settings.scribeEchoCancellation && mic.isRunning && !mic.echoCancellation {
            addNotice(.noEchoCancellation)
        }
    }

    private func addNotice(_ n: Notice) { if !notices.contains(n) { notices.append(n) } }

    // MARK: Stop

    /// Stops the recording; `endedAt` is when it ended (the moment of sleep for a sleep stop).
    func stop(reason: StopReason = .user, at endedAt: Date = Date()) {
        guard let id = activeMeetingID else { return }
        speakerPoller?.stop()
        speakerPoller = nil
        mic.stop()
        if #available(macOS 14.4, *) { (systemCapture as? SystemAudioCapture)?.stop() }
        systemCapture = nil
        let closed = closeTracks(at: MeetingClock.now())
        micTrack = nil; systemTrack = nil
        endSpeakerTimeline(meetingID: id, atMs: closed.length / 16)

        tickTimer?.invalidate(); tickTimer = nil
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        activeMeetingID = nil
        legStartDate = nil
        micSpeaking = false; systemSpeaking = false; micPausedForDictation = false
        flowBar.model.meeting = nil
        flowBar.layout(animated: false)
        switch reason {
        case .sleep: detector?.recordingStopped(.suspended, at: endedAt)
        case .userSwitch: detector?.recordingStopped(.interrupted, at: endedAt)
        default: detector?.recordingStopped(.user, at: endedAt)
        }

        var stopSeq: Int?
        if var m = store.meeting(id: id) {
            m.recordedMs = closed.length / 16
            m.endedAt = endedAt
            m.latestStopSeq += 1
            m.status = .processing
            m.hasSystemAudio = m.hasSystemAudio || closed.heardSystem
            store.updateMeetingState(m)
            stopSeq = m.latestStopSeq
        }
        store.addSegment(MeetingSegment(meetingID: id, source: .marker, startMs: closed.length / 16, endMs: closed.length / 16,
                                        marker: .stopped, epoch: endedAt))
        switch reason {
        case .maxLength: flowBar.flash("Scribe stopped at the maximum length", kind: .info, seconds: 4)
        case .noSpeech: flowBar.flash("Scribe stopped: no one spoke for 10 minutes", kind: .info, seconds: 4)
        case .user, .sleep, .quit, .callEnded, .userSwitch: break
        }
        // Checked once transcribed: a leg with almost no words may have been started by mistake.
        if var leg, reason != .userSwitch && reason != .quit {
            leg.stopSeq = stopSeq
            stoppedLegs[id] = (leg, closed.captured)
        }
        leg = nil
        dismissCard(kind: .info)
        finishTranscription(id)
    }

    /// Ends the leg on both tracks at host time `time` and closes them. A source that never delivered
    /// audio this leg is extended with a sparse zero region instead of a leg of silence being written and
    /// run through speech detection on the main thread.
    private func closeTracks(at time: Double) -> (length: Int, captured: Bool, heardSystem: Bool) {
        let tracks = [micTrack, systemTrack].compactMap { $0 }
        let delivered = tracks.map { $0.stats.delivered }
        var length = 0
        for (t, d) in zip(tracks, delivered) {
            length = max(length, d ? t.endLeg(at: time) : max(t.position(at: time), t.sampleCount))
        }
        for (t, d) in zip(tracks, delivered) where d { t.pad(toLength: length) }
        let heardSystem = systemTrack?.stats.nonZeroSeen ?? false
        tracks.forEach { $0.close() }
        for (t, d) in zip(tracks, delivered) where !d { Self.resize(t.url, toSamples: length) }
        return (length, delivered.contains(true), heardSystem)
    }

    /// Grows (sparse zeros) or truncates a track file to `count` samples.
    private nonisolated static func resize(_ url: URL, toSamples count: Int) {
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        try? h.truncate(atOffset: UInt64(max(0, count) * 2))
    }

    /// "Started by mistake?" after a leg with almost no words. Discard removes the note, or only this
    /// leg of a resumed one.
    private func offerDiscard(_ leg: Leg) {
        var card = FlowCard(kind: .alert, title: "Started by mistake?",
                            subtitle: "Only a few words were captured. Keep this meeting or discard it.",
                            symbol: "trash", primary: "Keep", secondary: "Discard", deadline: Date().addingTimeInterval(60))
        let cardID = card.id
        let keep: () -> Void = { [weak self] in self?.dismissCard(id: cardID); self?.settle(leg, card: cardID, discard: false) }
        card.onPrimary = keep
        card.onSecondary = { [weak self] in self?.dismissCard(id: cardID); self?.settle(leg, card: cardID, discard: true) }
        card.onDismiss = keep
        card.onTimeout = { [weak self] in self?.settle(leg, card: cardID, discard: false) }
        card.onSuperseded = card.onTimeout
        legCards[leg.meetingID] = cardID
        if !present(card) { settle(leg, card: cardID, discard: false) }
    }

    /// "Couldn't start recording": the track files could not be created (`leg` nil), or `leg` captured no
    /// audio. Unless the user tries again, such a leg is removed, so "nothing was saved" holds; a first leg's
    /// note is kept only when the user typed notes in it.
    private func showCouldNotStart(leg: Leg?, retry: @escaping () -> Void) {
        var card = FlowCard(kind: .alert, title: "Couldn't start recording",
                            subtitle: "We couldn't capture any audio, so nothing was saved.",
                            symbol: "exclamationmark.triangle", primary: "Try again", secondary: "Discard",
                            deadline: Date().addingTimeInterval(6))
        let cardID = card.id
        let drop: (Bool) -> Void = { [weak self] asked in
            guard let self, let leg else { return }
            let notes = self.store.meeting(id: leg.meetingID)?.notes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.settle(leg, card: cardID, discard: asked || leg.before != nil || notes.isEmpty)
        }
        card.onPrimary = { [weak self] in
            self?.dismissCard(id: cardID)
            if let leg, self?.legCards[leg.meetingID] == cardID { self?.legCards[leg.meetingID] = nil }
            retry()
        }
        card.onSecondary = { [weak self] in self?.dismissCard(id: cardID); drop(true) }
        card.onDismiss = { [weak self] in self?.dismissCard(id: cardID); drop(false) }
        card.onTimeout = { drop(false) }
        card.onSuperseded = card.onTimeout
        if let leg { legCards[leg.meetingID] = cardID }
        if !present(card) { drop(false) }
    }

    /// The answer to a stopped leg's card: keep (its audio is compressed now) or discard it. Nothing happens
    /// once the note has been resumed since: the newer leg is not this card's to keep or discard.
    private func settle(_ leg: Leg, card: UUID, discard: Bool) {
        if legCards[leg.meetingID] == card { legCards[leg.meetingID] = nil }
        guard isLatestStop(leg) else { return }
        if discard { self.discard(leg) } else { archiveAudio(leg.meetingID) }
    }

    /// `leg` is still the last of its note: not recording, and no Resume since it stopped.
    private func isLatestStop(_ leg: Leg) -> Bool {
        guard activeMeetingID != leg.meetingID, let seq = leg.stopSeq else { return false }
        return store.meeting(id: leg.meetingID)?.latestStopSeq == seq
    }

    /// Removes a leg: the whole note for a first leg; for a resumed one, its audio, transcript and markers,
    /// and the note's length, end and stop count as they were before it.
    private func discard(_ leg: Leg) {
        let id = leg.meetingID
        guard isLatestStop(leg) else { return }
        guard let before = leg.before, let resumedSeq = leg.resumedSeq else {
            store.deleteMeeting(id: id)
            return
        }
        let startMs = leg.startSample / 16
        for s in store.segments(meetingID: id) where s.seq >= resumedSeq && s.startMs >= startMs { store.deleteSegment(id: s.id) }
        store.deleteSpeakerSpans(meetingID: id, leg: resumedSeq)
        guard var m = store.meeting(id: id) else { return }
        m.recordedMs = before.recordedMs
        m.endedAt = before.endedAt
        m.latestStopSeq = before.latestStopSeq
        m.hasSystemAudio = before.hasSystemAudio
        m.status = .complete
        store.updateMeetingState(m)
        // Cuts the leg's audio whether it is still raw or already compressed, then compresses it again.
        if let path = before.audioPath, activeMeetingID != id {
            MeetingArchiver.shared.trim(folder: URL(fileURLWithPath: path), toFrames: leg.startSample)
        }
    }

    /// Compresses a stopped, transcribed meeting's raw tracks into `audio.m4a` in the background (see
    /// `MeetingArchive`). If that fails the raw tracks stay; a Resume cancels it.
    private func archiveAudio(_ id: String) {
        guard activeMeetingID != id, let path = store.meeting(id: id)?.audioPath else { return }
        MeetingArchiver.shared.archive(folder: URL(fileURLWithPath: path))
    }

    /// Words transcribed in a leg (lines from its start on).
    private func words(in leg: Leg) -> Int {
        store.segments(meetingID: leg.meetingID)
            .filter { $0.marker == nil && !$0.latched && $0.startMs >= leg.startSample / 16 }
            .reduce(0) { $0 + TextRules.wordCount($1.displayText) }
    }

    private func finishTranscription(_ id: String) {
        processingIDs.insert(id)
        let tr = transcriber
        Task {
            await tr.waitUntilDone(id)
            processingIDs.remove(id)
            // Every line is in: the names are worked out again from all of the meeting's readings.
            relabelSpeakers(id)
            let stopped = stoppedLegs.removeValue(forKey: id)
            // A resumed meeting is recording again; leave its status alone.
            guard activeMeetingID != id, var m = store.meeting(id: id), m.status == .processing else { return }
            m.status = .complete
            store.updateMeetingState(m)
            // The audio is compressed now, or once the leg's card is answered (Discard trims it first).
            var archiveNow = true
            if let (leg, captured) = stopped {
                if !captured {
                    showCouldNotStart(leg: leg) { [weak self] in self?.resume(id) }
                    archiveNow = false
                } else if words(in: leg) < 20 {
                    offerDiscard(leg)
                    archiveNow = false
                }
            }
            if archiveNow { archiveAudio(id) }
            let titling = titleIfBlank(id)
            // The first summary is written automatically for meetings longer than 5 minutes, and again after
            // a Resume when the earlier attempt found nothing to summarize (or failed). It waits for the
            // title, so the two don't evict each other's cache.
            let noRealSummary = m.summaryStatus == .none
                || ([.tooShort, .noSpeech, .failed].contains(m.summaryStatus) && m.summaryIsStale)
            if settingsStore.settings.scribeAutoSummarize && m.duration > 300 && noRealSummary {
                Task { [weak self] in
                    await titling?.value
                    self?.summarize(id, rerun: false)
                }
            }
        }
    }

    // MARK: Titles

    /// Names a meeting that still has no title from its transcript and notes (at every stop, whatever its
    /// length), when there is a language model to use (`titleGenerator`).
    @discardableResult
    private func titleIfBlank(_ id: String) -> Task<Void, Never>? {
        if let t = titleTasks[id] { return t }
        let name = settingsStore.settings.userName
        let task = Task { [weak self] in
            guard let self else { return }
            await self.store.generateTitleIfBlank(meetingID: id, userName: name.isEmpty ? nil : name) { [weak self] in
                try await self?.titleGenerator()
            }
            self.titleTasks[id] = nil
        }
        titleTasks[id] = task
        return task
    }

    /// The language model for a title. It is loaded for one only when the auto-summary needs it anyway;
    /// otherwise a title is written only while a model is already loaded.
    private func titleGenerator() async throws -> TextGenerator? {
        let base = settingsStore.settings.scribeAutoSummarize ? try await hub.generatorLoadingIfNeeded()
                                                                  : try await hub.currentGenerator()
        return base.map { YieldingGenerator($0) { @MainActor [weak self] in self?.isDictating?() ?? false } }
    }

    // MARK: Cards above the Flow Bar

    private var cardTimer: Timer?

    /// Shows a card in the Flow Bar's single slot (Wispr Flow's rules). A card is refused (false) while a
    /// more important one is up, and an information card while any other card is: tick-driven cards retry
    /// on the next tick. A more important card supersedes the one on screen, whose `onSuperseded` re-arms
    /// its source. Presenting the card on screen again (same id) updates it in place.
    @discardableResult
    func present(_ card: FlowCard) -> Bool {
        let current = flowBar.model.card
        if let current, current.id != card.id {
            let replaces = card.priority > current.priority || (card.priority == current.priority && card.kind != .info)
            guard replaces else { return false }
        }
        var card = card
        card.onHover = { [weak self, id = card.id] inside in self?.cardHovered(inside, id: id) }
        if card.kind != .detected && current?.kind == .detected { hoveringPrompt = false; updatePromptHold() }
        show(card)
        if let current, current.id != card.id { current.onSuperseded?() }
        return true
    }

    /// Removes the card `id` if it is still the one on screen. Card actions use this: one that runs after its
    /// card was replaced (picked from its menu meanwhile) never removes the successor unanswered.
    private func dismissCard(id: UUID) {
        guard flowBar.model.card?.id == id else { return }
        dismissCard()
    }

    func dismissCard(kind: FlowCard.Kind? = nil) {
        guard let card = flowBar.model.card, kind == nil || card.kind == kind else { return }
        cardTimer?.invalidate()
        flowBar.model.card = nil
        if card.kind == .detected { hoveringPrompt = false; updatePromptHold() }
        slotFreed()
    }

    private func show(_ card: FlowCard) {
        flowBar.model.card = card
        flowBar.layout(animated: false)
        scheduleCardTimer(card)
    }

    /// Runs `onTimeout` at the deadline. The stopping banner's deadline belongs to call detection.
    private func scheduleCardTimer(_ card: FlowCard) {
        cardTimer?.invalidate()
        cardTimer = nil
        guard let deadline = card.deadline, card.pausedAt == nil, card.kind != .stopping else { return }
        cardTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, deadline.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let shown = self.flowBar.model.card, shown.id == card.id, shown.pausedAt == nil else { return }
                self.flowBar.model.card = nil
                if shown.kind == .detected { self.hoveringPrompt = false; self.updatePromptHold() }
                shown.onTimeout?()
                self.slotFreed()
            }
        }
    }

    /// The pointer rests on a card: its countdown and progress stand still (a prompt's timeout too) and
    /// continue where they were when it leaves.
    private func cardHovered(_ inside: Bool, id: UUID) {
        guard var card = flowBar.model.card, card.id == id else { return }
        if card.kind == .detected { hoveringPrompt = inside; updatePromptHold() }
        guard card.kind != .stopping, let deadline = card.deadline else { return }
        if inside, card.pausedAt == nil {
            card.pausedAt = Date()
            cardTimer?.invalidate()
            flowBar.model.card = card
        } else if !inside, let paused = card.pausedAt {
            let pause = Date().timeIntervalSince(paused)
            card.pausedAt = nil
            card.deadline = deadline.addingTimeInterval(pause)
            card.startedAt = card.startedAt.addingTimeInterval(pause)
            flowBar.model.card = card
            scheduleCardTimer(card)
        }
    }

    /// The Flow Bar saw the pointer away from card `id` (30 Hz). The hover's end can get lost (the panel turns
    /// click-through before SwiftUI sees the exit), which would leave the card paused for good.
    private func pointerLeftCard(_ id: UUID) {
        guard let card = flowBar.model.card, card.id == id,
              card.pausedAt != nil || (card.kind == .detected && hoveringPrompt) else { return }
        cardHovered(false, id: id)
    }

    /// The prompt's timeout stands still while the pointer is on its card, nobody is at the Mac, or it waits
    /// behind another card (it would otherwise time out unseen and its call be latched).
    private func updatePromptHold() { detector?.holdPrompt(hoveringPrompt || !userPresent || pendingPrompt != nil) }

    /// A card left the slot: a prompt that had to wait is shown now if its call is still prompted.
    private func slotFreed() {
        guard pendingPrompt != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.flowBar.model.card == nil, let pending = self.pendingPrompt else { return }
            self.pendingPrompt = nil
            if let call = self.detector?.promptedCall, call.isSameCall(as: pending) { self.showDetected(call) }
        }
    }

    private func isShowing(_ id: UUID?) -> Bool { id != nil && flowBar.model.card?.id == id }

    /// Calendar reminder before a scheduled meeting. It gives way to every other card and comes back
    /// once the slot is free (a newer reminder simply replaces it).
    func showReminder(_ event: UpcomingEvent) { showReminder(event, again: false) }

    private func showReminder(_ event: UpcomingEvent, again: Bool) {
        guard event.end > Date(), !(again && flowBar.model.card?.kind == .reminder) else { return }
        let retry: () -> Void = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.showReminder(event, again: true) }
        }
        var card: FlowCard
        let joinOnly = isRecording
        if joinOnly {
            // While recording, only other meetings remind, and only to join them.
            if let id = activeMeetingID, store.meeting(id: id)?.calendarEventID == event.externalID { return }
            guard event.conferenceURL != nil else { return }
            card = FlowCard(kind: .reminder, title: event.title, subtitle: CalendarText.relativeLabel(event, now: Date()),
                            symbol: "calendar", primary: "Join Meeting", deadline: Date().addingTimeInterval(60))
        } else {
            let hasLink = event.conferenceURL != nil
            card = FlowCard(kind: .reminder, title: event.title,
                            subtitle: [CalendarText.relativeLabel(event, now: Date()), event.platform].compactMap { $0 }.joined(separator: " · "),
                            symbol: "calendar", primary: hasLink ? "Join & Start" : "Start Scribe",
                            menu: (hasLink ? ["Join Meeting Only", "Start Scribe Only"] : []) + ["Snooze for 2 Minutes"],
                            deadline: Date().addingTimeInterval(120))
        }
        let cardID = card.id
        card.onPrimary = { [weak self] in
            self?.dismissCard(id: cardID)
            if joinOnly { self?.noteJoinIntent(event) }
            if let url = event.conferenceURL { NSWorkspace.shared.open(url) }
            if !joinOnly { self?.start(event: event) }
        }
        card.onMenu = { [weak self] item in
            self?.dismissCard(id: cardID)
            switch item {
            case "Join Meeting Only":
                if let url = event.conferenceURL { self?.noteJoinIntent(event); NSWorkspace.shared.open(url) }
            case "Start Scribe Only": self?.start(event: event)
            default:
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.showReminder(event) }
            }
        }
        card.onDismiss = { [weak self] in self?.dismissCard(id: cardID) }
        card.onSuperseded = retry
        if !present(card) { retry() }
    }

    // MARK: Summaries

    /// Writes (or rewrites) the meeting's summary, title and action items with the local language model.
    /// Runs as background work: it pauses whenever the user dictates.
    /// `rerun`: write it again even when the summary is ready and current (Generate, Update, Regenerate, Try Again).
    /// `allowShort`: "Summarize Anyway" only; skips the too-short check. A meeting that already has a summary
    /// was allowed once, so it skips the check too, and a rewrite never replaces a summary (or the user's
    /// edits) with "too short" or "no speech".
    func summarize(_ id: String, rerun: Bool, allowShort: Bool = false) {
        guard summaryTasks[id] == nil, activeMeetingID != id, let m = store.meeting(id: id) else { return }
        if !rerun && m.summaryStatus == .ready && !m.summaryIsStale { return }
        // An automatic summary waits for the transcript's tail (its transcription summarizes when done).
        if !rerun && processingIDs.contains(id) { return }
        let hadSummary = !(m.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let previousItems = MeetingSummarizer.actionItems(in: m.summary ?? "").map(\.text)
        let s = settingsStore.settings
        let input = MeetingSummaryInput(title: m.title, date: m.createdAt, participants: m.participants,
                                        userName: s.userName.isEmpty ? nil : s.userName, notes: m.notes,
                                        segments: store.segments(meetingID: id))
        let stopSeq = m.latestStopSeq
        let wantTitle = m.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        store.setSummaryStatus(id: id, .generating)
        summaryStage[id] = "Reading the transcript…"
        summaryTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.summaryTasks[id] = nil; self.summaryStage[id] = nil }
            do {
                guard let base = try await self.hub.generatorLoadingIfNeeded() else {
                    throw TextGeneratorError.unavailable("Summaries need a language model. Choose one in Models.")
                }
                let generator = YieldingGenerator(base) { @MainActor [weak self] in self?.isDictating?() ?? false }
                let summary = try await MeetingSummarizer.summarize(input, generator: generator, wantTitle: wantTitle,
                                                                    contextTokens: base.contextTokens,
                                                                    allowShort: allowShort || hadSummary) { stage in
                    Task { @MainActor [weak self] in
                        // A stage that lands after the task ended would stay on screen (its defer clears the stage).
                        guard let self, self.summaryTasks[id] != nil else { return }
                        self.summaryStage[id] = Self.stageText(stage)
                    }
                }
                switch summary.outcome {
                case .summary:
                    self.store.setSummary(id: id, markdown: summary.markdown, overview: summary.overview, status: .ready, stopSeq: stopSeq)
                    if wantTitle, let title = summary.title, self.store.meeting(id: id)?.title.isEmpty == true {
                        self.store.setMeetingTitle(id: id, title: title)
                    }
                    let userName = self.settingsStore.settings.userName
                    self.store.addGeneratedTasks(meetingID: id, items: summary.actionItems.map { ($0.owner, $0.text) },
                                                 previous: previousItems, userName: userName.isEmpty ? nil : userName)
                    self.announceSummaryReady(id)
                case .tooShort, .noSpeech:
                    if hadSummary {
                        // The existing summary (and the user's edits) stays, as it was.
                        self.store.setSummaryStatus(id: id, .ready)
                    } else {
                        self.store.setSummary(id: id, markdown: nil, overview: nil,
                                              status: summary.outcome == .tooShort ? .tooShort : .noSpeech, stopSeq: stopSeq)
                    }
                }
            } catch is CancellationError {
                self.store.setSummaryStatus(id: id, hadSummary ? .ready : .none)
            } catch {
                self.store.setSummaryStatus(id: id, .failed, error: error.localizedDescription)
            }
            self.hub.primeCleanupCache(self.settingsStore.settings)
        }
    }

    /// The old flag meant both.
    func summarize(_ id: String, force: Bool) { summarize(id, rerun: force, allowShort: force) }

    /// "Your summary is ready!", once per summary, unless the meeting is already in front of the user.
    private func announceSummaryReady(_ id: String) {
        guard store.claimSummaryReadyNotification(id: id), let m = store.meeting(id: id) else { return }
        let frontmost = isMeetingFrontmost?(id)
            ?? (NSApp.isActive && AppRouter.shared.page == .scribe && AppRouter.shared.meetingID == id)
        guard !frontmost else { return }
        let text = MeetingSummarizer.readyNotification(meetingTitle: m.title)
        summaryNotifier.post(meetingID: id, title: text.title, body: text.body)
    }

    private static func stageText(_ stage: MeetingSummaryStage) -> String {
        switch stage {
        case .reading(let part, let total): total > 1 ? "Reading part \(part) of \(total)…" : "Reading the transcript…"
        case .writing: "Writing the summary…"
        case .titling: "Choosing a title…"
        }
    }

    /// Quit: flush both tracks synchronously. Untranscribed audio is picked up at the next launch. What the speaker
    /// poller turned on in the meeting app is turned off now, before the process exits.
    func stopForQuit() {
        if isRecording { stop(reason: .quit) }
        AXWakeRegistry.shared.restoreAll()
    }

    // MARK: Dictation hand-off

    /// The dictation recorder needs the microphone: pause the meeting microphone (system audio keeps
    /// recording) and mark the gap so the transcript shows why "You" went quiet.
    func dictationWillStart() {
        guard isRecording, !micPausedForDictation, let id = activeMeetingID, let track = micTrack else { return }
        // Even a microphone that is down (being retried) counts as paused, so the retry waits for dictation.
        if mic.isRunning { mic.stop() }
        micPausedForDictation = true
        let position = track.position(at: MeetingClock.now())
        store.addSegment(MeetingSegment(meetingID: id, source: .marker, startMs: position / 16, endMs: position / 16,
                                        marker: .dictated, epoch: Date()))
    }

    /// The dictation recorder stopped (key-up, cancel or failure), before the dictation is transcribed and
    /// pasted. The meeting microphone restarts after the caller returns (never on the dictation's own path,
    /// and `startMic` doesn't wait for the voice-processing unit), unless another dictation began meanwhile.
    func dictationDidEnd() {
        guard isRecording, micPausedForDictation else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording, self.micPausedForDictation, self.isDictating?() != true else { return }
            self.micPausedForDictation = false
            self.startMic()
        }
    }

    // MARK: Transcription results

    private func handle(_ job: MeetingTranscriber.Job, _ result: Result<String, Error>) {
        switch result {
        case .success(let text):
            guard !text.isEmpty else { return }
            var line = MeetingSegment(meetingID: job.meetingID, source: job.source, startMs: job.segment.startMs,
                                      endMs: job.segment.endMs, text: text)
            if let name = speakerName(forNewLine: line) { line.speaker = name; line.speakerOrigin = .ax }
            let seg = store.addSegment(line)
            if job.meetingID == activeMeetingID, job.segment.start >= (leg?.startSample ?? 0) {
                legLines += 1
                lastLineAt = Date()
                lineSinceTick = true
                silentSeconds = 0
                // Someone spoke: the meeting is still going.
                if isShowing(silenceCardID) { dismissCard() }
            }
            // A good line after a failure: the failure no longer stands, and a later one is reported again.
            if reportedFailure.remove(job.meetingID) != nil {
                if var m = store.meeting(id: job.meetingID), m.error != nil {
                    m.error = nil
                    store.updateMeetingState(m)
                }
                notices.removeAll { if case .transcriptionFailed = $0 { return true }; return false }
            }
            removeEcho(around: seg)
        case .failure(let error):
            guard !reportedFailure.contains(job.meetingID) else { return }
            reportedFailure.insert(job.meetingID)
            if var m = store.meeting(id: job.meetingID) {
                m.error = error.localizedDescription
                store.updateMeetingState(m)
            }
            if job.meetingID == activeMeetingID { addNotice(.transcriptionFailed(error.localizedDescription)) }
        }
    }

    /// Re-checks microphone lines near a new line for call audio picked up by the microphone. Shared words
    /// alone are not enough: a line is only cut when its audio correlates with the call audio (speakers,
    /// not headphones), which is measured from the tracks off the main thread.
    private func removeEcho(around seg: MeetingSegment) {
        guard let path = store.meeting(id: seg.meetingID)?.audioPath else { return }
        let folder = URL(fileURLWithPath: path)
        let window = store.segments(meetingID: seg.meetingID, overlappingMs: seg.startMs - 60_000, seg.endMs + 60_000)
        Task { [weak self] in
            let resolved = await Task.detached(priority: .utility) { EchoMatcher.resolve(window, folder: folder) }.value
            guard let self else { return }
            for (id, r) in resolved where window.contains(where: { $0.id == id && EchoMatcher.overlaps($0, seg) }) {
                self.store.applyEchoCleanup(id: id, text: r.text, startMs: r.startMs)
            }
        }
    }

    // MARK: Speaker names

    /// The user's own name never names an "Others" line.
    private var speakerSelfNames: [String] {
        let name = settingsStore.settings.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? [] : [name]
    }

    /// Starts, replaces or stops the speaker poller so it reads the call the recording follows now, while
    /// "Detect speaker names" is on and Shout may use Accessibility. Runs when a leg begins and every tick, so a
    /// call that binds late (Join + Start), the setting and the permission are all picked up within a second.
    private func updateSpeakerPoller() {
        let wanted: SpeakerTarget? = {
            guard isRecording, settingsStore.settings.scribeDetectSpeakers, AXIsProcessTrusted(),
                  let call = detector?.boundCall else { return nil }
            return SpeakerTarget(call: call)
        }()
        guard speakerPoller?.target != wanted else { return }
        if speakerPoller != nil {
            speakerPoller?.stop()
            speakerPoller = nil
            // What it showed last holds only until now.
            if let ms = timelineMs(at: MeetingClock.now()) { speakerTimeline?.close(atMs: ms) }
        }
        if liveSpeakerName != nil { liveSpeakerName = nil }
        guard let wanted, let id = activeMeetingID else { return }
        let classes = SpeakerClassNames { UserDefaults.standard.object(forKey: $0) }
        let poller = MeetingSpeakerPoller(target: wanted, selfNames: speakerSelfNames, classes: classes)
        poller.onChange = { [weak self, weak poller] change in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let poller, self.speakerPoller === poller else { return }
                    self.speakerChanged(change, meetingID: id)
                }
            }
        }
        speakerPoller = poller
        poller.start()
    }

    private func speakerChanged(_ change: SpeakerChange, meetingID id: String) {
        guard activeMeetingID == id, let ms = timelineMs(at: change.timestamp) else { return }
        let c = change.renaming(speakerAliases)
        speakerTimeline?.record(c, atMs: ms)
        let live = c.attributionState == .matched ? c.speakerName : nil
        if live != liveSpeakerName { liveSpeakerName = live }
    }

    /// The timeline position (ms) of host time `time` during this leg.
    private func timelineMs(at time: Double) -> Int? {
        guard let clock = legClock else { return nil }
        return (clock.sample + max(0, Int(((time - clock.time) * Double(MeetingTrack.sampleRate)).rounded()))) / 16
    }

    /// Stores the spans that closed since the last tick (never one per poll).
    private func storeSpeakerSpans() {
        guard let id = activeMeetingID, let closed = speakerTimeline?.takeClosed(), !closed.isEmpty else { return }
        store.appendSpeakerSpans(meetingID: id, closed)
    }

    /// The leg stopped at `ms`: its last span ends there and the rest is stored.
    private func endSpeakerTimeline(meetingID id: String, atMs ms: Int) {
        if liveSpeakerName != nil { liveSpeakerName = nil }
        speakerAliases = [:]
        legClock = nil
        guard var timeline = speakerTimeline else { return }
        speakerTimeline = nil
        timeline.close(atMs: ms)
        store.appendSpeakerSpans(meetingID: id, timeline.takeClosed())
    }

    /// The name of a new "Others" line of the leg being recorded, from what the app has shown so far (the final
    /// pass at the end of the leg may still change it).
    private func speakerName(forNewLine line: MeetingSegment) -> String? {
        guard line.source == .system, line.meetingID == activeMeetingID, let spans = speakerTimeline?.spans, !spans.isEmpty else { return nil }
        return SpeakerAttribution.attribute(segments: [line], spans: spans, selfNames: speakerSelfNames,
                                            aliases: speakerAliases)[line.id] ?? nil
    }

    /// Names the meeting's "Others" lines again from all its readings (stored, and the current leg's not stored yet),
    /// with the meeting's renames applied to every one of them.
    private func relabelSpeakers(_ id: String) {
        var spans = store.speakerSpans(meetingID: id)
        if id == activeMeetingID, let unstored = speakerTimeline?.unstored { spans += unstored }
        guard !spans.isEmpty else { return }
        store.applySpeakerNames(meetingID: id, SpeakerAttribution.attribute(segments: store.segments(meetingID: id), spans: spans,
                                                                           selfNames: speakerSelfNames,
                                                                           aliases: store.speakerAliases(meetingID: id)))
    }

    /// Renames a speaker in the whole meeting. The rename is stored, so it also applies to what the app shows under
    /// the old name later: in this leg, after a Resume, and whenever the names are worked out again.
    func renameSpeaker(meetingID: String, from old: String, to new: String) {
        guard let name = SpeakerNames.clean(new), name != old else { return }
        store.renameSpeaker(meetingID: meetingID, from: old, to: name)
        guard meetingID == activeMeetingID else { return }
        let key = SpeakerNames.key(old)
        speakerTimeline?.rename(key: key, to: name)
        speakerAliases = store.speakerAliases(meetingID: meetingID)
        if liveSpeakerName.map(SpeakerNames.key) == key { liveSpeakerName = name }
    }

    // MARK: Watchdogs and safety nets (1 Hz)

    /// "Meeting still going?" after this long with a healthy microphone and no transcript line.
    static let silenceLimit: TimeInterval = 600
    /// Maximum-length choices (minutes). The longest is capped at 3 h − 2 min.
    static let maxLengthOptions = [30, 60, 120, 180]

    static func maxLengthCap(minutes: Int) -> TimeInterval { min(Double(max(10, minutes)) * 60, 3 * 3600 - 120) }
    /// The warning comes this long before the cap: 2 minutes for a 30-minute cap, else 5.
    static func maxLengthLead(minutes: Int) -> TimeInterval { minutes <= 30 ? 120 : 300 }
    static func lengthLabel(minutes: Int) -> String {
        minutes < 60 || minutes % 60 != 0 ? "\(minutes) minutes" : (minutes == 60 ? "1 hour" : "\(minutes / 60) hours")
    }

    /// The 1-hour check-in (Wispr Flow's `notetakerLongMeetingCheckInEnabled`, on by default).
    private var longMeetingCheckIn: Bool { settingsStore.settings.scribeLongMeetingCheckIn }

    private func tick() {
        guard isRecording, let micT = micTrack, let sysT = systemTrack else { return }
        let now = Date()
        let ms = micT.stats, ss = sysT.stats
        let mSpeak = ms.speaking && !micPausedForDictation
        if mSpeak != micSpeaking { micSpeaking = mSpeak }
        if ss.speaking != systemSpeaking { systemSpeaking = ss.speaking }
        let legSeconds = legStartDate.map { now.timeIntervalSince($0) } ?? 0
        let s = settingsStore.settings

        // Speaker names follow the call bound now (it can bind late), the setting and the permission.
        updateSpeakerPoller()
        storeSpeakerSpans()

        // System audio that stays digitally silent usually means the permission was not granted
        // (macOS gives a denied tap silence, not an error).
        if #available(macOS 14.4, *), let cap = systemCapture as? SystemAudioCapture {
            superviseSystemAudio(cap, stats: ss, legSeconds: legSeconds)
        }

        // A microphone that failed to start is retried every 3 s. One that runs but stopped delivering is
        // restarted by its own watchdog, which reports a stall (`onStall`) when that doesn't help.
        if !micPausedForDictation && !mic.isRunning && now.timeIntervalSince(lastMicRetry) >= 3 { startMic() }
        if mic.isStalled && !micPausedForDictation && !micStallCardShown { micStallCardShown = showMicStallCard() }
        // Audio that can't be written (disk full): the transcript goes on, the user is told.
        if ms.writeFailed || ss.writeFailed {
            addNotice(.systemAudioUnavailable(Self.storageFullText))
            if !storageCardShown { storageCardShown = showStorageCard() }
        } else if notices.contains(.systemAudioUnavailable(Self.storageFullText)) {
            notices.removeAll { $0 == .systemAudioUnavailable(Self.storageFullText) }
            storageCardShown = false
        }
        if !micPausedForDictation && mic.isRunning && ms.quietSeconds >= 180 { addNotice(.micSilent) }
        else if ms.quietSeconds < 1 { notices.removeAll { $0 == .micSilent } }

        // Silence check: time with the microphone running and delivering, and no transcript line. Anything
        // else (dictation, the mic down or stalled, a line) starts it over.
        let dt = min(2, now.timeIntervalSince(lastTickAt ?? now))
        lastTickAt = now
        let buffers = mic.bufferStats.buffers
        let micHealthy = mic.isRunning && !micPausedForDictation && buffers != lastMicBuffers
        lastMicBuffers = buffers
        silentSeconds = micHealthy && !lineSinceTick ? silentSeconds + dt : 0
        lineSinceTick = false
        let silenceUp = isShowing(silenceCardID)
        if s.scribeAutoStop && !silenceUp && silentSeconds >= Self.silenceLimit && legLines > 0 { showSilenceCard() }

        // Maximum length, with a warning that can raise the limit.
        let cap = Self.maxLengthCap(minutes: s.scribeMaxMinutes)
        if elapsed >= cap { stop(reason: .maxLength); return }
        if elapsed >= cap - Self.maxLengthLead(minutes: s.scribeMaxMinutes), maxWarnedCap != cap, !silenceUp,
           showMaxLengthWarning(minutes: s.scribeMaxMinutes, capAt: now.addingTimeInterval(cap - elapsed)) {
            maxWarnedCap = cap
        }

        // "Still taking notes": once per leg, never while people are talking.
        let talking = lastLineAt.map { now.timeIntervalSince($0) < 180 } ?? false
        if s.scribeAutoStop, !checkInShown, !silenceUp, !talking, checkInDue(now: now, legSeconds: legSeconds, cap: cap) {
            checkInShown = showCheckIn()
        }
    }

    /// "Meeting still going?" [Stop] [Keep going]; stops when not answered.
    private func showSilenceCard() {
        var card = FlowCard(kind: .info, title: "Meeting still going?", subtitle: "No one has spoken for 10 minutes",
                            symbol: "waveform.slash", primary: "Stop", secondary: "Keep going",
                            deadline: Date().addingTimeInterval(30))
        let cardID = card.id
        card.onPrimary = { [weak self] in self?.dismissCard(id: cardID); self?.stop(reason: .noSpeech) }
        card.onSecondary = { [weak self] in self?.dismissCard(id: cardID); self?.silentSeconds = 0 }
        card.onDismiss = card.onSecondary
        card.onTimeout = { [weak self] in
            guard let self, self.isRecording, self.silentSeconds >= Self.silenceLimit else { return }
            self.stop(reason: .noSpeech)
        }
        if present(card) { silenceCardID = card.id }
    }

    /// "Shout isn't hearing your microphone": its watchdog's restarts didn't bring audio back.
    private func showMicStallCard() -> Bool {
        var card = FlowCard(kind: .info, title: "Shout isn't hearing your microphone",
                            subtitle: "It stopped sending audio. Check the input in System Settings › Sound.",
                            symbol: "mic.slash", primary: "OK", deadline: Date().addingTimeInterval(15))
        let cardID = card.id
        card.onPrimary = { [weak self] in self?.dismissCard(id: cardID) }
        card.onDismiss = card.onPrimary
        guard present(card) else { return false }
        micStallCardID = card.id
        return true
    }

    /// The meeting audio can't be written (disk full); shown once per episode.
    private func showStorageCard() -> Bool {
        var card = FlowCard(kind: .info, title: "Meeting audio isn't being saved",
                            subtitle: "The disk may be full. The transcript continues.",
                            symbol: "externaldrive.badge.exclamationmark", primary: "OK", deadline: Date().addingTimeInterval(15))
        let cardID = card.id
        card.onPrimary = { [weak self] in self?.dismissCard(id: cardID) }
        card.onDismiss = card.onPrimary
        return present(card)
    }

    /// Due at the calendar event's end + 10 min (when that is after this leg began), otherwise after an
    /// hour of this leg when the maximum length is longer than that.
    private func checkInDue(now: Date, legSeconds: TimeInterval, cap: TimeInterval) -> Bool {
        if let key = leg?.eventKey, let event = calendar?.events.first(where: { MeetingDetection.eventKey($0) == key }),
           event.end.timeIntervalSince(event.start) < 24 * 3600, let legStart = legStartDate {
            let target = event.end.addingTimeInterval(600)
            if target > legStart { return now >= target }
        }
        return longMeetingCheckIn && legSeconds >= 3600 && cap > 3600
    }

    /// "Still taking notes" [Keep going] [Stop]; keeps going when not answered.
    private func showCheckIn() -> Bool {
        let title = activeMeetingID.flatMap { store.meeting(id: $0)?.displayTitle }
        var card = FlowCard(kind: .info, title: "Still taking notes", subtitle: title, symbol: "questionmark.circle",
                            primary: "Keep going", secondary: "Stop", deadline: Date().addingTimeInterval(30))
        let cardID = card.id
        card.onPrimary = { [weak self] in self?.dismissCard(id: cardID) }
        card.onSecondary = { [weak self] in self?.dismissCard(id: cardID); self?.stop() }
        card.onDismiss = card.onPrimary
        card.onSuperseded = { [weak self] in self?.checkInShown = false }
        return present(card)
    }

    /// "Continue transcribing?" before the maximum length, counting down to it. [Yes] offers longer limits;
    /// × keeps the current one; no answer asks again.
    private func showMaxLengthWarning(minutes: Int, capAt: Date) -> Bool {
        let limit = Self.lengthLabel(minutes: minutes)
        let longer = Self.maxLengthOptions.filter { $0 > minutes }
        var card: FlowCard
        if longer.isEmpty {
            card = FlowCard(kind: .info, title: "Transcription will end soon", subtitle: "\(limit) is the limit for transcriptions.",
                            symbol: "timer", primary: "End recording", deadline: Date().addingTimeInterval(60))
        } else {
            card = FlowCard(kind: .info, title: "Continue transcribing?",
                            subtitle: "We'll auto-end transcriptions at \(limit). Would you like to extend this meeting?",
                            symbol: "timer", primary: "Yes", secondary: "End recording", deadline: Date().addingTimeInterval(60))
            card.subtitleLines = 3
        }
        let cardID = card.id
        let end: () -> Void = { [weak self] in self?.dismissCard(id: cardID); self?.stop(reason: .maxLength) }
        if longer.isEmpty {
            card.onPrimary = end
        } else {
            card.onPrimary = { [weak self] in self?.dismissCard(id: cardID); self?.showMaxLengthPicker(longer) }
            card.onSecondary = end
        }
        card.tileDeadline = capAt
        card.onDismiss = { [weak self] in self?.dismissCard(id: cardID) }
        card.onTimeout = { [weak self] in self?.maxWarnedCap = nil }
        card.onSuperseded = { [weak self] in self?.maxWarnedCap = nil }
        return present(card)
    }

    /// "Change auto-end time?": the longer limits; Save changes the setting.
    private func showMaxLengthPicker(_ options: [Int]) {
        let labels = options.map(Self.lengthLabel(minutes:))
        var card = FlowCard(kind: .info, title: "Change auto-end time?", subtitle: "We'll still check with you before ending it",
                            symbol: "timer", primary: "Save", deadline: Date().addingTimeInterval(60))
        card.choices = labels
        card.selectedChoice = labels.first
        let cardID = card.id
        card.onChoice = { [weak self] label in
            guard let self, var shown = self.flowBar.model.card, shown.id == cardID else { return }
            shown.selectedChoice = label
            self.present(shown)
        }
        card.onPrimary = { [weak self] in
            guard let self, let shown = self.flowBar.model.card, shown.id == cardID else { return }
            let chosen = shown.selectedChoice.flatMap { labels.firstIndex(of: $0) }.map { options[$0] }
            self.dismissCard(id: cardID)
            if let chosen { self.settingsStore.settings.scribeMaxMinutes = chosen }
        }
        card.onDismiss = { [weak self] in self?.dismissCard(id: cardID) }
        card.onTimeout = { [weak self] in self?.maxWarnedCap = nil }
        card.onSuperseded = { [weak self] in self?.maxWarnedCap = nil }
        present(card)
    }

    // MARK: Snapshots

    /// Puts the UI into the live state without capturing anything (snapshot mode only).
    func previewLive(meetingID: String, notices: [Notice], speaker: String? = nil) {
        guard SnapshotMode.active else { return }
        activeMeetingID = meetingID
        legStartDate = Date().addingTimeInterval(-754)
        systemSpeaking = true
        liveSpeakerName = speaker
        self.notices = notices
    }

    func endPreview() {
        activeMeetingID = nil; legStartDate = nil; systemSpeaking = false; notices = []; liveSpeakerName = nil
    }

    // MARK: Crash recovery

    /// Finishes meetings that were interrupted (quit or crash): transcribes the audio after the last
    /// transcribed line of each track and marks them complete.
    func recoverInterrupted() {
        // A crash may have left a meeting app's Accessibility tree woken by the speaker poller.
        if !SnapshotMode.active { AXWakeRegistry.shared.recoverAfterCrash() }
        let unfinished = store.unfinishedMeetings()
        // Audio left half-compressed or half-restored is cleaned up, and stopped meetings that still have raw
        // tracks are compressed. The unfinished ones are compressed once their transcription is done.
        // (Not with the throwaway demo database: the folders belong to the real one.)
        if ProcessInfo.processInfo.environment["SHOUT_DEMO_DATA"] == nil {
            MeetingArchiver.shared.recoverAll(skipping: Set(unfinished.map(\.id) + [activeMeetingID].compactMap { $0 }))
        }
        for m in unfinished where m.id != activeMeetingID && !processingIDs.contains(m.id) { recover(m) }
        // Summaries a quit or crash interrupted are written again; a meeting whose tail is still being
        // transcribed (just recovered) gets its summary when that is done, from the whole transcript.
        for id in store.resetInterruptedSummaries() where !processingIDs.contains(id) {
            if let m = store.meeting(id: id), settingsStore.settings.scribeAutoSummarize, m.duration > 300 {
                summarize(id, rerun: false)
            }
        }
        // Untitled meetings from before get a title, with the same rule for loading a model as at a stop.
        let name = settingsStore.settings.userName
        Task { [weak self] in
            guard let self else { return }
            await self.store.generateMissingTitles(userName: name.isEmpty ? nil : name) { [weak self] in
                try await self?.titleGenerator()
            }
        }
    }

    /// Closes a leg a quit or crash left open: the `stopped` marker, stop count and end time are written
    /// at once (a Resume right after continues a closed meeting), then the audio after each track's last
    /// line, up to the files' length now, is transcribed in the background.
    private func recover(_ m: Meeting) {
        guard recovered.insert(m.id).inserted else { return }
        guard let path = m.audioPath else {
            var done = m; done.status = .complete; store.updateMeetingState(done); return
        }
        let folder = URL(fileURLWithPath: path)
        let micURL = folder.appendingPathComponent("mic.pcm"), sysURL = folder.appendingPathComponent("system.pcm")
        let micEnd = MeetingTrack.sampleCount(micURL), sysEnd = MeetingTrack.sampleCount(sysURL)
        let micFrom = store.lastSegmentEndMs(meetingID: m.id, source: .mic) * 16
        let sysFrom = store.lastSegmentEndMs(meetingID: m.id, source: .system) * 16
        // Raw tracks or, once compressed, the archive (nothing is left to transcribe then).
        let length = max(micEnd, sysEnd, MeetingArchive.length(in: folder))
        var mm = m
        mm.recordedMs = max(mm.recordedMs, length / 16)
        if m.status == .recording {
            let modified = [micURL, sysURL].compactMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
            }.max()
            mm.endedAt = modified ?? Date()
            mm.latestStopSeq += 1
            store.addSegment(MeetingSegment(meetingID: m.id, source: .marker, startMs: length / 16, endMs: length / 16,
                                            marker: .stopped, epoch: mm.endedAt))
        }
        mm.status = .processing
        store.updateMeetingState(mm)
        let id = m.id
        // The scan runs inside the transcriber, so finishing the note (now, or at the stop of a Resume made
        // meanwhile) waits for the lines it finds before marking it complete and summarizing it.
        transcriber.submit(meetingID: id) {
            let a = ((try? MeetingTrack.segments(in: micURL, from: micFrom, to: micEnd)) ?? []).map { (MeetingSource.mic, $0) }
            let b = ((try? MeetingTrack.segments(in: sysURL, from: sysFrom, to: sysEnd)) ?? []).map { (MeetingSource.system, $0) }
            return (a + b).sorted { $0.1.start < $1.1.start }.map { MeetingTranscriber.Job(meetingID: id, source: $0.0, segment: $0.1) }
        }
        // Resumed meanwhile: this finds the note recording and leaves it to that leg's stop.
        finishTranscription(id)
    }
}

/// Native meeting apps whose name makes a good default label for a recording.
enum MeetingApps {
    static func name(for bundleID: String?) -> String? {
        guard let id = bundleID?.lowercased() else { return nil }
        let known: [String: String] = [
            "us.zoom.xos": "Zoom", "com.microsoft.teams": "Microsoft Teams", "com.microsoft.teams2": "Microsoft Teams",
            "com.cisco.webexmeetingsapp": "Webex", "cisco-systems.spark": "Webex", "com.apple.facetime": "FaceTime",
            "com.tinyspeck.slackmacgap": "Slack", "com.hnc.discord": "Discord", "net.whatsapp.whatsapp": "WhatsApp",
        ]
        return known[id]
    }
}

/// Posts "Your summary is ready!" as a system notification; clicking it (or "View summary") opens the
/// meeting. macOS asks once whether Shout may send notifications.
@MainActor
private final class SummaryNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "summary-ready"
    /// Notifications need an app bundle (`swift run` and tests have none).
    private let available = Bundle.main.bundleURL.pathExtension == "app"

    /// Becomes the notification delegate at once (created at launch): a click on a notification posted in an
    /// earlier session, or before this session's first post, is only delivered to a delegate set before
    /// launch finishes. Nothing is posted or asked for here.
    override init() {
        super.init()
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = MeetingSummarizer.readyNotification(meetingTitle: "").action
        let view = UNNotificationAction(identifier: "view", title: action, options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [view], intentIdentifiers: [])])
    }

    func post(meetingID: String, title: String, body: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.category
        content.userInfo = ["meetingID": meetingID]
        let request = UNNotificationRequest(identifier: "summary-\(meetingID)", content: content, trigger: nil)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { center.add(request) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["meetingID"] as? String
        let open = response.actionIdentifier != UNNotificationDismissActionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let id, open {
                    AppRouter.shared.page = .scribe
                    AppRouter.shared.meetingID = id
                    (NSApp.delegate as? AppDelegate)?.openMainWindow(page: "scribe")
                    NSApp.activate(ignoringOtherApps: true)
                }
                completionHandler()
            }
        }
    }
}

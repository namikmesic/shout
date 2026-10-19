import Foundation
import Combine

public enum CleanupLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, light, medium, high
    public var id: String { rawValue }
    public var title: String {
        switch self { case .off: "Off"; case .light: "Light"; case .medium: "Medium"; case .high: "High" }
    }
    public var summary: String {
        switch self {
        case .off: "Raw transcript. No language model is used."
        case .light: "Removes filler words and fixes grammar while keeping your wording."
        case .medium: "Also tightens sentences for clarity."
        case .high: "Rewrites for brevity and polish."
        }
    }
}

public enum Tone: String, Codable, CaseIterable, Sendable, Identifiable {
    case formal, casual, veryCasual, excited
    public var id: String { rawValue }
    public var title: String {
        switch self { case .formal: "Formal"; case .casual: "Casual"; case .veryCasual: "Very casual"; case .excited: "Excited" }
    }
    public var example: String {
        switch self {
        case .formal: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .casual: "Hey are you free for lunch tomorrow? Let's do 12 if that works for you"
        case .veryCasual: "hey are you free for lunch tomorrow? let's do 12 if that works for you"
        case .excited: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you!"
        }
    }
}

/// The style categories users configure a tone for.
public enum StyleCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case personal, work, email, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .personal: "Personal messages"; case .work: "Work messages"; case .email: "Email"; case .other: "Other"
        }
    }
    public var appsDescription: String {
        switch self {
        case .personal: "Messages, WhatsApp, Telegram, Signal, Discord"
        case .work: "Slack, Teams, Google Chat"
        case .email: "Mail, Outlook, Gmail, Superhuman"
        case .other: "Documents, notes, browsers and everything else"
        }
    }
}

/// Per-app formatting override.
public enum FormatMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic, noAI, casual, lowercase
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "Apply AI formatting"; case .noAI: "No AI formatting"
        case .casual: "Casual messaging"; case .lowercase: "All lowercase"
        }
    }
}

/// Shout's windows: as macOS is set, or always light or dark.
public enum Appearance: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String {
        switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
    }
}

public enum MediaBehavior: String, Codable, CaseIterable, Sendable, Identifiable {
    case nothing, mute, pause
    public var id: String { rawValue }
    public var title: String {
        switch self { case .nothing: "Do nothing"; case .mute: "Mute system audio"; case .pause: "Pause media" }
    }
}

public enum RetentionPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case forever, day, never
    public var id: String { rawValue }
    public var title: String {
        switch self { case .forever: "Keep history"; case .day: "Delete after 24 hours"; case .never: "Never store" }
    }
}

/// What Shout has observed about system-audio capture. There is no public API to query the
/// "System Audio Recording" permission, so it is inferred from whether captured audio is ever non-silent.
public enum SystemAudioStatus: String, Codable, Sendable {
    case unknown, working, silent
}

/// When to remind before a scheduled meeting.
public enum MeetingReminderLead: String, Codable, CaseIterable, Sendable, Identifiable {
    case rightBefore, oneMinute, twoMinutes, never
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .rightBefore: "Right before the meeting"
        case .oneMinute: "1 minute before"
        case .twoMinutes: "2 minutes before"
        case .never: "Never"
        }
    }
    public var seconds: TimeInterval? {
        switch self { case .rightBefore: 15; case .oneMinute: 60; case .twoMinutes: 120; case .never: nil }
    }
}

public struct AppOverride: Codable, Hashable, Sendable, Identifiable {
    public var bundleID: String
    public var appName: String
    public var mode: FormatMode
    public var id: String { bundleID }
    public init(bundleID: String, appName: String, mode: FormatMode) {
        self.bundleID = bundleID; self.appName = appName; self.mode = mode
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    // Shortcuts
    public var pushToTalk = KeyCombo.defaultPushToTalk
    public var handsFree = KeyCombo.defaultHandsFree
    public var command = KeyCombo.defaultCommand
    public var pasteLast = KeyCombo.defaultPasteLast
    public var copyLast = KeyCombo.defaultCopyLast
    public var doubleTapLocksHandsFree = true

    // Models
    public var speechModelID = ModelCatalog.defaultSpeechModelID
    public var languageModelID = ModelCatalog.defaultLanguageModelID
    public var ollamaURL = "http://localhost:11434"
    public var ollamaModel = ""

    // Language: empty = automatic detection; one entry = forced; several = auto among them.
    public var languages: [String] = [Locale.current.language.languageCode?.identifier ?? "en"]

    // Formatting
    public var cleanupLevel: CleanupLevel = .light
    public var tones: [StyleCategory: Tone] = [.personal: .casual, .work: .formal, .email: .formal, .other: .formal]
    public var appOverrides: [AppOverride] = []
    public var useContext = true
    public var autoLearnWords = true
    public var pressEnterCommand = false
    public var commandModeEnabled = true
    public var emailSignatureEnabled = false
    public var emailSignature = ""
    public var userName = ""

    // Prompt mode: a held shortcut that turns what you say (or the selected text) into a structured prompt.
    public var promptModeEnabled = true
    public var promptShortcut = KeyCombo.defaultPrompt
    /// Screenshots taken while describing a prompt go into it, tied to the words said then.
    public var promptScreenshots = true
    /// The AI editing model looks at those screenshots to word the prompt, when it can (`promptModelSeesScreenshots`).
    public var promptShowScreenshotsToModel = true

    // Audio
    public var microphoneUID: String? = nil
    public var mediaBehavior: MediaBehavior = .nothing
    public var soundsEnabled = true
    public var soundVolume: Float = 0.5

    // System
    public var appearance: Appearance = .system
    public var launchAtLogin = true
    public var showInDock = true
    public var showFlowBarWhenIdle = true
    public var restoreClipboard = true
    public var keepModelsLoaded = true

    // Privacy
    public var retention: RetentionPolicy = .forever
    public var saveAudio = false

    // Scribe
    public var scribeOpenNotepad = true
    public var scribeMaxMinutes = 120
    public var scribeEchoCancellation = true
    public var scribeSystemAudio: SystemAudioStatus = .unknown
    public var scribeConsentDismissed = false
    public var scribeReminderLead: MeetingReminderLead = .rightBefore
    public var scribeShowNextMeeting = true
    public var scribeDetectCalls = true
    public var scribeAutoStart = false
    public var scribeAutoStop = true
    /// "Still taking notes" an hour into a recording (or 10 minutes after its calendar event ends).
    public var scribeLongMeetingCheckIn = true
    public var scribeHideFromScreenCapture = false
    public var scribeSplitScreen = false
    /// Starts or stops the Scribe from anywhere; empty means no shortcut. ⌥M unless the user cleared it
    /// (`scribeShortcutRemoved`) or another Shout shortcut clashes with it (`resolveScribeDefault`).
    public var scribeShortcut = KeyCombo.defaultScribe
    public var scribeShortcutRemoved = false
    public var scribeShowLiveTranscript = true
    /// Names "Others" lines from who the meeting app shows talking (Zoom, Meet, Teams, Slack), read through
    /// Accessibility; nothing leaves the Mac.
    public var scribeDetectSpeakers = true
    public var scribeAutoSummarize = true
    public var scribeConsentMessage = AppSettings.defaultConsentMessage
    public var scribeSetupDismissed = false

    public static let defaultConsentMessage =
        "Hi everyone, a quick note that I'm transcribing this call on my Mac for my own notes. Nothing is uploaded anywhere."

    public var hasCompletedOnboarding = false

    public init() {}

    public var speechModel: ModelInfo {
        ModelCatalog.model(id: speechModelID) ?? ModelCatalog.model(id: ModelCatalog.defaultSpeechModelID)!
    }
    public var languageModel: ModelInfo {
        ModelCatalog.model(id: languageModelID) ?? ModelCatalog.model(id: ModelCatalog.defaultLanguageModelID)!
    }

    /// The single forced language, or nil for automatic detection.
    public var forcedLanguage: String? { languages.count == 1 ? languages[0] : nil }

    public func tone(for category: StyleCategory) -> Tone { tones[category] ?? .formal }

    /// Whether the chosen AI editing model can do Prompt mode's screenshots (otherwise the switch is grayed out).
    public var promptScreenshotsAvailable: Bool { languageModel.handlesPromptScreenshots }
    /// Screenshots are taken in Prompt mode: switched on, and a model that handles them.
    public var promptScreenshotsOn: Bool { promptScreenshots && promptScreenshotsAvailable }
    /// The model looks at the screenshots: they're on, it's switched on, and the model can see pictures (its image
    /// reader still has to be on this Mac: `TextGenerator.readsImages`).
    public var promptModelSeesScreenshots: Bool {
        promptScreenshotsOn && promptShowScreenshotsToModel && languageModel.imageReader != nil
    }
    public func override(for bundleID: String?) -> FormatMode {
        guard let bundleID else { return .automatic }
        return appOverrides.first { $0.bundleID == bundleID }?.mode ?? .automatic
    }

    // Tolerant decoding so new fields never wipe existing settings.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? cur }
        pushToTalk = d(.pushToTalk, pushToTalk); handsFree = d(.handsFree, handsFree); command = d(.command, command)
        pasteLast = d(.pasteLast, pasteLast); copyLast = d(.copyLast, copyLast)
        doubleTapLocksHandsFree = d(.doubleTapLocksHandsFree, doubleTapLocksHandsFree)
        speechModelID = d(.speechModelID, speechModelID); languageModelID = d(.languageModelID, languageModelID)
        ollamaURL = d(.ollamaURL, ollamaURL); ollamaModel = d(.ollamaModel, ollamaModel)
        languages = d(.languages, languages); cleanupLevel = d(.cleanupLevel, cleanupLevel)
        tones = d(.tones, tones); appOverrides = d(.appOverrides, appOverrides)
        useContext = d(.useContext, useContext); autoLearnWords = d(.autoLearnWords, autoLearnWords)
        pressEnterCommand = d(.pressEnterCommand, pressEnterCommand)
        commandModeEnabled = d(.commandModeEnabled, commandModeEnabled)
        emailSignatureEnabled = d(.emailSignatureEnabled, emailSignatureEnabled)
        emailSignature = d(.emailSignature, emailSignature); userName = d(.userName, userName)
        promptModeEnabled = d(.promptModeEnabled, promptModeEnabled); promptShortcut = d(.promptShortcut, promptShortcut)
        promptScreenshots = d(.promptScreenshots, promptScreenshots)
        promptShowScreenshotsToModel = d(.promptShowScreenshotsToModel, promptShowScreenshotsToModel)
        microphoneUID = d(.microphoneUID, microphoneUID); mediaBehavior = d(.mediaBehavior, mediaBehavior)
        soundsEnabled = d(.soundsEnabled, soundsEnabled); soundVolume = d(.soundVolume, soundVolume)
        launchAtLogin = d(.launchAtLogin, launchAtLogin); showInDock = d(.showInDock, showInDock)
        appearance = d(.appearance, appearance)
        showFlowBarWhenIdle = d(.showFlowBarWhenIdle, showFlowBarWhenIdle)
        restoreClipboard = d(.restoreClipboard, restoreClipboard); keepModelsLoaded = d(.keepModelsLoaded, keepModelsLoaded)
        retention = d(.retention, retention); saveAudio = d(.saveAudio, saveAudio)
        scribeOpenNotepad = d(.scribeOpenNotepad, scribeOpenNotepad)
        scribeMaxMinutes = d(.scribeMaxMinutes, scribeMaxMinutes)
        scribeEchoCancellation = d(.scribeEchoCancellation, scribeEchoCancellation)
        scribeSystemAudio = d(.scribeSystemAudio, scribeSystemAudio)
        scribeConsentDismissed = d(.scribeConsentDismissed, scribeConsentDismissed)
        scribeReminderLead = d(.scribeReminderLead, scribeReminderLead)
        scribeShowNextMeeting = d(.scribeShowNextMeeting, scribeShowNextMeeting)
        scribeDetectCalls = d(.scribeDetectCalls, scribeDetectCalls)
        scribeAutoStart = d(.scribeAutoStart, scribeAutoStart)
        scribeAutoStop = d(.scribeAutoStop, scribeAutoStop)
        scribeLongMeetingCheckIn = d(.scribeLongMeetingCheckIn, scribeLongMeetingCheckIn)
        scribeHideFromScreenCapture = d(.scribeHideFromScreenCapture, scribeHideFromScreenCapture)
        scribeSplitScreen = d(.scribeSplitScreen, scribeSplitScreen)
        scribeShortcut = d(.scribeShortcut, scribeShortcut)
        scribeShortcutRemoved = d(.scribeShortcutRemoved, scribeShortcutRemoved)
        scribeShowLiveTranscript = d(.scribeShowLiveTranscript, scribeShowLiveTranscript)
        scribeDetectSpeakers = d(.scribeDetectSpeakers, scribeDetectSpeakers)
        scribeAutoSummarize = d(.scribeAutoSummarize, scribeAutoSummarize)
        scribeConsentMessage = d(.scribeConsentMessage, scribeConsentMessage)
        scribeSetupDismissed = d(.scribeSetupDismissed, scribeSetupDismissed)
        hasCompletedOnboarding = d(.hasCompletedOnboarding, hasCompletedOnboarding)
        // As on every change: ⌥M gives way to a shortcut that clashes with it (push to talk on Left ⌥).
        resolveScribeDefault()
    }
}

/// Shout's global shortcuts, so a new one can be checked against the others.
public enum ShortcutSlot: String, CaseIterable, Sendable {
    case pushToTalk, handsFree, command, prompt, pasteLast, copyLast, scribe

    public var title: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .handsFree: "Hands-free"
        case .command: "Command Mode"
        case .prompt: "Prompt mode"
        case .pasteLast: "Paste last transcript"
        case .copyLast: "Copy last transcript"
        case .scribe: "Scribe"
        }
    }

    /// Two shortcuts clash when one's keys contain the other's: the hotkey layer matches exact key sets, so pressing
    /// the longer one fires the shorter on the way (push to talk on Left ⌥ starts dictating on the way to ⌥M).
    /// Hands-free, Command Mode and Prompt mode may build on push to talk (fn, fn+Space, fn+⌃, fn+⇧): the hotkey
    /// layer hands a held push to talk over to them.
    static func clash(_ a: KeyCombo, as aSlot: ShortcutSlot, with b: KeyCombo, as bSlot: ShortcutSlot) -> Bool {
        guard aSlot != bSlot, a.overlaps(b) else { return false }
        func extendsPushToTalk(_ ptt: KeyCombo, _ pttSlot: ShortcutSlot, _ other: KeyCombo, _ otherSlot: ShortcutSlot) -> Bool {
            pttSlot == .pushToTalk && [.handsFree, .command, .prompt].contains(otherSlot) && ptt.keys.isStrictSubset(of: other.keys)
        }
        return !extendsPushToTalk(a, aSlot, b, bSlot) && !extendsPushToTalk(b, bSlot, a, aSlot)
    }
}

extension AppSettings {
    public subscript(shortcut slot: ShortcutSlot) -> KeyCombo {
        get {
            switch slot {
            case .pushToTalk: pushToTalk
            case .handsFree: handsFree
            case .command: command
            case .prompt: promptShortcut
            case .pasteLast: pasteLast
            case .copyLast: copyLast
            case .scribe: scribeShortcut
            }
        }
        set {
            switch slot {
            case .pushToTalk: pushToTalk = newValue
            case .handsFree: handsFree = newValue
            case .command: command = newValue
            case .prompt: promptShortcut = newValue
            case .pasteLast: pasteLast = newValue
            case .copyLast: copyLast = newValue
            case .scribe: scribeShortcut = newValue
            }
        }
    }

    /// The shortcut that `combo` would clash with if it were recorded for `slot`, or nil when it is free. The ⌥M
    /// default doesn't block anything: it gives way instead (`resolveScribeDefault`).
    public func shortcutConflict(_ combo: KeyCombo, for slot: ShortcutSlot) -> ShortcutSlot? {
        ShortcutSlot.allCases.first { other in
            let theirs = self[shortcut: other]
            if other == .scribe && theirs == KeyCombo.defaultScribe { return false }
            return ShortcutSlot.clash(combo, as: slot, with: theirs, as: other)
        }
    }

    /// No other shortcut clashes with ⌥M (push to talk on Left ⌥ does).
    public var defaultScribeShortcutIsFree: Bool {
        !ShortcutSlot.allCases.contains { ShortcutSlot.clash(KeyCombo.defaultScribe, as: .scribe, with: self[shortcut: $0], as: $0) }
    }

    /// ⌥M is the Scribe shortcut only while it is free: it is dropped when another shortcut comes to clash with
    /// it, and comes back once that changes, unless the user cleared it. `SettingsStore` applies this on every change.
    public mutating func resolveScribeDefault() {
        if scribeShortcut == KeyCombo.defaultScribe && !defaultScribeShortcutIsFree {
            scribeShortcut = KeyCombo([])
        } else if scribeShortcut.isEmpty && !scribeShortcutRemoved && defaultScribeShortcutIsFree {
            scribeShortcut = KeyCombo.defaultScribe
        }
    }
}

/// Persists settings as JSON in UserDefaults and publishes changes.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()
    private let key = "ShoutSettings.v1"
    private let defaults: UserDefaults

    @Published public var settings: AppSettings {
        didSet {
            // @Published re-runs this observer for the assignment below; the outer pass saves once.
            guard !isResolving else { return }
            // A new shortcut that clashes with ⌥M takes its place at once, so both never fire together.
            var resolved = settings
            resolved.resolveScribeDefault()
            if resolved != settings {
                isResolving = true
                settings = resolved
                isResolving = false
            }
            if settings != oldValue { save() }
        }
    }
    private var isResolving = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}

import Foundation

// Speaker names from the meeting app's own window (as Wispr Flow's helper reads them): which calls can be
// read, the text rules of each app, and the name filter. Pure string logic; the Accessibility reads live in
// the app (`MeetingSpeakerPoller`).

/// The meeting apps whose window shows who is talking in a form Shout can read.
public enum SpeakerPlatform: String, Sendable, Codable, CaseIterable {
    case zoom, meet, teams, slack

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .slack: "Slack"
        }
    }
}

/// The recorded call's app, as the speaker poller reads it.
public struct SpeakerTarget: Equatable, Hashable, Sendable {
    public var pid: pid_t
    public var bundleID: String
    public var platform: SpeakerPlatform
    /// Chromium and Electron build their Accessibility tree only once asked (`AXManualAccessibility`).
    public var wakesTree: Bool
    /// The Meet code of the call: only its window is read when several Meet windows are open
    /// (`SpeakerWindows.meetWindows`).
    public var meetingCode: String?

    public init(pid: pid_t, bundleID: String, platform: SpeakerPlatform, wakesTree: Bool, meetingCode: String? = nil) {
        self.pid = pid; self.bundleID = bundleID; self.platform = platform; self.wakesTree = wakesTree
        self.meetingCode = meetingCode
    }

    /// Bundle IDs (lowercased); an ID matches exactly or as a prefix followed by ".".
    static let zoomApps = ["us.zoom.xos"]
    static let teamsApps = ["com.microsoft.teams", "com.microsoft.teams2"]
    static let slackApps = ["com.tinyspeck.slackmacgap", "com.slack.slack"]
    /// Chrome (and its beta, dev and canary builds), Edge, Brave and Chromium.
    static let chromium = ["com.google.chrome", "com.microsoft.edgemac", "com.brave.browser", "org.chromium.chromium"]
    static let arc = ["company.thebrowser.browser"]
    static let safari = ["com.apple.safari", "com.apple.safaritechnologypreview"]

    /// The call runs in a browser tab rather than the platform's own app.
    public var inBrowser: Bool { Self.matches(bundleID, Self.chromium + Self.arc + Self.safari) }

    static func matches(_ bundleID: String, _ list: [String]) -> Bool {
        let id = bundleID.lowercased()
        return list.contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    /// The reader for a call, or nil when its app shows no readable speaker (Webex, FaceTime, Firefox, Slack or
    /// Zoom in a browser, …). Zoom and Slack only in their own apps; Meet in Chromium browsers, Arc and Safari;
    /// Teams in its app and in Chromium browsers.
    public init?(call: DetectedCall) {
        let id = call.bundleID
        let platform: SpeakerPlatform
        let wakes: Bool
        switch call.platform {
        case .zoom where Self.matches(id, Self.zoomApps):
            (platform, wakes) = (.zoom, false)
        case .meet where Self.matches(id, Self.chromium + Self.arc):
            (platform, wakes) = (.meet, true)
        case .meet where Self.matches(id, Self.safari):
            // WebKit builds its tree on demand; no wake-up attribute.
            (platform, wakes) = (.meet, false)
        case .teams where Self.matches(id, Self.teamsApps + Self.chromium):
            (platform, wakes) = (.teams, true)
        case .slack where Self.matches(id, Self.slackApps):
            (platform, wakes) = (.slack, true)
        default:
            return nil
        }
        self.init(pid: call.pid, bundleID: id, platform: platform, wakesTree: wakes, meetingCode: call.meetingCode)
    }
}

/// Which part of the app a reading came from (Wispr Flow's values).
public enum SpeakerSource: String, Sendable, Codable {
    case zoomMain = "zoom_main", zoomCompact = "zoom_compact", zoomCompactTile = "zoom_compact_tile"
    case meetTab = "meet_tab", meetSide = "meet_side"
    case teamsMain = "teams_main", teamsCompact = "teams_compact", teamsCombined = "teams_combined"
    case slackWindow = "slack_window"
    case unknown
}

/// Why a reading names nobody although the app may show a speaker (Wispr Flow's values).
public enum SpeakerReadReason: String, Sendable, Codable {
    case sourceMissing = "source_missing", readFailed = "read_failed", partialTree = "partial_tree"
    case indicatorUnavailable = "indicator_unavailable", labelUnrecognized = "label_unrecognized"
    case conflictingLabels = "conflicting_labels", sourceHidden = "source_hidden", sourceOccluded = "source_occluded"
    case partialCoverage = "partial_coverage"
}

// MARK: - Names

public enum SpeakerNames {
    /// Words that mark a status label, not a name.
    static let statusWords = ["muted", "unmuted", "talking", "video", "presenting", "camera", "microphone"]
    /// Names are cut to this length before they are stored.
    public static let maxLength = 200

    /// NFC, tabs and line breaks turned into spaces, runs of spaces collapsed, trimmed and cut to `maxLength`;
    /// nil when nothing is left.
    public static func clean(_ raw: String) -> String? {
        let words = raw.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let t = String(words.joined(separator: " ").prefix(maxLength))
        return t.isEmpty ? nil : t
    }

    /// The comparison key: cleaned, a trailing "(…)" removed, lowercased. "Ada Lovelace (Guest)" and
    /// "ada  lovelace" have the same key.
    public static func key(_ name: String) -> String {
        let t = clean(name) ?? ""
        let base = t.replacing(#/\s*\([^()]*\)\s*$/#, with: "")
        return (base.isEmpty ? t : base).lowercased()
    }

    /// Whether a label read from a tile can be a person's name. Rejects timers ("12:04"), overflow tiles
    /// ("+3 more"), avatar initials ("AL"), status labels ("Muted") and anything under two characters.
    public static func isPlausible(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.contains(where: \.isLetter) else { return false }
        if t.contains(where: \.isNumber) {
            if t.firstMatch(of: #/\d:\d\d/#) != nil { return false }
            if t.wholeMatch(of: #/(?i)\+?\d+\s+(more|others?|participants?)/#) != nil { return false }
        }
        if t.count <= 3, t == t.uppercased(), t != t.lowercased() { return false }
        let lower = t.lowercased()
        return !statusWords.contains { lower.contains($0) }
    }

    /// The user's own tile: "You", "Me", or a name marked "(You)" / "(Me)". Returns the name to show for the
    /// user ("Ada Lovelace" for "Ada Lovelace (You)", "You" for "You"); nil for anyone else.
    public static func selfName(fromLabel label: String) -> String? {
        guard let t = clean(label) else { return nil }
        if ["you", "me"].contains(t.lowercased()) { return t }
        guard let m = t.firstMatch(of: #/^(.*\S)\s*\((?i:you|me)\)$/#) else { return nil }
        return String(m.output.1)
    }
}

// MARK: - Window titles

public enum SpeakerWindows {
    /// The meeting window by title, as Wispr Flow binds it (Zoom also by `AXIdentifier`, see
    /// `MeetingDetection.zoomMeetingWindowID`).
    public static func isMeetingWindow(title: String, platform: SpeakerPlatform) -> Bool {
        let t = title.lowercased()
        switch platform {
        case .zoom: return t.contains("zoom meeting") || t.contains("zoom webinar")
        case .meet: return t.contains("meet.google.com") || ["meet -", "meet –", "meet —"].contains { t.contains($0) }
        case .teams: return t.contains("microsoft teams")
        case .slack: return t.contains("huddle:") || MeetingDetection.isSlackHuddle(windowTitle: title)
        }
    }

    /// The Meet code in a window title ("Meet – abc-defg-hij - Google Chrome"), lowercased.
    public static func meetCode(inTitle title: String) -> String? {
        title.lowercased().firstMatch(of: #/(?:^|[^a-z0-9])([a-z0-9]{3}-[a-z0-9]{4}-[a-z0-9]{3})(?:$|[^a-z0-9])/#)
            .map { String($0.output.1) }
    }

    /// The Meet windows that may show the recorded call, in order. With the call's code known, only the windows
    /// whose title has that code; when none has, those whose title has no code (a meeting titled after its
    /// event). A window showing another code is another meeting and never supplies names, even when the call's
    /// own window is minimised or unreadable (Wispr Flow binds Meet by the tab it captured and reports
    /// `original_tab_missing` rather than reading another one). Every window when the code is unknown.
    public static func meetWindows<W>(_ windows: [W], code: String?, title: (W) -> String) -> [W] {
        guard let code = code?.lowercased() else { return windows }
        let codes = windows.map { meetCode(inTitle: title($0)) }
        let wanted: String? = codes.contains(code) ? code : nil
        return zip(windows, codes).filter { $0.1 == wanted }.map(\.0)
    }
}

// MARK: - Zoom

public enum ZoomSpeakerText {
    /// A participant box in Zoom's meeting window: "Ada Lovelace, Active speaker, Computer audio unmuted, …".
    public struct Box: Equatable, Sendable {
        public var name: String
        public var isSpeaking: Bool
        public var isMuted: Bool
    }

    static let boxMarkers = ["computer audio muted", "computer audio unmuted"]
    /// Buttons of the floating window that are not a participant.
    public static let renderToggles: Set<String> = ["show video render", "hide video render"]

    /// Whether an element's `AXDescription` marks a participant box.
    public static func isBox(description: String) -> Bool {
        let lower = description.lowercased()
        return boxMarkers.contains { lower.contains($0) }
    }

    /// The box's name (up to the first comma, so an empty first field is no name), whether it is the active
    /// speaker and whether it is muted.
    public static func box(description: String) -> Box? {
        guard isBox(description: description) else { return nil }
        let lower = description.lowercased()
        guard let first = description.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first,
              let name = SpeakerNames.clean(String(first)), SpeakerNames.isPlausible(name) else { return nil }
        return Box(name: name, isSpeaking: lower.contains("active speaker"), isMuted: lower.contains("computer audio muted"))
    }

    /// Everything a box shows, as one tile: its name, whether it is the user's own ("Sam Park (Me)" is the user,
    /// named "Sam Park"; Zoom marks no own box otherwise), muted and speaking. Read whole on every poll, so a box
    /// Zoom hands to someone else, or a participant who renames, shows the new name at once.
    public static func tile(description: String) -> SpeakerTile? {
        guard let box = box(description: description) else { return nil }
        let own = SpeakerNames.selfName(fromLabel: box.name)
        return SpeakerTile(name: own ?? box.name, isSelf: own != nil, isMuted: box.isMuted, isLit: box.isSpeaking)
    }

    /// The speaker in the floating window's "Talking: Ada Lovelace" (`AXStaticText` value), as one name.
    public static func talkingLabel(_ value: String) -> String? {
        guard value.hasPrefix("Talking:") else { return nil }
        guard let name = SpeakerNames.clean(String(value.dropFirst("Talking:".count))), SpeakerNames.isPlausible(name) else { return nil }
        return name
    }

    /// The user's microphone from the mute button's label: true muted, false unmuted, nil unknown.
    public static func localMicMuted(buttonLabel: String) -> Bool? {
        switch buttonLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "unmute my audio", "audio, turn on, currently muted": true
        case "mute my audio", "audio, turn off, currently unmuted": false
        default: nil
        }
    }
}

// MARK: - Teams

public enum TeamsSpeakerText {
    /// Which comma-separated field of a gallery tile's `AXDescription` holds the name.
    public enum TileKind: Sendable {
        /// `vdi-dynamic-occlusion` (a video tile): the first field.
        case video
        /// `fui-Primitive` (an avatar tile): the second field.
        case primitive
    }

    public static let callMonitorTitleID = "call-monitor-title-id"
    public static let rosterItemPrefix = "calling-roster-item-"
    public static let rosterSectionPrefix = "roster-title-section-"
    /// The call monitor's label when only the user is talking.
    static let selfSpeakingLabels: Set<String> = ["you are speaking"]
    /// Status words Teams appends to a name.
    static let knownBadges = ["guest", "external", "organizer", "presenter", "muted", "unmuted", "speaking", "is speaking",
                              "video on", "video off", "raised hand", "hand raised", "pinned", "spotlighted", "you"]

    public static func tileKind(classes: [String], video: [String], primitive: [String]) -> TileKind? {
        if classes.contains(where: video.contains) { return .video }
        if classes.contains(where: primitive.contains) { return .primitive }
        return nil
    }

    /// The name on a gallery tile, without the badges Teams adds after it.
    public static func tileName(description: String, kind: TileKind) -> String? {
        let fields = description.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let index = kind == .video ? 0 : 1
        guard fields.indices.contains(index), let name = SpeakerNames.clean(stripBadges(fields[index])),
              SpeakerNames.isPlausible(name) || SpeakerNames.selfName(fromLabel: name) != nil else { return nil }
        return name
    }

    /// Separators left between a name and a badge.
    static let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;·-–—"))

    /// Removes known badge words at the end ("Ada Lovelace Organizer" → "Ada Lovelace").
    public static func stripBadges(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for badge in knownBadges {
                let lower = t.lowercased()
                guard lower.count > badge.count + 1, lower.hasSuffix(" " + badge) else { continue }
                t = String(t.dropLast(badge.count)).trimmingCharacters(in: separators)
                changed = true
            }
        }
        return t
    }

    public static func isMuted(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("muted") && !lower.contains("unmuted")
    }

    /// What the compact call monitor's label says, matched against the names on the gallery tiles.
    public enum CompactLabel: Equatable, Sendable {
        case selfSpeaking
        case name(String)
        case ambiguous
        case unrecognized
    }

    /// "You are speaking" is the user. Otherwise the label must be one known tile name (by key), or a known name
    /// followed only by badge words; several matches are ambiguous.
    public static func resolveCompactLabel(_ label: String, knownNames: [String]) -> CompactLabel {
        guard let cleaned = SpeakerNames.clean(label) else { return .unrecognized }
        if selfSpeakingLabels.contains(cleaned.lowercased()) { return .selfSpeaking }
        let key = SpeakerNames.key(cleaned)
        var hits: [String: String] = [:]
        for name in knownNames {
            let k = SpeakerNames.key(name)
            guard !k.isEmpty else { continue }
            if k == key {
                hits[k] = name
            } else if key.hasPrefix(k + " ") || key.hasPrefix(k + ",") {
                let rest = String(key.dropFirst(k.count)).trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                if knownBadges.contains(rest) { hits[k] = name }
            }
        }
        switch hits.count {
        case 0: return .unrecognized
        case 1: return .name(hits.values.first!)
        default: return .ambiguous
        }
    }

    /// The user's microphone from the `microphone-button` label: true muted, false unmuted, nil unknown.
    public static func localMicMuted(buttonLabel: String) -> Bool? {
        let lower = buttonLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("unmute mic") { return true }
        if lower.hasPrefix("mute mic") { return false }
        return nil
    }
}

// MARK: - Slack

public enum SlackSpeakerText {
    /// "View Ada Lovelace’s profile" → "Ada Lovelace" (a huddle tile's `AXDescription`).
    public static func profileName(_ description: String) -> String? {
        let t = description.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{02BC}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let head = t.range(of: "view ", options: [.caseInsensitive, .anchored]),
              let tail = t.range(of: "'s profile", options: [.caseInsensitive, .anchored, .backwards]),
              head.upperBound <= tail.lowerBound else { return nil }
        return SpeakerNames.clean(String(t[head.upperBound..<tail.lowerBound]))
    }
}

// MARK: - Web classes

/// The obfuscated web classes the Meet, Teams and Slack readers look for. They change when those apps ship, so
/// each list can be replaced from user defaults (an array or a comma-separated string) without a new build.
public struct SpeakerClassNames: Equatable, Sendable {
    public var meetTileRoots = ["oZRSLe"]
    public var meetMarkers = ["kssMZb"]
    public var teamsMarkers = ["vdi-frame-occlusion"]
    public var teamsVideoTiles = ["vdi-dynamic-occlusion"]
    public var teamsPrimitiveTiles = ["fui-Primitive"]
    public var slackTileRoots = ["p-huddle_peer_tile"]
    public var slackMarkers = ["p-huddle_peer_tile__overlay--active_speaker"]

    public static let `default` = SpeakerClassNames()

    /// User-defaults keys of the overrides.
    public static let overrideKeys: [String: WritableKeyPath<SpeakerClassNames, [String]>] = [
        "ShoutSpeakerMeetTileRootClasses": \.meetTileRoots, "ShoutSpeakerMeetMarkerClasses": \.meetMarkers,
        "ShoutSpeakerTeamsMarkerClasses": \.teamsMarkers, "ShoutSpeakerTeamsVideoTileClasses": \.teamsVideoTiles,
        "ShoutSpeakerTeamsPrimitiveTileClasses": \.teamsPrimitiveTiles,
        "ShoutSpeakerSlackTileRootClasses": \.slackTileRoots, "ShoutSpeakerSlackMarkerClasses": \.slackMarkers,
    ]

    public init() {}

    /// The defaults with any overrides from `value(key)`; an empty or unreadable override keeps the default.
    public init(overrides value: (String) -> Any?) {
        self.init()
        for (key, path) in Self.overrideKeys {
            let list: [String]
            switch value(key) {
            case let a as [String]: list = a
            case let s as String: list = s.split(separator: ",").map(String.init)
            default: continue
            }
            let cleaned = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !cleaned.isEmpty { self[keyPath: path] = cleaned }
        }
    }

    /// The tile roots and speaking markers of a web platform.
    public func tileRoots(_ platform: SpeakerPlatform) -> [String] {
        switch platform {
        case .meet: meetTileRoots
        case .teams: teamsVideoTiles + teamsPrimitiveTiles
        case .slack: slackTileRoots
        case .zoom: []
        }
    }

    public func markers(_ platform: SpeakerPlatform) -> [String] {
        switch platform {
        case .meet: meetMarkers
        case .teams: teamsMarkers
        case .slack: slackMarkers
        case .zoom: []
        }
    }
}

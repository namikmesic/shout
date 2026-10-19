import Foundation

// Call detection: which app holding the microphone is a meeting, and when a recorded call has ended.
// Pure logic only (no AppKit, Core Audio or Accessibility), so all of it is unit-tested.
// The app side lives in Shout/System (MicActivityMonitor, CallContextProbe, CallDetector).

/// A conferencing service or calling app.
public enum MeetingPlatform: String, Sendable, CaseIterable {
    case zoom, meet, teams, webex, facetime, slack, discord, whatsapp
    case lark, gather, voov, dialpadMeetings, dialpad, aircall, tuple, clickup
    case gotomeeting, whereby, jitsi
    /// A browser holding the microphone without any meeting evidence.
    case other

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .facetime: "FaceTime"
        case .slack: "Slack"
        case .discord: "Discord"
        case .whatsapp: "WhatsApp"
        case .lark: "Lark"
        case .gather: "Gather"
        case .voov: "VooV Meeting"
        case .dialpadMeetings: "Dialpad Meetings"
        case .dialpad: "Dialpad"
        case .aircall: "Aircall"
        case .tuple: "Tuple"
        case .clickup: "ClickUp"
        case .gotomeeting: "GoTo Meeting"
        case .whereby: "Whereby"
        case .jitsi: "Jitsi Meet"
        case .other: "Call"
        }
    }

    /// Whether a confirmed call on this platform may start the Scribe automatically. Chat and phone
    /// apps (Discord, WhatsApp, Aircall, …) can still show the prompt, but never start on their own.
    public var autoStartEligible: Bool {
        switch self {
        case .discord, .whatsapp, .dialpad, .aircall, .tuple, .clickup, .other: false
        default: true
        }
    }

    /// The platform of a calendar event's conference link.
    public init(service: ConferenceService) {
        switch service {
        case .zoom: self = .zoom
        case .googleMeet: self = .meet
        case .teams: self = .teams
        case .webex: self = .webex
        case .facetime: self = .facetime
        }
    }
}

/// How a process holding the microphone is treated.
public enum MeetingAppKind: Equatable, Sendable {
    /// A calling app: holding the microphone is a call by itself.
    case meetingApp(MeetingPlatform)
    /// A browser: a call only with a meeting URL or meeting tab.
    case browser
    /// Slack: a call only while a huddle window is open.
    case slack
    /// Anything else (dictation tools, voice memos, Shout itself, …).
    case ignored
}

/// A process currently using audio input, with the app it belongs to (helpers resolved to their app).
public struct MicHolder: Equatable, Hashable, Sendable {
    /// The process that has input running (for browsers usually a helper process).
    public var pid: pid_t
    /// Its bundle ID as reported by Core Audio ("" if none).
    public var bundleID: String
    /// The app the process belongs to; Accessibility and "app quit" checks use this pid.
    public var appPID: pid_t
    public var appBundleID: String
    public var appName: String

    public init(pid: pid_t, bundleID: String, appPID: pid_t? = nil, appBundleID: String? = nil, appName: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.appPID = appPID ?? pid
        self.appBundleID = appBundleID ?? bundleID
        self.appName = appName
    }
}

/// What Accessibility shows of an app's windows. Empty arrays mean "read, nothing found";
/// a missing context (nil) means "could not read" (no permission, or the app did not answer).
public struct MeetingContext: Equatable, Sendable {
    /// Front-tab URL of each browser window (focused window first).
    public var urls: [String]
    public var windowTitles: [String]
    /// Browser tab-strip titles (Chromium adds " - Microphone recording" to tabs using the mic).
    public var tabTitles: [String]
    /// Meeting URLs seen in this browser in the last few minutes (the tab may be in the background now).
    public var recentURLs: [String]
    /// Windows' `AXIdentifier`s (Zoom names its meeting window "zm.meeting.window.main" in every language).
    public var windowIdentifiers: [String]

    public init(urls: [String] = [], windowTitles: [String] = [], tabTitles: [String] = [], recentURLs: [String] = [],
                windowIdentifiers: [String] = []) {
        self.urls = urls
        self.windowTitles = windowTitles
        self.tabTitles = tabTitles
        self.recentURLs = recentURLs
        self.windowIdentifiers = windowIdentifiers
    }
}

/// A call found holding the microphone.
public struct DetectedCall: Equatable, Hashable, Sendable {
    /// The app's pid (not the helper process).
    public var pid: pid_t
    public var bundleID: String
    public var appName: String
    public var platform: MeetingPlatform
    /// The meeting URL that identified a browser call.
    public var url: String?
    /// Meet `abc-defg-hij`, Zoom meeting number, Teams meeting key, … when known.
    public var meetingCode: String?
    /// True when holding the mic is proof enough of a meeting to auto-start (see `MeetingDetection.detect`).
    public var qualifiesForAutoStart: Bool
    /// The calendar occurrence this call belongs to, by meeting code or time window (`MeetingDetection.eventKey`).
    /// Set by the app, which has the calendar.
    public var eventKey: String?

    public init(pid: pid_t, bundleID: String, appName: String, platform: MeetingPlatform, url: String? = nil,
                meetingCode: String? = nil, qualifiesForAutoStart: Bool, eventKey: String? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.platform = platform
        self.url = url
        self.meetingCode = meetingCode
        self.qualifiesForAutoStart = qualifiesForAutoStart
        self.eventKey = eventKey
    }

    /// Label for prompts: the service ("Google Meet") for browser calls, otherwise the app name.
    public var displayName: String { platform == .other ? appName : platform.displayName }

    /// Same call: same platform, and the same meeting code when both are known, otherwise the same app.
    /// A browser holding the mic without evidence (`.other`) is the same call as a meeting later found in it.
    public func isSameCall(as other: DetectedCall) -> Bool {
        let sameApp = bundleID.lowercased() == other.bundleID.lowercased()
        guard platform == other.platform else { return (platform == .other || other.platform == .other) && sameApp }
        if let a = meetingCode, let b = other.meetingCode { return a.lowercased() == b.lowercased() }
        return sameApp
    }

    /// `isSameCall` without the `.other` rule: a browser holding the mic without evidence only matches another
    /// such call of the same browser.
    public func isSameCallStrictly(as other: DetectedCall) -> Bool {
        platform == other.platform && isSameCall(as: other)
    }

    /// The same meeting for certain: same platform and the same meeting code. Code-less calls never are
    /// (two Zoom calls in a row are the same app, not the same meeting).
    public func isSameMeeting(as other: DetectedCall) -> Bool {
        guard platform == other.platform, let a = meetingCode, let b = other.meetingCode else { return false }
        return a.lowercased() == b.lowercased()
    }

    /// `self` says more about the call than `old`: it qualifies now, or gained a URL, code, platform or event.
    public func improves(on old: DetectedCall) -> Bool {
        (qualifiesForAutoStart && !old.qualifiesForAutoStart) || (url != nil && old.url == nil)
            || (meetingCode != nil && old.meetingCode == nil) || (eventKey != nil && old.eventKey == nil)
            || (platform != .other && old.platform == .other)
    }

    /// `self`, keeping what `old` already knew and this observation lacks (URL, meeting code, event, auto-start).
    /// A read that gains a URL but misses the code still names the same meeting.
    func merged(over old: DetectedCall) -> DetectedCall {
        var c = self
        c.url = url ?? old.url
        c.meetingCode = meetingCode ?? old.meetingCode
        c.eventKey = eventKey ?? old.eventKey
        c.qualifiesForAutoStart = qualifiesForAutoStart || old.qualifiesForAutoStart
        return c
    }
}

public enum MeetingDetection {

    // MARK: Allowlist

    /// Bundle IDs (lowercased). An ID matches an entry exactly or as a prefix followed by "."
    /// ("com.google.chrome" covers "com.google.Chrome.helper" and "com.google.chrome.canary").
    private static let allowlist: [(String, MeetingAppKind)] = {
        let apps: [(MeetingPlatform, [String])] = [
            (.zoom, ["us.zoom.xos"]),
            (.teams, ["com.microsoft.teams", "com.microsoft.teams2"]),
            (.webex, ["com.cisco.webexmeetingsapp", "cisco-systems.spark", "com.webex.meetingmanager"]),
            (.facetime, ["com.apple.facetime", "com.apple.avconferenced"]),
            (.lark, ["com.larksuite.larkapp"]),
            (.gather, ["com.gather.gather"]),
            (.voov, ["com.tencent.tencentmeeting"]),
            (.dialpadMeetings, ["com.electron.uberconference"]),
            // Chat and phone apps: prompt, never auto-start.
            (.discord, ["com.hnc.discord", "com.hnc.discordptb", "com.hnc.discordcanary"]),
            (.whatsapp, ["net.whatsapp.whatsapp", "desktop.whatsapp"]),
            (.dialpad, ["com.electron.dialpad"]),
            (.aircall, ["io.aircall.phone", "io.aircall.workspace"]),
            (.tuple, ["app.tuple.app"]),
            (.clickup, ["com.clickup.desktop-app"]),
        ]
        let browsers = [
            "com.google.chrome", "org.chromium.chromium", "com.microsoft.edgemac", "com.brave.browser",
            "company.thebrowser.browser", "company.thebrowser.dia", "ai.perplexity.comet", "com.openai.atlas",
            "com.operasoftware.opera", "com.operasoftware.operagx", "com.vivaldi.vivaldi", "app.zen-browser.zen",
            "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
            "org.mozilla.plugincontainer",
            // Safari captures in the shared WebKit GPU process.
            "com.apple.safari", "com.apple.safaritechnologypreview", "com.apple.webkit.gpu",
        ]
        return apps.flatMap { p, ids in ids.map { ($0, MeetingAppKind.meetingApp(p)) } }
            + browsers.map { ($0, .browser) }
            + [("com.tinyspeck.slackmacgap", .slack)]
    }()

    /// Classifies a bundle ID (case-insensitive). Unknown apps are `.ignored`.
    public static func kind(bundleID: String) -> MeetingAppKind {
        let id = bundleID.lowercased()
        guard !id.isEmpty else { return .ignored }
        for (entry, kind) in allowlist where id == entry || id.hasPrefix(entry + ".") { return kind }
        return .ignored
    }

    /// The kind of a holder: its own bundle ID first, then its app's (a helper with an unlisted ID).
    public static func kind(of holder: MicHolder) -> MeetingAppKind {
        let own = kind(bundleID: holder.bundleID)
        return own == .ignored ? kind(bundleID: holder.appBundleID) : own
    }

    // MARK: Decision

    /// Turns a microphone holder and what Accessibility shows of its app into a call.
    ///
    /// - Calling apps (Zoom, Teams, FaceTime, Discord, …): always a call; `qualifiesForAutoStart`
    ///   follows `MeetingPlatform.autoStartEligible`.
    /// - Browsers: a call only with a meeting URL (front tab of any window, or recently seen) or a
    ///   meeting tab/window title (Meet, Teams, Slack huddle).
    /// - Slack: a call only while a window title shows a huddle, or one did in the last few minutes
    ///   (`slackHuddleSeen`, see `SlackHuddleMarker`).
    ///
    /// With `includeUnconfirmed`, browsers and Slack without evidence are returned too, as calls that
    /// never qualify for auto-start (Wispr's "detect any call"); otherwise they are nil.
    ///
    /// `preferCode`: the meeting code of the call already recorded or prompted in this app. Among equally strong
    /// evidence, the tab or URL with that code wins (another meeting's tab opened beside it is not the call).
    public static func detect(holder: MicHolder, context: MeetingContext?, includeUnconfirmed: Bool = false,
                              slackHuddleSeen: Bool = false, preferCode: String? = nil) -> DetectedCall? {
        func call(_ platform: MeetingPlatform, url: String? = nil, code: String? = nil, qualifies: Bool) -> DetectedCall {
            DetectedCall(pid: holder.appPID, bundleID: holder.appBundleID, appName: holder.appName,
                         platform: platform, url: url, meetingCode: code, qualifiesForAutoStart: qualifies)
        }
        switch kind(of: holder) {
        case .ignored:
            return nil
        case .meetingApp(let platform):
            return call(platform, qualifies: platform.autoStartEligible)
        case .slack:
            if slackHuddleSeen || context?.windowTitles.contains(where: isSlackHuddle) == true { return call(.slack, qualifies: true) }
            return includeUnconfirmed ? call(.slack, qualifies: false) : nil
        case .browser:
            if let ctx = context, let found = browserEvidence(ctx, preferCode: preferCode) {
                // Auto-start only for a Meet, Zoom or Teams meeting in the tab using the mic or in a front tab
                // (as Wispr Flow); background tabs, remembered URLs and other titles only prompt.
                let strong = found.frontTab && [.meet, .zoom, .teams].contains(found.platform)
                return call(found.platform, url: found.url, code: found.code, qualifies: strong)
            }
            return includeUnconfirmed ? call(.other, qualifies: false) : nil
        }
    }

    /// `AXIdentifier` of Zoom's meeting window, the same in every language.
    public static let zoomMeetingWindowID = "zm.meeting.window.main"

    /// Whether the recorded call is still visible in its app, used as stop evidence after the app
    /// released the mic. nil when it cannot be told (no context, or no rule for that app).
    public static func isCallStillVisible(_ call: DetectedCall, context: MeetingContext?) -> Bool? {
        guard let ctx = context else { return nil }
        switch kind(bundleID: call.bundleID) {
        case .browser:
            if let code = call.meetingCode?.lowercased() {
                let texts = ctx.urls.map { $0.removingPercentEncoding ?? $0 } + ctx.tabTitles + ctx.windowTitles
                return texts.contains { $0.lowercased().contains(code) }
            }
            return browserEvidence(ctx)?.platform == call.platform
        case .slack:
            return ctx.windowTitles.contains(where: isSlackHuddle)
        case .meetingApp(.zoom):
            if ctx.windowIdentifiers.contains(zoomMeetingWindowID) { return true }
            // A Zoom that names its windows but not the meeting window has no meeting window open.
            if ctx.windowIdentifiers.contains(where: { $0.hasPrefix("zm.") }) { return false }
            // Fallback for Zoom builds without identifiers: English window titles only; elsewhere this
            // reads as "gone", which only shortens the stop window.
            return ctx.windowTitles.contains { let t = $0.lowercased(); return t.contains("zoom meeting") || t.contains("zoom webinar") }
        default:
            return nil
        }
    }

    /// Key of one calendar occurrence, the same for an `UpcomingEvent` and a meeting linked to it
    /// (`calendarEventID` + `calendarOccurrenceStart`).
    public static func eventKey(externalID: String, occurrenceStart: Date) -> String {
        "\(externalID)@\(Int64(occurrenceStart.timeIntervalSince1970.rounded()))"
    }

    public static func eventKey(_ event: UpcomingEvent) -> String {
        eventKey(externalID: event.externalID, occurrenceStart: event.occurrenceStart)
    }

    /// Strongest first: a tab Chromium marks as using the mic, a window's front-tab URL, a meeting URL
    /// seen recently, then any tab or window title (unmarked tabs only count when no tab is marked).
    /// Within each kind, the one with `preferCode` comes first.
    private static func browserEvidence(_ ctx: MeetingContext, preferCode: String? = nil)
        -> (platform: MeetingPlatform, url: String?, code: String?, frontTab: Bool)? {
        let prefer = preferCode?.lowercased()
        func preferring(_ list: [String], code: (String) -> String?) -> [String] {
            guard let prefer, let i = list.firstIndex(where: { code($0)?.lowercased() == prefer }) else { return list }
            var l = list
            l.insert(l.remove(at: i), at: 0)
            return l
        }
        let marked = preferring(ctx.tabTitles.filter(hasRecordingMarker)) { parse(title: $0)?.1 }
        for title in marked {
            guard let (platform, titleCode) = parse(title: title) else { continue }
            guard let code = titleCode else {
                // A title without a code (Teams, a Meet named after its event) doesn't say which meeting it is,
                // so it takes no code from elsewhere (another tab's URL, or a meeting seen minutes ago). The live
                // URL is kept for the calendar link only when it is the one of that service on screen.
                let live = ctx.urls.filter { parse(url: $0)?.0 == platform }
                return (platform, live.count == 1 ? live[0] : nil, nil, true)
            }
            // The marker names the tab that uses the mic, which says more than "front tab". Its URL (live or
            // seen recently) is still wanted for the calendar link; a Meet URL can be rebuilt from the code.
            let url = (ctx.urls + ctx.recentURLs).first { u in
                guard let (p, c) = parse(url: u), p == platform else { return false }
                return c?.lowercased() == code
            } ?? (platform == .meet ? "https://meet.google.com/\(code)" : nil)
            return (platform, url, code, true)
        }
        for url in preferring(ctx.urls, code: { parse(url: $0)?.1 }) {
            if let (platform, code) = parse(url: url) { return (platform, url, code, true) }
        }
        for url in preferring(ctx.recentURLs, code: { parse(url: $0)?.1 }) {
            if let (platform, code) = parse(url: url) { return (platform, url, code, false) }
        }
        for title in (marked.isEmpty ? ctx.tabTitles : []) + ctx.windowTitles {
            if let (platform, code) = parse(title: title) { return (platform, nil, code, false) }
        }
        return nil
    }

    // MARK: URLs

    /// The service of a meeting URL; nil for landing, marketing and app-shell pages.
    public static func platform(forURL url: String) -> MeetingPlatform? { parse(url: url)?.0 }

    /// The meeting's identity in a URL: Meet `abc-defg-hij`, Zoom meeting number, Teams meeting key
    /// (`meetup-join` thread or `/meet/` id), Webex meeting, Slack huddle channel, … nil if none.
    public static func meetingCode(forURL url: String) -> String? { parse(url: url)?.1 }

    private static func parse(url string: String) -> (MeetingPlatform, String?)? {
        guard let comps = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = comps.host?.lowercased() else { return nil }
        func on(_ domains: String...) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        let parts = comps.path.split(separator: "/").map(String.init)
        let first = parts.first?.lowercased() ?? ""
        func query(_ name: String) -> String? {
            comps.queryItems?.first { $0.name.lowercased() == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        if host == "meet.google.com" {
            if first.wholeMatch(of: meetCodePattern) != nil { return (.meet, first) }
            if first == "lookup", parts.count >= 2 { return (.meet, nil) }
            return nil
        }
        if on("zoom.us", "zoomgov.com") {
            let p = parts.map { $0.lowercased() }
            func number(_ s: String) -> String? { s.wholeMatch(of: #/\d{6,13}/#) != nil ? s : nil }
            if p.count >= 2, ["j", "s", "w"].contains(p[0]), let n = number(p[1]) { return (.zoom, n) }
            if p.count >= 3, p[0] == "wc", p[1] == "join", let n = number(p[2]) { return (.zoom, n) }
            if p.count >= 2, p[0] == "wc", let n = number(p[1]) { return (.zoom, n) }
            if p.count >= 2, p[0] == "my" { return (.zoom, nil) }
            return nil
        }
        if on("teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft", "teams.microsoft.us") {
            // The meeting can be in the path or, in the web client, in the fragment ("#/l/meetup-join/…").
            let full = (comps.percentEncodedPath + "#" + (comps.percentEncodedFragment ?? "")).removingPercentEncoding ?? comps.path
            if let m = full.firstMatch(of: #/(?i)\/l\/meetup-join\/([^\/?#]+)/#) { return (.teams, String(m.1)) }
            if let m = full.firstMatch(of: #/(?i)\/meet\/([^\/?#]+)/#) { return (.teams, String(m.1)) }
            if full.lowercased().contains("/light-meetings/") || query("meetingjoin") == "true" { return (.teams, nil) }
            return nil
        }
        if on("webex.com") {
            if parts.count >= 2, let i = parts.firstIndex(where: { $0.lowercased() == "meet" }), i + 1 < parts.count {
                return (.webex, parts[i + 1].lowercased())
            }
            if first == "j.php" || parts.last?.lowercased() == "j.php" { return (.webex, query("mtid")) }
            let lower = comps.path.lowercased()
            if lower.contains("/joinservice/") || lower.contains("/webappng/") {
                return (.webex, lower.firstMatch(of: #/\d{9,12}/#).map { String($0.0) })
            }
            return nil
        }
        if on("slack.com"), first == "huddle", parts.count >= 2 {
            return (.slack, parts.dropFirst().joined(separator: "/"))
        }
        if on("discord.com", "discordapp.com"), first == "channels", parts.count >= 3 {
            return (.discord, parts[1] + "/" + parts[2])
        }
        if on("goto.com", "gotomeeting.com") {
            if let n = parts.first(where: { $0.wholeMatch(of: #/\d{9}/#) != nil }),
               ["meeting", "join"].contains(first) || host.hasPrefix("meet.") { return (.gotomeeting, n) }
            return nil
        }
        if on("whereby.com"), parts.count == 1, !wherebyReserved.contains(first) { return (.whereby, first) }
        if host == "meet.jit.si" || host == "8x8.vc", let room = parts.last, !room.isEmpty, !first.hasPrefix("static") {
            return (.jitsi, room.lowercased())
        }
        return nil
    }

    private static let meetCodePattern = #/[a-z]{3}-[a-z]{4}-[a-z]{3}/#
    private static let wherebyReserved: Set<String> = ["", "user", "login", "information", "org", "pricing", "blog",
                                                       "signup", "embed", "partners", "legal", "download"]

    // MARK: Titles

    /// A huddle in one of Slack's own windows: "Huddle: #channel", "[Main]", or a title that names Slack
    /// and a huddle (`isSlackHuddleTitle`).
    public static func isSlackHuddle(windowTitle title: String) -> Bool {
        title.contains("[Main]") || title.firstMatch(of: #/^\s*(?i:huddle)\s*:/#) != nil || isSlackHuddleTitle(title)
    }

    /// A title that names both Slack and a huddle as separate words ("Huddle: #eng - Acme - Slack"), or
    /// Slack's 🎤 marker. The only Slack rule for browser windows and tabs.
    public static func isSlackHuddleTitle(_ title: String) -> Bool {
        if title.firstMatch(of: #/(?i)slack\s*🎤/#) != nil { return true }
        let slack = #/(?i)(?:^|[\s|]|[-–—]\s*)slack(?:[\s|]|[-–—]|$)/#
        let huddle = #/(?i)(?:^|[\s|]|[-–—]\s*)huddle\s*:/#
        return title.firstMatch(of: slack) != nil && title.firstMatch(of: huddle) != nil
    }

    /// Chromium's tab-title suffixes for tabs that use the microphone.
    public static func hasRecordingMarker(_ tabTitle: String) -> Bool {
        tabTitle.lowercased().contains("microphone recording")
    }

    /// A meeting from a tab or window title: "Meet - abc-defg-hij", a bare Meet code,
    /// "… | Microsoft Teams", or a Slack huddle.
    private static func parse(title: String) -> (MeetingPlatform, String?)? {
        let t = title.lowercased().trimmingCharacters(in: .whitespaces)
        let code = t.firstMatch(of: #/\b([a-z]{3}-[a-z]{4}-[a-z]{3})\b/#).map { String($0.1) }
        if t.firstMatch(of: #/^meet\s+[-–—]\s+\S/#) != nil || t.firstMatch(of: #/^[a-z]{3}-[a-z]{4}-[a-z]{3}\b/#) != nil {
            return (.meet, code)
        }
        if t.contains("| microsoft teams") { return (.teams, nil) }
        if isSlackHuddleTitle(title) { return (.slack, nil) }
        return nil
    }
}

/// Wispr Flow's "huddle seen" marker: Slack's focused window showing a huddle counts for a few minutes,
/// so a huddle whose window is closed, or not titled yet when Slack opens the mic, still qualifies.
/// Any other focused-window title clears it.
public struct SlackHuddleMarker: Sendable {
    public static let validFor: TimeInterval = 5 * 60
    private var seenAt: Date?

    public init() {}

    /// The title of Slack's focused window, read when Slack is in front.
    public mutating func note(windowTitle: String, at now: Date) {
        seenAt = MeetingDetection.isSlackHuddle(windowTitle: windowTitle) ? now : nil
    }

    public func isFresh(at now: Date) -> Bool {
        seenAt.map { now.timeIntervalSince($0) < Self.validFor } ?? false
    }
}

// MARK: - Session tracking

/// Decides when to prompt for a detected call and when a recorded call has ended.
///
/// Feed it the calls holding the microphone (`observe`), the app's own events (recording started or
/// stopped, prompt declined or snoozed, Keep going, sleep and wake, audio changes) and a clock (`tick`,
/// about twice a second while `needsTick`). Each call returns the UI actions to perform. Time is passed
/// in, so the whole state machine is deterministic.
public struct CallSessionTracker: Sendable {
    public enum Action: Equatable, Sendable {
        /// Show "Meeting detected" for this call (auto-start countdown is the app's choice). Sent again for
        /// the same prompt when its call is identified better (a URL, a calendar event): update the card.
        case prompt(DetectedCall)
        /// Hide the prompt (timed out, the call went away, or recording started some other way).
        case dismissPrompt
        /// Show "Scribe stopping" with [Keep going] [Stop]; the tracker emits `.stop` at `deadline`.
        case showStopping(deadline: Date)
        /// Hide the stopping banner (the call came back, Keep going, or the recording ended otherwise).
        case cancelStopping
        /// Stop the recording now (auto-stop).
        case stop
        /// The call of a recording that stopped by itself (call ended, Mac slept) came back: resume the same meeting.
        case offerResume(DetectedCall)
    }

    /// Asynchronous evidence that the recorded call ended, reported after its app released the mic.
    public enum Corroboration: Sendable {
        /// The call's app is no longer running.
        case appQuit
        /// The meeting tab or window was looked for and is gone.
        case windowGone
    }

    /// What a recording belongs to, so it only ever follows its own call.
    public struct Target: Equatable, Sendable {
        /// The calendar occurrence the note is linked to (`MeetingDetection.eventKey`).
        public var eventKey: String?
        /// When that event ends: a call lost near the end stops sooner.
        public var eventEnd: Date?
        /// Join + Start: the event's service. A call of it that starts after the recording is the meeting.
        public var platform: MeetingPlatform?
        /// Resume: the call the note was recorded from, when known.
        public var previousCall: DetectedCall?
        /// Resume of an existing note: never just the call that happens to hold the mic.
        public var isResume: Bool

        public init(eventKey: String? = nil, eventEnd: Date? = nil, platform: MeetingPlatform? = nil,
                    previousCall: DetectedCall? = nil, isResume: Bool = false) {
            self.eventKey = eventKey
            self.eventEnd = eventEnd
            self.platform = platform
            self.previousCall = previousCall
            self.isResume = isResume
        }
    }

    // MARK: Constants

    /// The recorded call must be missing this long before the loss counts (mic flaps on device changes).
    public static let absenceConfirm: TimeInterval = 1.5
    /// …and missing from this many observations; 2 while the conversation is warm (see `warmSpeech`).
    public static let confirmPolls = 1, confirmPollsWhenWarm = 2
    /// Speech within this long makes the conversation "warm" (stricter loss confirmation).
    public static let warmSpeech: TimeInterval = 60
    /// Speech within this long vetoes showing the stopping banner…
    public static let speechVeto: TimeInterval = 5
    /// …but never for longer than this after the loss was confirmed.
    public static let speechVetoCap: TimeInterval = 30
    /// Quiet wait after a confirmed loss, by evidence: app quit or meeting window/tab gone…
    public static let corroboratedWindow: TimeInterval = 1
    /// …a native calling app released the mic, or the call's calendar event is ending…
    public static let nativeReleaseWindow: TimeInterval = 3.5
    /// …anything else (browser without proof, default input device just changed).
    public static let ambiguousWindow: TimeInterval = 5.5
    /// A default-input change this close to the loss makes it ambiguous (apps reopen the new device).
    public static let deviceChangeDemote: TimeInterval = 10
    /// A loss this close to the end of the recording's calendar event is expected: shorter window, and
    /// no `minSessionAge` guard.
    public static let eventEndProximity: TimeInterval = 5 * 60
    /// The stopping banner stays up at least this long before the recording stops.
    public static let minStoppingBanner: TimeInterval = 6
    /// No auto-stop in a session's first seconds (the call may still be connecting)…
    public static let minSessionAge: TimeInterval = 15
    /// …or this soon after wake or a Core Audio restart (process objects are being rebuilt).
    public static let holdoff: TimeInterval = 10
    /// A recording without a call looks for one that belongs to it (`Target`) at most this many times,
    /// once per change in the calls holding the mic.
    public static let lateBindAttempts = 24
    /// A declined or ignored prompt stays quiet until its call has been gone this long…
    public static let latchClearAfterFree: TimeInterval = 15
    /// …or at most this long.
    public static let latchMax: TimeInterval = 4 * 3600
    /// "Snooze for 2 min".
    public static let snooze: TimeInterval = 120
    /// The prompt goes away on its own after this long (counts as ignored).
    public static let promptTimeout: TimeInterval = 20
    /// A prompt is updated in place at most this many times as its call is identified better.
    public static let maxPromptUpdates = 3
    /// A recording's call coming back within this long, with the same meeting code, resumes the same meeting…
    public static let resumeWindow: TimeInterval = 120
    /// …or within this long when it also belongs to the same calendar occurrence…
    public static let sameEventResumeWindow: TimeInterval = 600
    /// …(after a sleep stop, counted from wake; the stop waits this long at most for the wake)…
    public static let sleepWakeWait: TimeInterval = 6 * 3600
    /// …at most this many times per meeting (stops flapping loops).
    public static let maxAutoResumes = 2

    // MARK: Settings

    /// Show prompts for new calls (detection on).
    public var promptsEnabled = true
    /// Stop recordings when their call ends ("Stop Scribe when a call ends").
    public var autoStopEnabled = true
    /// Last time anyone spoke in the recording (mic or system). Set by the app before `observe`/`tick`.
    public var lastSpeechAt: Date?

    // MARK: State

    private struct Latch { var call: DetectedCall; var createdAt: Date; var lastSeenAt: Date }
    private struct Prompt { var call: DetectedCall; var shownAt: Date; var absentSince: Date?; var updates = 0 }
    private struct Snooze { var call: DetectedCall; var until: Date }
    private struct Session {
        var call: DetectedCall?
        var target: Target
        var startedAt: Date
        var resumes: Int
        /// Calls holding the mic when the recording started (Join + Start never takes them by service alone).
        var presentAtStart: [DetectedCall]
        var bindAttempts = 0
        var lastCandidates: [DetectedCall] = []
        var absentSince: Date?
        var absentPolls = 0
        var evidence: Set<Corroboration> = []
        /// Loss confirmed; the quiet window runs from here.
        var armedAt: Date?
        /// Banner visible; stop at this time.
        var stopAt: Date?
        /// The user chose Keep going for this absence: no new stop until the call is seen again.
        var keptGoing = false

        /// The call was seen: any loss in progress is over.
        mutating func found() {
            absentSince = nil; absentPolls = 0; evidence = []; armedAt = nil; stopAt = nil; keptGoing = false
        }
    }
    /// A recording that stopped without the user's say (its call ended, or the Mac slept).
    private struct Ended {
        var call: DetectedCall; var eventKey: String?; var at: Date; var resumes: Int; var bySleep: Bool
        /// A sleep stop before `systemDidWake`: its resume window has not started yet (checks can run first at wake).
        var awaitingWake = false
    }

    private var calls: [DetectedCall] = []
    private var latches: [Latch] = []
    private var prompt: Prompt?
    private var promptHeld = false
    private var snoozed: Snooze?
    private var session: Session?
    /// The session the last `.stop` ended, until the next input (see `stopHandedBack`).
    private var stopped: Session?
    private var ended: Ended?
    private var offeredResume: Ended?
    private var holdoffUntil = Date.distantPast
    private var inputChangedAt: Date?

    public init() {}

    public var isRecording: Bool { session != nil }
    /// The call the current recording follows, if any.
    public var boundCall: DetectedCall? { session?.call }
    /// The prompt on screen, if any.
    public var promptedCall: DetectedCall? { prompt?.call }
    /// The call of the recording that last stopped by itself or by sleep, while it may still resume.
    public var endedCall: DetectedCall? { ended?.call }
    /// True while a timer must call `tick` (something is counting down).
    public var needsTick: Bool {
        prompt != nil || snoozed != nil
            || (autoStopEnabled && (session.map { $0.absentSince != nil && !$0.keptGoing } ?? false))
    }

    // MARK: Inputs

    /// The calls holding the microphone now (one observation per poll or Core Audio change).
    public mutating func observe(_ current: [DetectedCall], at now: Date) -> [Action] {
        calls = current
        stopped = nil
        for i in latches.indices where present(latches[i].call) { latches[i].lastSeenAt = now }
        var actions: [Action] = []
        if var p = prompt {
            if let seen = current.first(where: { $0.isSameCall(as: p.call) }) {
                p.absentSince = nil
                if seen.improves(on: p.call), p.updates < Self.maxPromptUpdates {
                    p.call = seen.merged(over: p.call)
                    p.updates += 1
                    // The updated card may start its auto-start countdown only now: it gets a full timeout.
                    p.shownAt = now
                    actions.append(.prompt(p.call))
                }
            } else {
                p.absentSince = p.absentSince ?? now
            }
            prompt = p
        }
        if var s = session {
            if s.call == nil { s.call = lateBind(&s) }
            if var c = s.call {
                if let seen = current.first(where: { Self.sameCall($0, vague: c) }) {
                    if s.stopAt != nil { actions.append(.cancelStopping) }
                    if seen.improves(on: c) { c = seen.merged(over: c) } else { c.pid = seen.pid } // the app may have restarted
                    s.call = c
                    s.found()
                } else {
                    s.absentSince = s.absentSince ?? now
                    s.absentPolls += 1
                }
            }
            session = s
        }
        return actions + advance(now)
    }

    /// Advances timers; call about twice a second while `needsTick`.
    public mutating func tick(at now: Date) -> [Action] {
        stopped = nil
        return advance(now)
    }

    /// Evidence that the recorded call ended (only used while its app is not holding the mic).
    public mutating func corroborate(_ evidence: Corroboration, at now: Date) -> [Action] {
        guard var s = session, s.absentSince != nil else { return [] }
        s.evidence.insert(evidence)
        session = s
        return advance(now)
    }

    /// The call a recording starting now would follow: the call being auto-resumed, one that belongs to
    /// the target (`belongs`), or for a plain start the prompted call or the first that may auto-start.
    /// A plain start never takes a chat, phone or evidence-less browser call, even while it is prompted (only
    /// its own card records it, passing it as `call`).
    public func callToBind(_ target: Target = Target()) -> DetectedCall? {
        if let o = offeredResume, let back = calls.first(where: { $0.isSameCallStrictly(as: o.call) }) { return back }
        if let c = calls.first(where: { belongs($0, to: target, startedWith: calls) }) { return c }
        guard target.platform == nil, !target.isResume else { return nil }
        return (prompt?.call).flatMap { $0.qualifiesForAutoStart ? $0 : nil } ?? calls.first { $0.qualifiesForAutoStart }
    }

    /// A recording started, following `call` (or `callToBind(target)`). An unbound recording later takes
    /// a call that belongs to its target.
    public mutating func recordingStarted(call: DetectedCall? = nil, target: Target = Target(), at now: Date) -> [Action] {
        var actions: [Action] = []
        let bound = call ?? callToBind(target)
        if prompt != nil { prompt = nil; actions.append(.dismissPrompt) }
        var resumes = 0
        if let o = offeredResume, let b = bound, o.call.isSameCall(as: b) { resumes = o.resumes + 1 }
        session = Session(call: bound, target: target, startedAt: now, resumes: resumes, presentAtStart: calls)
        if let b = bound, snoozed?.call.isSameCall(as: b) == true { snoozed = nil }
        ended = nil
        offeredResume = nil
        stopped = nil
        return actions
    }

    /// The recording stopped (user Stop, safety nets, quit). After the tracker's own `.stop` this is a no-op.
    /// Calls still holding the mic are latched, so stopping by hand does not bring the prompt back.
    /// `latch: false` when the stop was not the user's decision but must not resume either (fast user
    /// switch, a failed start), so the call may prompt again afterwards.
    public mutating func recordingStopped(at now: Date, latch shouldLatch: Bool = true) -> [Action] {
        guard let s = session else { return [] }
        session = nil
        ended = nil
        if shouldLatch { for c in calls { latch(c, now) } }
        return s.stopAt != nil ? [.cancelStopping] : []
    }

    /// The Mac is going to sleep and the recording stopped: like an auto-stop, nothing is latched and its
    /// call coming back after wake resumes the same meeting (the window starts at `systemDidWake`).
    public mutating func recordingSuspended(at now: Date) -> [Action] {
        guard let s = session else { return [] }
        session = nil
        ended = s.call.map { Ended(call: $0, eventKey: s.target.eventKey, at: now, resumes: s.resumes, bySleep: true,
                                   awaitingWake: true) }
        return s.stopAt != nil ? [.cancelStopping] : []
    }

    /// [Stop] on the stopping banner: stop now, exactly as the auto-stop would have (Resume offered, and
    /// the call coming back resumes the meeting).
    public mutating func expediteStop(at now: Date) -> [Action] {
        guard let s = session, let call = s.call else { return [] }
        session = nil
        ended = Ended(call: call, eventKey: s.target.eventKey, at: now, resumes: s.resumes, bySleep: false)
        stopped = s
        return [.stop]
    }

    /// The stopping banner could not be shown, or something else took it off screen. The recording never
    /// stops without a visible warning, so the stop is handed back as if the user chose Keep going; this
    /// also undoes a `.stop` emitted just now.
    public mutating func stopHandedBack(at now: Date) -> [Action] {
        if session != nil { return keepGoing(at: now) }
        guard var s = stopped else { return [] }
        s.armedAt = nil
        s.stopAt = nil
        s.keptGoing = true
        session = s
        ended = nil
        stopped = nil
        return []
    }

    /// The user closed the prompt.
    public mutating func promptDeclined(at now: Date) {
        guard let p = prompt else { return }
        prompt = nil
        latch(p.call, now)
    }

    /// "Snooze for 2 min": the prompt comes back then if the call still holds the mic.
    public mutating func promptSnoozed(at now: Date) {
        guard let p = prompt else { return }
        prompt = nil
        snoozed = Snooze(call: p.call, until: now.addingTimeInterval(Self.snooze))
    }

    /// Pauses the prompt's timeout (the pointer is on the card, or nobody is at the Mac). When released,
    /// the prompt gets a full timeout again.
    public mutating func holdPrompt(_ held: Bool, at now: Date) {
        if promptHeld && !held, var p = prompt { p.shownAt = now; prompt = p }
        promptHeld = held
    }

    /// The meeting offered for resuming could not be resumed (deleted, or the Scribe can't start): its
    /// call is prompted like any new call instead.
    public mutating func resumeFailed(at now: Date) -> [Action] {
        guard let o = offeredResume else { return [] }
        offeredResume = nil
        latches.removeAll { $0.call.isSameCall(as: o.call) }
        guard session == nil, promptsEnabled, prompt == nil, let c = calls.first(where: { $0.isSameCall(as: o.call) }) else { return [] }
        prompt = Prompt(call: c, shownAt: now)
        return [.prompt(c)]
    }

    /// "Keep going" on the stopping banner: no auto-stop until the call is seen again and lost again.
    public mutating func keepGoing(at now: Date) -> [Action] {
        guard var s = session, s.absentSince != nil else { return [] }
        let visible = s.stopAt != nil
        s.armedAt = nil
        s.stopAt = nil
        s.keptGoing = true
        session = s
        return visible ? [.cancelStopping] : []
    }

    public mutating func systemDidWake(at now: Date) {
        holdoffUntil = max(holdoffUntil, now.addingTimeInterval(Self.holdoff))
        // After a sleep stop the resume window counts from wake.
        if var e = ended, e.bySleep { e.at = now; e.awaitingWake = false; ended = e }
    }
    public mutating func audioServiceRestarted(at now: Date) { holdoffUntil = max(holdoffUntil, now.addingTimeInterval(Self.holdoff)) }
    public mutating func inputDeviceChanged(at now: Date) { inputChangedAt = now }

    // MARK: Logic

    /// Whether `vague` is the call `known`. A browser holding the mic without evidence (`.other`) may be a
    /// meeting known in that browser whose evidence wasn't read this time, but a meeting is never "just the
    /// browser": a declined or recorded `.other` does not stand for a meeting found in it later, and a
    /// recorded meeting is not still there because another tab of its browser holds the mic.
    private static func sameCall(_ known: DetectedCall, vague: DetectedCall) -> Bool {
        known.isSameCallStrictly(as: vague) || (vague.platform == .other && known.isSameCall(as: vague))
    }

    private func present(_ call: DetectedCall) -> Bool { calls.contains { $0.isSameCall(as: call) } }
    private func latched(_ call: DetectedCall) -> Bool { latches.contains { Self.sameCall($0.call, vague: call) } }

    /// Calls that may auto-start first, then in observation order.
    private func best(_ list: [DetectedCall]) -> DetectedCall? {
        list.first { $0.qualifiesForAutoStart } ?? list.first
    }

    /// Whether a call is the meeting a recording is for: one of its calendar event, the call a resumed
    /// note was recorded from, or (Join + Start) a call of the event's service that was not already there
    /// when the recording started. Chat and phone calls and browsers without meeting evidence never are;
    /// they are only recorded from their own prompt.
    private func belongs(_ c: DetectedCall, to t: Target, startedWith existing: [DetectedCall]) -> Bool {
        if let key = t.eventKey, c.eventKey == key, c.platform != .other { return true }
        guard c.qualifiesForAutoStart else { return false }
        if let previous = t.previousCall, c.isSameCall(as: previous) { return true }
        if let p = t.platform, c.platform == p, !existing.contains(where: { $0.isSameCall(as: c) }) { return true }
        return false
    }

    /// An unbound recording takes a call that belongs to it, trying once per new set of calls.
    private func lateBind(_ s: inout Session) -> DetectedCall? {
        guard s.bindAttempts < Self.lateBindAttempts, !calls.isEmpty, calls != s.lastCandidates else { return nil }
        s.lastCandidates = calls
        s.bindAttempts += 1
        return calls.first { belongs($0, to: s.target, startedWith: s.presentAtStart) }
    }

    /// The stopped meeting's own call: the same meeting code (Wispr Flow's `{service, code}` identity) within
    /// `resumeWindow`, or within `sameEventResumeWindow` when it is also of the same calendar occurrence. A
    /// code-less call is a new meeting, whatever its app or event (a call during the event's time window is
    /// not that event's meeting for certain).
    private func isResumable(_ c: DetectedCall, _ e: Ended, at now: Date) -> Bool {
        guard c.isSameMeeting(as: e.call) else { return false }
        if e.awaitingWake { return true }
        let sameEvent = e.eventKey != nil && c.eventKey == e.eventKey
        return now.timeIntervalSince(e.at) <= (sameEvent ? Self.sameEventResumeWindow : Self.resumeWindow)
    }

    /// Expired: past its window (a sleep stop still waiting for the wake: past `sleepWakeWait`), or resumed enough.
    private func isOver(_ e: Ended, at now: Date) -> Bool {
        let window = e.awaitingWake ? Self.sleepWakeWait : (e.eventKey == nil ? Self.resumeWindow : Self.sameEventResumeWindow)
        return now.timeIntervalSince(e.at) > window || e.resumes >= Self.maxAutoResumes
    }

    private mutating func latch(_ call: DetectedCall, _ now: Date) {
        if let i = latches.firstIndex(where: { $0.call.isSameCallStrictly(as: call) }) { latches[i].lastSeenAt = now }
        else { latches.append(Latch(call: call, createdAt: now, lastSeenAt: now)) }
    }

    private func nearEventEnd(_ s: Session) -> Bool {
        guard let end = s.target.eventEnd, let lost = s.absentSince else { return false }
        return abs(end.timeIntervalSince(lost)) <= Self.eventEndProximity
    }

    /// Quiet window for the current loss, by the strongest evidence so far.
    private func stopWindow(_ s: Session) -> TimeInterval {
        if !s.evidence.isEmpty { return Self.corroboratedWindow }
        if let changed = inputChangedAt, let lost = s.absentSince,
           abs(lost.timeIntervalSince(changed)) <= Self.deviceChangeDemote { return Self.ambiguousWindow }
        if nearEventEnd(s) { return Self.nativeReleaseWindow }
        if let call = s.call, case .meetingApp = MeetingDetection.kind(bundleID: call.bundleID) { return Self.nativeReleaseWindow }
        return Self.ambiguousWindow
    }

    private func spokeWithin(_ seconds: TimeInterval, of now: Date) -> Bool {
        lastSpeechAt.map { now.timeIntervalSince($0) < seconds } ?? false
    }

    private mutating func advance(_ now: Date) -> [Action] {
        latches.removeAll {
            now.timeIntervalSince($0.lastSeenAt) >= Self.latchClearAfterFree || now.timeIntervalSince($0.createdAt) >= Self.latchMax
        }
        if session != nil { return advanceSession(now) }
        return advanceIdle(now)
    }

    private mutating func advanceSession(_ now: Date) -> [Action] {
        guard var s = session, let call = s.call, let lostAt = s.absentSince, autoStopEnabled, !s.keptGoing else { return [] }
        var actions: [Action] = []
        if s.armedAt == nil {
            let polls = spokeWithin(Self.warmSpeech, of: now) ? Self.confirmPollsWhenWarm : Self.confirmPolls
            let minAge = nearEventEnd(s) ? 0 : Self.minSessionAge
            let guardUntil = max(s.startedAt.addingTimeInterval(minAge), holdoffUntil)
            if now.timeIntervalSince(lostAt) >= Self.absenceConfirm, s.absentPolls >= polls, now >= guardUntil {
                s.armedAt = now
            }
        }
        if let armed = s.armedAt, s.stopAt == nil, now.timeIntervalSince(armed) >= stopWindow(s),
           !(spokeWithin(Self.speechVeto, of: now) && now.timeIntervalSince(armed) < Self.speechVetoCap) {
            let deadline = now.addingTimeInterval(Self.minStoppingBanner)
            s.stopAt = deadline
            actions.append(.showStopping(deadline: deadline))
        }
        if let stopAt = s.stopAt, now >= stopAt {
            session = nil
            stopped = s
            ended = Ended(call: call, eventKey: s.target.eventKey, at: now, resumes: s.resumes, bySleep: false)
            return actions + [.stop]
        }
        session = s
        return actions
    }

    private mutating func advanceIdle(_ now: Date) -> [Action] {
        var actions: [Action] = []
        if let p = prompt {
            if !promptHeld && now.timeIntervalSince(p.shownAt) >= Self.promptTimeout {
                prompt = nil
                latch(p.call, now)
                actions.append(.dismissPrompt)
            } else if let gone = p.absentSince, now.timeIntervalSince(gone) >= Self.absenceConfirm {
                prompt = nil
                actions.append(.dismissPrompt)
            }
        }
        if let o = offeredResume, now.timeIntervalSince(o.at) > Self.promptTimeout { offeredResume = nil }
        if let e = ended {
            if isOver(e, at: now) {
                ended = nil
            } else if let back = calls.first(where: { isResumable($0, e, at: now) }) {
                ended = nil
                offeredResume = Ended(call: back, eventKey: e.eventKey, at: now, resumes: e.resumes, bySleep: e.bySleep)
                latch(back, now)
                if let p = prompt, p.call.isSameCall(as: back) { prompt = nil; actions.append(.dismissPrompt) }
                return actions + [.offerResume(back)]
            }
        }
        var snoozedCall: DetectedCall?
        if let sn = snoozed {
            if now >= sn.until {
                snoozed = nil
                snoozedCall = calls.first { $0.isSameCall(as: sn.call) }
            }
        }
        guard promptsEnabled, prompt == nil else { return actions }
        let candidate = snoozedCall ?? best(calls.filter { c in
            !latched(c) && !(snoozed.map { Self.sameCall($0.call, vague: c) } ?? false)
        })
        if let c = candidate {
            prompt = Prompt(call: c, shownAt: now)
            actions.append(.prompt(c))
        }
        return actions
    }
}

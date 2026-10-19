import Foundation

// Calendar events for the Scribe: upcoming list, menu-bar title, reminders and matching a recording to an event.
// Everything here is pure (no EventKit) so it can be unit-tested; `CalendarService` in the app maps EKEvents into it.

/// One occurrence of a calendar event.
public struct UpcomingEvent: Identifiable, Hashable, Sendable {
    /// The user's own response to the invitation.
    public enum Response: String, Sendable, CaseIterable {
        case accepted, tentative, declined, none
    }

    /// Event identifier + occurrence start, so every occurrence of a recurring event is distinct.
    public var id: String
    /// Identifier of the event (series) as the calendar server knows it. With `occurrenceStart` it keys a meeting note.
    public var externalID: String
    /// The occurrence's original start (stays put when a single occurrence is moved).
    public var occurrenceStart: Date
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    /// The join link (Zoom, Google Meet, Teams, Webex, FaceTime), if any.
    public var conferenceURL: URL?
    /// Display name of the conference service ("Zoom", "Google Meet", …).
    public var platform: String?
    /// Display names, organizer first, without the current user.
    public var attendees: [String]
    /// Calendar colour as `#RRGGBB`.
    public var colorHex: String?
    public var myStatus: Response
    public var calendarTitle: String?

    public init(id: String, externalID: String, occurrenceStart: Date? = nil, title: String, start: Date, end: Date,
                isAllDay: Bool = false, location: String? = nil, conferenceURL: URL? = nil, platform: String? = nil,
                attendees: [String] = [], colorHex: String? = nil, myStatus: Response = .none, calendarTitle: String? = nil) {
        self.id = id; self.externalID = externalID; self.occurrenceStart = occurrenceStart ?? start; self.title = title
        self.start = start; self.end = end; self.isAllDay = isAllDay; self.location = location
        self.conferenceURL = conferenceURL
        self.platform = platform ?? conferenceURL.flatMap { ConferenceService(url: $0)?.displayName }
        self.attendees = attendees; self.colorHex = colorHex; self.myStatus = myStatus; self.calendarTitle = calendarTitle
    }

    /// `id` for an occurrence: `<eventIdentifier>@<occurrence start, unix seconds>`.
    public static func makeID(eventIdentifier: String, occurrenceStart: Date) -> String {
        "\(eventIdentifier)@\(Int64(occurrenceStart.timeIntervalSince1970.rounded()))"
    }

    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(No title)" : t
    }

    public var conferenceService: ConferenceService? { conferenceURL.flatMap { ConferenceService(url: $0) } }
    public var isDeclined: Bool { myStatus == .declined }
    public func isInProgress(at now: Date) -> Bool { start <= now && now < end }
    public func hasEnded(at now: Date) -> Bool { end <= now }
    /// Overlaps another event (touching end/start does not count).
    public func overlaps(_ other: UpcomingEvent) -> Bool { start < other.end && other.start < end }
}

/// Video-call services whose join links are recognised.
public enum ConferenceService: String, Sendable, CaseIterable {
    case zoom
    case googleMeet = "google_meet"
    case teams
    case webex
    case facetime

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .facetime: "FaceTime"
        }
    }

    /// Classifies by scheme/host only (any page on the service). Redirect wrappers (Outlook Safe Links,
    /// google.com/url) are unwrapped first.
    public init?(url: URL) {
        let url = CalendarText.unwrapRedirect(url)
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "zoommtg", "zoomus": self = .zoom; return
        case "msteams": self = .teams; return
        case "facetime": self = .facetime; return
        case "http", "https": break
        default: return nil
        }
        guard let host = url.host?.lowercased() else { return nil }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("zoom.us") || on("zoomgov.com") { self = .zoom }
        else if host == "meet.google.com" { self = .googleMeet }
        else if on("teams.microsoft.com") || on("teams.live.com") || on("teams.microsoft.us") { self = .teams }
        else if on("webex.com") { self = .webex }
        else if host == "facetime.apple.com" { self = .facetime }
        else { return nil }
    }
}

// MARK: - Text: links, codes, labels

public enum CalendarText {
    /// The join link of an event: the event's URL field first, then its location, then its notes.
    /// Dial-in, help, "meeting options" and unsubscribe links are ignored.
    public static func conferenceURL(location: String?, url: URL?, notes: String?) -> URL? {
        if let url, let u = joinLink(url) { return u }
        if let location, let u = joinLinks(in: location).first { return u }
        if let notes, let u = joinLinks(in: notes).first { return u }
        return nil
    }

    /// All join links in free text (plain, Outlook `text<https://…>`, or HTML-ish), in order, without duplicates.
    public static func joinLinks(in text: String) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        for candidate in candidateURLs(in: text) {
            guard let u = joinLink(candidate), seen.insert(u.absoluteString).inserted else { continue }
            out.append(u)
        }
        return out
    }

    /// The URL itself (unwrapped from Safe Links / google.com/url) if it joins a call, else nil.
    public static func joinLink(_ url: URL) -> URL? {
        let url = unwrapRedirect(url)
        guard let service = ConferenceService(url: url) else { return nil }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let full = fullyDecoded(url.absoluteString).lowercased()
        let scheme = url.scheme?.lowercased() ?? ""
        // Help, dial-in, unsubscribe and settings pages are never join links. Page names count as whole path
        // segments, so a personal room such as zoom.us/my/helpdesk is still a join link.
        let junk = ["unsubscribe", "globalcallin", "tollfree", "dialin", "meetingoptions"]
        let junkPages: Set<String> = ["download", "support", "help", "u", "signin", "profile"]
        if junk.contains(where: { (host + path).contains($0) }) { return nil }
        if path.split(separator: "/").contains(where: { junkPages.contains(String($0)) }) { return nil }
        if host.hasPrefix("support.") || host.hasPrefix("help.") || host.hasPrefix("dialin.") { return nil }
        switch service {
        case .zoom:
            if scheme == "zoommtg" || scheme == "zoomus" { return full.contains("confno=") ? url : nil }
            return firstMatch(#"^/(?:j|s|w|wc/join)/\d{9,13}\b|^/wc/\d{9,13}/(?:join|start)\b|^/my/[^/]+"#, in: path) != nil ? url : nil
        case .googleMeet:
            return firstMatch(#"^/(?:[a-z]{3}-[a-z]{4}-[a-z]{3}|lookup/[a-z0-9_-]+)(?:/|$)"#, in: path) != nil ? url : nil
        case .teams:
            if scheme == "msteams" { return full.contains("meetup-join") ? url : nil }
            return full.contains("/l/meetup-join/") || firstMatch(#"/meet/\d{6,}"#, in: full) != nil ? url : nil
        case .webex:
            if host == "www.webex.com" { return nil }
            let ok = path.hasSuffix("/j.php") || path.hasSuffix("/e.php") || path.contains("/meet/") || path.contains("/join/")
                || path.contains("joinservice") || path.contains("/wbxmjs/") || path.hasPrefix("/m/")
            return ok ? url : nil
        case .facetime:
            return path.hasPrefix("/join") ? url : nil
        }
    }

    /// A service-qualified meeting identity that is the same for the event's join link and the live call URL
    /// (`google_meet:abc-defg-hij`, `zoom:85012345678`, `teams:19:meeting_…@thread.v2`, `teams:meet/123…`).
    public static func meetingCode(_ url: URL) -> String? {
        let url = unwrapRedirect(url)
        guard let service = ConferenceService(url: url) else { return nil }
        let path = url.path
        let decoded = fullyDecoded(url.absoluteString)
        func code(_ s: String) -> String { "\(service.rawValue):\(s)" }
        switch service {
        case .googleMeet:
            if let m = firstMatch(#"^/([a-z]{3}-[a-z]{4}-[a-z]{3})(?:/|$)"#, in: path.lowercased(), group: 1) { return code(m) }
            if let m = firstMatch(#"^/lookup/([a-z0-9_-]+)"#, in: path.lowercased(), group: 1) { return code("lookup/" + m) }
        case .zoom:
            let p = #"/(?:j|s|w|wc/join)/(\d{9,13})\b|/wc/(\d{9,13})/(?:join|start)\b|[?&]confno=(\d{9,13})\b"#
            if let m = firstMatch(p, in: decoded, group: nil) { return code(m) }
            if let m = firstMatch(#"^/my/([^/?#]+)"#, in: path.lowercased(), group: 1) { return code("my/" + m) }
        case .teams:
            if let m = firstMatch(#"meetup-join/(19:[^/?#&\s]+)"#, in: decoded, group: 1) { return code(m) }
            if let m = firstMatch(#"/meet/(\d{6,})"#, in: decoded, group: 1) { return code("meet/" + m) }
        case .webex:
            if let mtid = queryValue("MTID", in: url) { return code("mtid/" + mtid.lowercased()) }
            let site = url.host?.lowercased().components(separatedBy: ".").first ?? ""
            if let m = firstMatch(#"/meet/([^/?#]+)"#, in: path.lowercased(), group: 1) { return code("\(site)/\(m)") }
        case .facetime:
            if let m = firstMatch(#"[#&?]p=([^&#]+)"#, in: decoded, group: 1) { return code(m) }
        }
        return nil
    }

    // MARK: Labels

    /// Right-hand label of an event row: "in 5 min", "in 1 h 20 min", "Starting now", "20 min left",
    /// "Ending soon", "12 min ago".
    public static func relativeLabel(_ event: UpcomingEvent, now: Date) -> String {
        if event.isAllDay { return "All day" }
        let untilStart = seconds(from: now, to: event.start)
        let untilEnd = seconds(from: now, to: event.end)
        if untilStart >= 60 { return "in " + spelled(minutes: ceilMinutes(untilStart)) }
        if untilStart > 0 || untilStart > -60 && untilEnd > 0 { return "Starting now" }
        if untilEnd > 0 { return untilEnd <= 5 * 60 ? "Ending soon" : spelled(minutes: ceilMinutes(untilEnd)) + " left" }
        let ago = max(1, -untilEnd / 60)
        return ago < 60 ? "\(ago) min ago" : "\(ago / 60) h ago"
    }

    /// An upcoming meeting this close takes the menu bar over from the one in progress.
    public static let menuBarSoon: TimeInterval = 10 * 60
    /// With nothing in progress, a meeting further away than this shows as "Free until …".
    public static let menuBarFreeUntil: TimeInterval = 60 * 60

    /// Menu-bar title next to the icon (setting "Show your next meeting in the menu bar"). The first rule that applies:
    /// 1. a meeting starts within 10 min: "Standup • in 5 min" ("• now" in its last minute);
    /// 2. nothing is in progress: the next meeting if it starts within the hour, else "Free until 3:00 PM"
    ///    ("Free until Fri 9:00 AM" when it is more than a day away), or nil when nothing is left;
    /// 3. a meeting is in progress and not yet half over: "Standup • 23m left";
    /// 4. otherwise, once everything in progress has ended: the next meeting if it starts within a minute of that,
    ///    "Free from 3:00 – 4:00 PM" when it starts later that day, else "Free after 5:00 PM".
    /// Meetings that start together read "2 meetings". All-day, declined, zero-length and ended events are ignored.
    /// At most `maxLength` characters; a long title is shortened with "…".
    public static func menuBarTitle(events: [UpcomingEvent], now: Date, maxLength: Int = 30,
                                    calendar: Calendar = .current, locale: Locale = .current) -> String? {
        let maxLength = max(1, maxLength)
        let live = events.filter { !$0.isAllDay && !$0.isDeclined && $0.end > $0.start && $0.end > now }.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return a.id < b.id
        }
        let running = live.filter { $0.start <= now }
        let next = live.first { $0.start > now }

        func label(_ e: UpcomingEvent) -> String {
            let together = live.filter { $0.start == e.start }.count
            let title = together > 1 ? "\(together) meetings" : e.displayTitle
            let suffix: String
            if e.start <= now {
                let minuteStart = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
                let minutes = max(1, Int(((e.end.timeIntervalSince1970 - minuteStart) / 60).rounded(.down)))
                suffix = barDuration(minutes: minutes, unit: "m") + " left"
            } else {
                // Whole minutes, rounded down (the epsilon only absorbs Date arithmetic noise). The title refreshes
                // just after each minute boundary, so 14:59:00.1 is "now" for 15:00, never "in 1 min" (R5-5).
                let minutes = Int((e.start.timeIntervalSince(now) / 60 + 1e-6).rounded(.down))
                suffix = minutes < 1 ? "now" : "in " + barDuration(minutes: minutes, unit: " min")
            }
            return truncated(title, suffix: " • " + suffix, maxLength: maxLength)
        }
        func fitted(_ s: String) -> String { s.count <= maxLength ? s : String(s.prefix(maxLength - 1)) + "…" }
        func clock(_ d: Date, weekday: Bool) -> String {
            (weekday ? self.weekday(d, calendar: calendar, locale: locale) + " " : "") + time(d, calendar: calendar, locale: locale)
        }

        if let next, next.start.timeIntervalSince(now) <= menuBarSoon { return label(next) }
        guard let current = running.last else {
            guard let next else { return nil }
            let away = next.start.timeIntervalSince(now)
            return away > menuBarFreeUntil ? fitted("Free until " + clock(next.start, weekday: away > 86_400)) : label(next)
        }
        if now < current.start.addingTimeInterval(current.end.timeIntervalSince(current.start) / 2) { return label(current) }
        let free = running.map(\.end).max() ?? current.end
        if let next, next.start.timeIntervalSince(free) < 60 { return label(next) }
        if let next, calendar.isDate(next.start, inSameDayAs: free) {
            return fitted("Free from " + interval(free, next.start, calendar: calendar, locale: locale))
        }
        return fitted("Free after " + clock(free, weekday: !calendar.isDate(free, inSameDayAs: now)))
    }

    /// "10:00 – 10:30 AM" (localized short times).
    public static func timeRange(_ event: UpcomingEvent, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if event.isAllDay { return "All day" }
        return interval(event.start, event.end, calendar: calendar, locale: locale)
    }

    /// When a note was taken, for menus: "3:04 PM" today, "Yesterday, 3:04 PM", "Oct 14, 3:04 PM", or with the year
    /// ("Oct 14, 2024, 3:04 PM") before this year.
    public static func noteTime(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let t = time(date, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return t }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday, " + t }
        let f = DateFormatter()
        f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return normalizeSpaces(f.string(from: date)) + ", " + t
    }

    /// Localized short time ("3:00 PM").
    public static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "HH:mm"
        return normalizeSpaces(f.string(from: date))
    }

    /// Localized short weekday ("Fri").
    static func weekday(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date)
    }

    /// "3:00 – 4:00 PM" (localized short times).
    static func interval(_ from: Date, _ to: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateIntervalFormatter()
        f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
        f.dateStyle = .none; f.timeStyle = .short
        return normalizeSpaces(f.string(from: from, to: to))
    }

    /// Display name for a participant: their name, else the address of a `mailto:` URL.
    public static func participantName(name: String?, url: URL?) -> String? {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n.lowercased().hasPrefix("mailto:") ? String(n.dropFirst(7)) : n
        }
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        let addr = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
        let decoded = addr.removingPercentEncoding ?? addr
        return decoded.isEmpty ? nil : decoded
    }

    /// `#RRGGBB` from sRGB components in 0…1.
    public static func hexColor(red: Double, green: Double, blue: Double) -> String {
        func c(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(red), c(green), c(blue))
    }

    /// Whether `event` overlaps another (not declined, not all-day) event in `events` ("Conflict" chip).
    public static func conflicts(_ event: UpcomingEvent, in events: [UpcomingEvent]) -> Bool {
        guard !event.isAllDay, !event.isDeclined else { return false }
        return events.contains { $0.id != event.id && !$0.isAllDay && !$0.isDeclined && $0.overlaps(event) }
    }

    // MARK: Internals

    /// Unwraps Outlook Safe Links and google.com/url redirects (recursively, a few levels).
    static func unwrapRedirect(_ url: URL) -> URL {
        var u = url
        for _ in 0..<3 {
            guard let host = u.host?.lowercased() else { break }
            let inner: String?
            if host.hasSuffix("safelinks.protection.outlook.com") {
                inner = queryValue("url", in: u)
            } else if (host == "www.google.com" || host == "google.com") && u.path == "/url" {
                inner = queryValue("q", in: u) ?? queryValue("url", in: u)
            } else {
                inner = nil
            }
            guard let inner, let next = URL(string: inner) else { break }
            u = next
        }
        return u
    }

    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// URL-looking substrings, in order of appearance: anything with a scheme, plus bare conference hosts.
    static func candidateURLs(in text: String) -> [URL] {
        let t = decodeEntities(text)
        let ns = t as NSString
        let stop = #"[^\s<>"'`\[\]{}|\\^]+"#
        var found: [(Int, String)] = []
        var taken: [NSRange] = []
        let schemed = try! NSRegularExpression(pattern: #"(?i)(?:\b(?:https?|zoommtg|zoomus|facetime)://|\bmsteams:/{1,2})"# + stop)
        for m in schemed.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            found.append((m.range.location, ns.substring(with: m.range))); taken.append(m.range)
        }
        let bare = try! NSRegularExpression(pattern:
            #"(?i)\b(?:[a-z0-9-]+\.)*(?:zoom\.us|zoomgov\.com|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|facetime\.apple\.com)/"# + stop)
        for m in bare.matches(in: t, range: NSRange(location: 0, length: ns.length))
        where !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let before = m.range.location > 0 ? ns.substring(with: NSRange(location: m.range.location - 1, length: 1)) : ""
            if before == "@" || before == "/" || before == "." { continue }
            found.append((m.range.location, "https://" + ns.substring(with: m.range)))
        }
        return found.sorted { $0.0 < $1.0 }.compactMap { URL(string: trimTrailing($0.1)) }
    }

    private static func trimTrailing(_ s: String) -> String {
        var s = Substring(s)
        while let last = s.last, ".,;:!?)*'\"".contains(last) { s = s.dropLast() }
        return String(s)
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for _ in 0..<2 { out = out.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive) }
        let map = ["&quot;": "\"", "&#34;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">",
                   "&nbsp;": " ", "&#61;": "=", "&#x3d;": "=", "&#47;": "/", "&#x2f;": "/"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        return out
    }

    private static func fullyDecoded(_ s: String) -> String {
        var cur = s
        for _ in 0..<3 {
            guard let next = cur.removingPercentEncoding, next != cur else { break }
            cur = next
        }
        return cur
    }

    /// First match of `pattern`; `group` nil returns the first non-empty capture group (or the whole match).
    private static func firstMatch(_ pattern: String, in s: String, group: Int? = 0) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let groups: [Int] = group.map { [$0] } ?? Array(1..<max(1, m.numberOfRanges)) + [0]
        for g in groups where g < m.numberOfRanges {
            if let r = Range(m.range(at: g), in: s), !r.isEmpty { return String(s[r]) }
        }
        return nil
    }

    /// Whole seconds from `a` to `b` (rounded, so Date arithmetic noise never flips a boundary).
    static func seconds(from a: Date, to b: Date) -> Int { Int(b.timeIntervalSince(a).rounded()) }
    private static func ceilMinutes(_ seconds: Int) -> Int { max(1, (seconds + 59) / 60) }

    /// "5 min", "1 h", "1 h 20 min".
    private static func spelled(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Menu-bar durations: "23m" / "23 min" (by `unit`), "1 hr", "1h 5m".
    private static func barDuration(minutes: Int, unit: String) -> String {
        if minutes < 60 { return "\(minutes)\(unit)" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr" : "\(h)h \(m)m"
    }

    static func truncated(_ title: String, suffix: String, maxLength: Int) -> String {
        let room = maxLength - suffix.count
        guard title.count > room else { return title + suffix }
        guard room > 1 else { return String((title + suffix).prefix(maxLength - 1)) + "…" }
        let cut = title.prefix(room - 1).trimmingCharacters(in: .whitespaces)
        return cut + "…" + suffix
    }

    /// ICU uses narrow/no-break spaces in times ("3:00\u{202F}PM"); plain spaces read the same and test cleanly.
    private static func normalizeSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
    }
}

// MARK: - Schedule helpers

/// Events grouped under one heading of the upcoming list.
public struct CalendarDay: Hashable, Sendable {
    /// Start of the day.
    public var day: Date
    /// "Today", "Tomorrow", "Yesterday" or "Friday, Oct 17".
    public var title: String
    public var events: [UpcomingEvent]
}

public enum CalendarSchedule {
    /// How long after its start a missed reminder is still shown (e.g. after wake or launch).
    public static let reminderLateGrace: TimeInterval = 5 * 60

    /// Events worth showing: drops all-day and declined ones unless asked; sorted by start, then end.
    public static func visible(_ events: [UpcomingEvent], includeAllDay: Bool = false,
                               includeDeclined: Bool = false) -> [UpcomingEvent] {
        events.filter { (includeAllDay || !$0.isAllDay) && (includeDeclined || !$0.isDeclined) }.sorted(by: order)
    }

    static func order(_ a: UpcomingEvent, _ b: UpcomingEvent) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        return a.id < b.id
    }

    /// The event to show in the menu bar / tray: an event starting within `soon` beats one in progress
    /// (you need to join it); otherwise the most recently started event in progress; otherwise the next to start.
    /// All-day and declined events are ignored.
    public static func next(in events: [UpcomingEvent], now: Date, soon: TimeInterval = 5 * 60) -> UpcomingEvent? {
        let live = events.filter { !$0.isAllDay && !$0.isDeclined && $0.end > now }
        let upcoming = live.filter { $0.start > now }.sorted(by: order)
        let running = live.filter { $0.start <= now }.sorted { $0.start != $1.start ? $0.start > $1.start : $0.end < $1.end }
        if let u = upcoming.first, u.start.timeIntervalSince(now) <= soon { return u }
        return running.first ?? upcoming.first
    }

    /// The meetings in the menu-bar menu: everything in progress ("Now"), then the rest of today ("Today"), then
    /// tomorrow ("Tomorrow"), at most `limit` in all. All-day, declined and ended events are left out; empty headings too.
    public static func menuSections(_ events: [UpcomingEvent], now: Date, limit: Int = 3,
                                    calendar: Calendar = .current) -> [(title: String, events: [UpcomingEvent])] {
        let live = events.filter { !$0.isAllDay && !$0.isDeclined && $0.end > now }.sorted(by: order)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let groups: [(String, [UpcomingEvent])] = [
            ("Now", live.filter { $0.start <= now }),
            ("Today", live.filter { $0.start > now && calendar.isDate($0.start, inSameDayAs: now) }),
            ("Tomorrow", live.filter { calendar.isDate($0.start, inSameDayAs: tomorrow) }),
        ]
        var room = limit
        var out: [(title: String, events: [UpcomingEvent])] = []
        for (title, items) in groups where room > 0 && !items.isEmpty {
            out.append((title, Array(items.prefix(room))))
            room -= min(room, items.count)
        }
        return out
    }

    /// "Join Meeting" in the menu-bar menu: the first meeting in progress that has a call link.
    public static func joinableNow(_ events: [UpcomingEvent], now: Date) -> UpcomingEvent? {
        events.filter { !$0.isAllDay && !$0.isDeclined && $0.isInProgress(at: now) && $0.conferenceURL != nil }
            .sorted(by: order).first
    }

    /// Groups by day under "Today" / "Tomorrow" / weekday headings. An event still running from an earlier day
    /// shows under Today.
    public static func days(_ events: [UpcomingEvent], now: Date, calendar: Calendar = .current,
                            locale: Locale = .current) -> [CalendarDay] {
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: [UpcomingEvent]] = [:]
        for e in events {
            var key = calendar.startOfDay(for: e.start)
            if key < today && e.end > today { key = today }
            buckets[key, default: []].append(e)
        }
        let f = DateFormatter()
        f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "EEEEMMMd", options: 0, locale: locale)
        return buckets.keys.sorted().map { day in
            let title: String
            if calendar.isDate(day, inSameDayAs: now) { title = "Today" }
            else if let t = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(day, inSameDayAs: t) { title = "Tomorrow" }
            else if let y = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: y) { title = "Yesterday" }
            else { title = f.string(from: day) }
            return CalendarDay(day: day, title: title, events: buckets[day]!.sorted(by: order))
        }
    }

    /// Sets of overlapping events ("conflict groups"), each in start order, only groups of two or more.
    /// All-day and declined events never conflict.
    public static func conflictGroups(_ events: [UpcomingEvent]) -> [[UpcomingEvent]] {
        let timed = events.filter { !$0.isAllDay && !$0.isDeclined && $0.end > $0.start }.sorted(by: order)
        var groups: [[UpcomingEvent]] = [], current: [UpcomingEvent] = [], currentEnd = Date.distantPast
        for e in timed {
            if !current.isEmpty && e.start < currentEnd {
                current.append(e); currentEnd = max(currentEnd, e.end)
            } else {
                if current.count > 1 { groups.append(current) }
                current = [e]; currentEnd = e.end
            }
        }
        if current.count > 1 { groups.append(current) }
        return groups
    }

    /// IDs of events that overlap at least one other event.
    public static func conflictingIDs(_ events: [UpcomingEvent]) -> Set<String> {
        // Every member of a sweep group overlaps at least one other member.
        Set(conflictGroups(events).flatMap { $0.map(\.id) })
    }

    /// Events whose reminder is due now: `start - lead <= now`, started at most `lateGrace` ago, not declined,
    /// not all-day and not already notified.
    public static func dueReminders(in events: [UpcomingEvent], now: Date, lead: TimeInterval,
                                    notified: Set<String>, lateGrace: TimeInterval = reminderLateGrace) -> [UpcomingEvent] {
        events.filter {
            !$0.isAllDay && !$0.isDeclined && !notified.contains($0.id)
                && $0.start.addingTimeInterval(-lead) <= now && now < $0.start.addingTimeInterval(lateGrace) && now < $0.end
        }.sorted(by: order)
    }

    /// When the next not-yet-notified reminder becomes due (after `now`), or nil.
    public static func nextReminderDate(in events: [UpcomingEvent], now: Date, lead: TimeInterval,
                                        notified: Set<String>) -> Date? {
        events.filter { !$0.isAllDay && !$0.isDeclined && !notified.contains($0.id) }
            .map { $0.start.addingTimeInterval(-lead) }
            .filter { $0 > now }
            .min()
    }
}

// MARK: - Matching a recording to an event

public enum CalendarMatcher {
    public enum MatchType: String, Sendable {
        /// The user clicked Join + Start for this event shortly before.
        case userIntent
        /// The call URL's meeting code equals the event's conference link code.
        case meetingCode
        /// Native Zoom started within the event's time window.
        case timeWindow
    }

    public struct Match: Hashable, Sendable {
        public var event: UpcomingEvent
        public var type: MatchType
    }

    /// How long a Join + Start click stays valid.
    public static let userIntentTTL: TimeInterval = 120
    /// Slack around an event for the native-Zoom time window.
    public static let timeWindowSlack: TimeInterval = 60
    public static let zoomBundleIDs: Set<String> = ["us.zoom.xos"]

    public static func match(recordingStart: Date, callURL: URL?, bundleID: String?, userIntentEventID: String?,
                             userIntentAt: Date? = nil, events: [UpcomingEvent]) -> UpcomingEvent? {
        matchDetailed(recordingStart: recordingStart, callURL: callURL, bundleID: bundleID,
                      userIntentEventID: userIntentEventID, userIntentAt: userIntentAt, events: events)?.event
    }

    /// 1. user intent (an event the user clicked Join + Start on, within `userIntentTTL` when `userIntentAt` is given);
    /// 2. meeting code of `callURL` equal to the event's (no time bound; prefers the event in progress, then the
    ///    closest start or end); 3. native Zoom only: the single (not declined) event with a Zoom link in
    ///    `start-60s … end+60s` (if several, the single one in progress; otherwise none).
    public static func matchDetailed(recordingStart t: Date, callURL: URL?, bundleID: String?, userIntentEventID: String?,
                                     userIntentAt: Date? = nil, events: [UpcomingEvent]) -> Match? {
        if let wanted = userIntentEventID, userIntentAt.map({ abs(t.timeIntervalSince($0)) <= userIntentTTL }) ?? true,
           let e = events.first(where: { $0.id == wanted })
            // A series ID: the occurrence nearest the recording.
            ?? events.filter({ $0.externalID == wanted }).min(by: { distance($0, t) < distance($1, t) }) {
            return Match(event: e, type: .userIntent)
        }
        if let callURL, let code = CalendarText.meetingCode(callURL) {
            let hits = events.filter { $0.conferenceURL.flatMap(CalendarText.meetingCode) == code }
            if let e = hits.filter({ $0.isInProgress(at: t) }).min(by: { distance($0, t) < distance($1, t) })
                ?? hits.min(by: { distance($0, t) < distance($1, t) }) {
                return Match(event: e, type: .meetingCode)
            }
        }
        if let b = bundleID?.lowercased(), zoomBundleIDs.contains(b) {
            let window = events.filter {
                !$0.isAllDay && !$0.isDeclined && $0.conferenceService == .zoom
                    && $0.start.addingTimeInterval(-timeWindowSlack) <= t && t <= $0.end.addingTimeInterval(timeWindowSlack)
            }
            if window.count == 1 { return Match(event: window[0], type: .timeWindow) }
            let running = window.filter { $0.isInProgress(at: t) }
            if running.count == 1 { return Match(event: running[0], type: .timeWindow) }
        }
        return nil
    }

    private static func distance(_ e: UpcomingEvent, _ t: Date) -> TimeInterval {
        min(abs(e.start.timeIntervalSince(t)), abs(e.end.timeIntervalSince(t)))
    }
}

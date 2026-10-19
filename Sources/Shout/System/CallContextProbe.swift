import AppKit
import ApplicationServices
import ShoutKit

/// Reads what an app shows of a call through Accessibility: its window titles and identifiers and, for
/// browsers, the front-tab URL of each window (`AXWebArea` → `AXURL`) and the tab-strip titles (`AXTabGroup`).
///
/// Reads run on a background queue with a 0.25 s per-message timeout and an overall time box, so a hung
/// app never blocks the main thread. Results are cached per pid and kind of read for `cacheTTL`; concurrent
/// requests for the same pid and kind share one read. Returns nil without Accessibility permission or when the
/// app did not answer.
@MainActor
final class CallContextProbe {
    nonisolated static let cacheTTL: TimeInterval = 5
    /// Upper bound for one app's read (windows are skipped once it is spent).
    nonisolated static let timeBox: TimeInterval = 1.5

    /// One queue for every probe: `Reader`'s state is only touched on it.
    private nonisolated static let queue = DispatchQueue(label: "shout.call-context", qos: .userInitiated)
    /// A browser read (URLs, tabs) is not the same as a plain one, so neither stands in for the other.
    private struct Key: Hashable { let pid: pid_t; let browser: Bool }
    private var cache: [Key: (at: Date, context: MeetingContext?)] = [:]
    private var waiting: [Key: [CheckedContinuation<MeetingContext?, Never>]] = [:]

    /// Context of the app `pid`. `browser` adds URLs and tab titles. `maxAge` 0 forces a fresh read.
    func context(pid: pid_t, browser: Bool, maxAge: TimeInterval = CallContextProbe.cacheTTL) async -> MeetingContext? {
        guard AXIsProcessTrusted() else { return nil }
        let key = Key(pid: pid, browser: browser)
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < maxAge { return hit.context }
        return await withCheckedContinuation { continuation in
            if waiting[key] != nil { waiting[key]?.append(continuation); return }
            waiting[key] = [continuation]
            // Strong capture: the waiters are resumed even if the probe is released meanwhile.
            Self.queue.async { [self] in
                let result = Reader.read(pid: pid, browser: browser, deadline: Date().addingTimeInterval(Self.timeBox))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.finish(key, result: result) }
                }
            }
        }
    }

    func clearCache() { cache = [:] }

    private func finish(_ key: Key, result: MeetingContext?) {
        cache[key] = (Date(), result)
        if cache.count > 32 { cache = cache.filter { Date().timeIntervalSince($0.value.at) < Self.cacheTTL } }
        let list = waiting.removeValue(forKey: key) ?? []
        for c in list { c.resume(returning: result) }
    }
}

/// The Accessibility reads themselves; only ever used on the probe's serial queue.
private enum Reader {
    static let messageTimeout: Float = 0.25
    static let maxWindows = 8
    /// Elements visited per window while looking for the web area and tab strip (Wispr Flow's helper
    /// searches up to 3000 elements, 50 levels deep, for 0.75 s).
    static let nodeBudget = 3000
    static let maxDepth = 50
    static let maxTabs = 60
    /// Apps whose tree was asked for, by launch time: a pid reused by a newly launched app is asked again.
    nonisolated(unsafe) static var manualAXEnabled: [pid_t: Date] = [:]

    static func read(pid: pid_t, browser: Bool, deadline: Date) -> MeetingContext? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messageTimeout)
        // Chromium and Electron build their accessibility tree only when asked.
        if browser {
            let launched = NSRunningApplication(processIdentifier: pid)?.launchDate ?? .distantPast
            if manualAXEnabled[pid] != launched {
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                manualAXEnabled[pid] = launched
                // Call detection keeps relying on it: the speaker poller must not turn it off after a meeting.
                AXWakeRegistry.shared.keepAwake(pid)
            }
        }
        guard let windows: [AXUIElement] = value(app, kAXWindowsAttribute) else { return nil }
        // Focused window first, then main, then the rest.
        var ordered: [AXUIElement] = []
        for w in [value(app, kAXFocusedWindowAttribute) as AXUIElement?, value(app, kAXMainWindowAttribute) as AXUIElement?]
            .compactMap({ $0 }) + windows where !ordered.contains(where: { CFEqual($0, w) }) {
            ordered.append(w)
        }
        var ctx = MeetingContext()
        for window in ordered.prefix(maxWindows) {
            guard Date() < deadline else { break }
            AXUIElementSetMessagingTimeout(window, messageTimeout)
            let attrs = values(window, [kAXTitleAttribute, kAXIdentifierAttribute])
            if let title = attrs[0] as? String, !title.isEmpty { ctx.windowTitles.append(title) }
            if let identifier = attrs[1] as? String, !identifier.isEmpty { ctx.windowIdentifiers.append(identifier) }
            if browser { scan(window, into: &ctx, deadline: deadline) }
        }
        return ctx
    }

    /// Breadth-first walk of a browser window: the first `AXWebArea`'s URL, and the titles of tabs in
    /// any `AXTabGroup`. Web content itself is never entered.
    private static func scan(_ window: AXUIElement, into ctx: inout MeetingContext, deadline: Date) {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        var foundURL = false
        while index < queue.count, index < nodeBudget, Date() < deadline {
            let (element, depth) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(element, messageTimeout)
            let attrs = values(element, [kAXRoleAttribute, kAXChildrenAttribute])
            let role = attrs[0] as? String
            if role == "AXWebArea" {
                if !foundURL, let url = url(element) { ctx.urls.append(url); foundURL = true }
                continue
            }
            var children = (attrs[1] as? [AXUIElement]) ?? []
            if role == (kAXTabGroupRole as String) {
                // Tabs are radio buttons; other children (Safari keeps the page here) are walked as usual.
                var rest: [AXUIElement] = []
                for child in children.prefix(maxTabs * 2) {
                    AXUIElementSetMessagingTimeout(child, messageTimeout)
                    let t = values(child, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute])
                    guard (t[0] as? String) == (kAXRadioButtonRole as String) else { rest.append(child); continue }
                    let title = (t[1] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (t[2] as? String) ?? ""
                    if !title.isEmpty, ctx.tabTitles.count < maxTabs { ctx.tabTitles.append(title) }
                }
                children = rest
            }
            // Elements past the budget are never visited, so they are not queued either.
            if depth < maxDepth { queue += children.prefix(max(0, nodeBudget - queue.count)).map { ($0, depth + 1) } }
        }
    }

    private static func url(_ webArea: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(webArea, kAXURLAttribute as CFString, &raw) == .success, let raw else { return nil }
        let s = (raw as? URL)?.absoluteString ?? (raw as? String)
        guard let s, s.hasPrefix("http") else { return nil }
        return s
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return (raw as! T)
        }
        return raw as? T
    }

    /// Several attributes in one round trip; missing ones come back as nil.
    private static func values(_ element: AXUIElement, _ attributes: [String]) -> [Any?] {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(), &raw) == .success,
              let array = raw as? [Any], array.count == attributes.count else {
            return Array(repeating: nil, count: attributes.count)
        }
        // Errors come back as AXValue(kAXValueAXErrorType); `as?` casts below simply fail for them.
        return array.map { $0 is NSNull ? nil : $0 }
    }
}

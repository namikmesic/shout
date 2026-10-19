import AppKit
import ApplicationServices
import ShoutKit

/// Reads the focused text field and app through the Accessibility API.
@MainActor
enum ContextReader {
    /// Live handle to the focused element, used for edit tracking after a paste.
    struct FocusHandle {
        let element: AXUIElement
        let pid: pid_t
        let fullValue: String?
        let selection: NSRange?
        /// The window the field is in, raised again before pasting.
        var window: AXUIElement? = nil
        /// Where the caret or selection was (read even when no text is).
        var caret: NSRange? = nil
    }

    /// Apps already asked for `AXManualAccessibility`, by pid and launch date (macOS reuses pids).
    private static var enabledManualAX: Set<String> = []

    /// The app's accessibility element. Chromium/Electron apps only build their accessibility tree when asked, so
    /// they're asked (once per launch).
    static func applicationElement(_ app: NSRunningApplication) -> AXUIElement {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let axKey = "\(pid)@\(app.launchDate?.timeIntervalSinceReferenceDate ?? 0)"
        if !enabledManualAX.contains(axKey) {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledManualAX.insert(axKey)
            // Dictation relies on the tree too: the speaker poller must not turn it back off after a call.
            AXWakeRegistry.shared.keepAwake(pid)
        }
        return appElement
    }

    static func capture(includeText: Bool) -> (DictationContext, FocusHandle?) {
        var ctx = DictationContext()
        guard let app = NSWorkspace.shared.frontmostApplication else { return (ctx, nil) }
        ctx.appName = app.localizedName
        ctx.bundleID = app.bundleIdentifier
        let pid = app.processIdentifier
        guard AXIsProcessTrusted() else { return (ctx, nil) }

        let appElement = applicationElement(app)

        let window: AXUIElement? = attribute(appElement, kAXFocusedWindowAttribute)
        if let window {
            AXUIElementSetMessagingTimeout(window, 0.25)
            ctx.windowTitle = attribute(window, kAXTitleAttribute)
        }

        var focused: AXUIElement? = attribute(appElement, kAXFocusedUIElementAttribute)
        if focused == nil {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.25)
            focused = attribute(system, kAXFocusedUIElementAttribute)
        }
        guard let element = focused else { return (ctx, nil) }
        AXUIElementSetMessagingTimeout(element, 0.25)

        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        ctx.isSecure = subrole == (kAXSecureTextFieldSubrole as String)
        ctx.url = findURL(from: element)

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
                                      "AXSearchField", kAXStaticTextRole as String, "AXWebArea"]
        let hasRange = (attributeValue(element, kAXSelectedTextRangeAttribute) != nil)
        ctx.isEditable = settable.boolValue || (role.map(textRoles.contains) ?? false) || hasRange

        let caret = selectedRange(element)
        guard includeText, !ctx.isSecure else {
            return (ctx, FocusHandle(element: element, pid: pid, fullValue: nil, selection: nil, window: window, caret: caret))
        }

        ctx.selectedText = attribute(element, kAXSelectedTextAttribute)
        var fullValue: String?
        var selection: NSRange?
        if let range = selectedRange(element) {
            selection = range
            let count: Int = attribute(element, kAXNumberOfCharactersAttribute) ?? -1
            if count >= 0 && count <= 100_000, let value: String = attribute(element, kAXValueAttribute) {
                fullValue = value
                let ns = value as NSString
                let loc = min(range.location, ns.length)
                let end = min(range.location + range.length, ns.length)
                let beforeStart = max(0, loc - 1500)
                ctx.textBefore = ns.substring(with: NSRange(location: beforeStart, length: loc - beforeStart))
                ctx.textAfter = ns.substring(with: NSRange(location: end, length: min(500, ns.length - end)))
            } else {
                // Large documents: fetch only the text around the cursor.
                let beforeStart = max(0, range.location - 1500)
                ctx.textBefore = string(element, range: NSRange(location: beforeStart, length: range.location - beforeStart))
                ctx.textAfter = string(element, range: NSRange(location: range.location + range.length, length: 500))
            }
        } else if let value: String = attribute(element, kAXValueAttribute), value.count < 100_000 {
            // No caret information: assume the cursor is at the end.
            fullValue = value
            ctx.textBefore = String(value.suffix(1500))
            ctx.textAfter = ""
        }
        // Placeholder text is not real content.
        if let placeholder: String = attribute(element, kAXPlaceholderValueAttribute), placeholder == ctx.textBefore {
            ctx.textBefore = ""
        }
        return (ctx, FocusHandle(element: element, pid: pid, fullValue: fullValue, selection: selection, window: window, caret: caret))
    }

    // MARK: Returning to the field

    enum ReturnResult: Equatable {
        /// The field has the focus again (or never lost it), with its caret or selection.
        case field
        /// The app and its window are back, but the field itself couldn't be confirmed (some apps don't let
        /// Shout focus a field): the text goes wherever that window's cursor is.
        case window
        /// Pasting would put the text somewhere else: the app quit, the window closed, or the selection to
        /// replace changed. The reason reads after "Couldn't get back to <app>: ".
        case lost(String)
    }

    /// Brings back the app, window and field a dictation started in, and the caret there, wherever the user went
    /// meanwhile (another app, another screen). `selection`: text the result replaces (Command and Prompt mode); it
    /// must still be selected there, or nothing is replaced.
    @MainActor
    static func returnTo(_ handle: FocusHandle?, app: NSRunningApplication?, selection: String?) async -> ReturnResult {
        guard let app else { return .window }
        if app.isTerminated { return .lost("it quit") }
        let wasFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        guard let handle, AXIsProcessTrusted() else {
            // The paste goes to the front app: never one the user didn't start in.
            return await bringToFront(app) ? .window : .lost("it couldn't be brought to the front")
        }
        if let window = handle.window, !isAlive(window) { return .lost("its window was closed") }
        let focusedNow = focusedElement(pid: handle.pid).map { CFEqual($0, handle.element) } ?? false
        if wasFront && focusedNow && selection == nil { return .field }

        if !wasFront, !(await bringToFront(app)) { return .lost("it couldn't be brought to the front") }
        if let window = handle.window {
            if (attribute(window, kAXMinimizedAttribute) as Bool?) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        // Some apps rebuild their fields (Electron): the window is back, the text goes to its cursor.
        guard isAlive(handle.element) else { return selection == nil ? .window : .lost("the selected text is gone") }
        if !focusedNow { AXUIElementSetAttributeValue(handle.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        if !focusedNow || selection != nil, let caret = handle.caret { setSelectedRange(handle.element, caret) }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let focused = focusedElement(pid: handle.pid).map { CFEqual($0, handle.element) } ?? false
        if let selection, let current: String = attribute(handle.element, kAXSelectedTextAttribute) {
            // Replacing: only the same text. Apps that don't report their selection are trusted, as before.
            guard current == selection else { return .lost("the selected text changed") }
        }
        return focused ? .field : .window
    }

    /// Makes `app` the front app. A plain `activate()` from an app that isn't in front itself (Shout, while the
    /// user works elsewhere) is ignored since macOS 14, so Accessibility's AXFrontmost is set too. Waits up to about
    /// half a second for it to take, and says whether it did.
    @MainActor
    static func bringToFront(_ app: NSRunningApplication) async -> Bool {
        func isFront() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        if isFront() { return true }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        for _ in 0..<3 where !app.isTerminated {
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            app.activate()
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                if isFront() { return true }
            }
        }
        return isFront()
    }

    /// False once the app says the element is gone (a closed window, a removed field).
    private static func isAlive(_ el: AXUIElement) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) != .invalidUIElement
    }

    private static func setSelectedRange(_ el: AXUIElement, _ range: NSRange) {
        var r = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &r) else { return }
        AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, value)
    }

    /// Current value of an element (for edit tracking).
    static func value(of element: AXUIElement) -> String? { attribute(element, kAXValueAttribute) }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        return attribute(appElement, kAXFocusedUIElementAttribute)
    }

    /// Selected text via a simulated ⌘C, for apps that do not expose AXSelectedText.
    static func selectedTextViaCopy() async -> String? {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved = (pb.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        let c = CGKeyCode(TextInserter.keyCodeForCharacter("c") ?? 8)
        TextInserter.pressKey(c, flags: .maskCommand)
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)
        pb.clearContents()
        if !saved.isEmpty {
            pb.writeObjects(saved.map { dict in
                let item = NSPasteboardItem()
                for (t, d) in dict { item.setData(d, forType: t) }
                return item
            })
        }
        return text
    }

    // MARK: AX helpers

    private static func attributeValue(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func attribute<T>(_ el: AXUIElement, _ attr: String) -> T? {
        guard let v = attributeValue(el, attr) else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! T)
        }
        if T.self == Int.self, let n = v as? NSNumber { return (n.intValue as! T) }
        return v as? T
    }

    static func selectedRange(_ el: AXUIElement) -> NSRange? {
        guard let v = attributeValue(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        // Apps report sentinels ({-1, 0}) and garbage here; the NSRange arithmetic and substring calls
        // that follow need a non-negative range whose end doesn't overflow.
        guard r.location >= 0, r.length >= 0, !r.location.addingReportingOverflow(r.length).overflow else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    private static func string(_ el: AXUIElement, range: NSRange) -> String? {
        var r = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, axRange, &out) == .success else { return nil }
        return out as? String
    }

    /// Walks up from the focused element to the enclosing web area and reads its URL.
    private static func findURL(from element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let el = current else { break }
            let role: String? = attribute(el, kAXRoleAttribute)
            if role == "AXWebArea" {
                if let url = attributeValue(el, kAXURLAttribute) {
                    let s = (url as? URL)?.absoluteString ?? (url as? String)
                    if let s, s.hasPrefix("http") { return s }
                }
            }
            current = attribute(el, kAXParentAttribute)
        }
        return nil
    }
}

import AppKit
import ApplicationServices

/// "Split the screen when joining": the Notepad takes the right 30 % of the meeting window's screen (at least
/// 500 pt) and the meeting app's window the rest, as in Wispr Flow's helper. Uses Accessibility to move the other
/// app's window, off the main thread: every message waits on that app (up to 0.5 s each).
@MainActor
enum WindowArranger {
    nonisolated static let notepadShare: CGFloat = 0.3
    nonisolated static let notepadMinWidth: CGFloat = 500
    nonisolated static let timeout: Float = 0.5
    private static let queue = DispatchQueue(label: "shout.window-arranger", qos: .userInitiated)

    /// A display's frame and visible frame (Cocoa coordinates).
    private struct Screen: Sendable { let frame: CGRect, visible: CGRect }

    /// Moves the meeting window, then docks the Notepad beside it. Returns false when it can't try (no
    /// Accessibility, Shout's own pid). A meeting window that doesn't move (full screen, refused, no answer)
    /// leaves the Notepad where it is.
    @discardableResult
    static func split(meetingPID pid: pid_t, notepad: NSWindow) -> Bool {
        guard AXIsProcessTrusted(), pid != getpid() else { return false }
        // The first screen is the primary one (menu bar, origin 0,0), which Accessibility's top-left origin is on.
        let screens = NSScreen.screens.map { Screen(frame: $0.frame, visible: $0.visibleFrame) }
        guard !screens.isEmpty else { return false }
        let fallback = (notepad.screen ?? NSScreen.main).map { Screen(frame: $0.frame, visible: $0.visibleFrame) }
        queue.async {
            guard let frame = moveMeetingWindow(pid: pid, screens: screens, fallback: fallback) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if notepad.isVisible { notepad.setFrame(frame, display: true, animate: true) }
                }
            }
        }
        return true
    }

    /// On `queue`: puts the meeting window on the left of the screen it is on and returns the Notepad's frame, or
    /// nil when the window didn't take its new frame.
    nonisolated private static func moveMeetingWindow(pid: pid_t, screens: [Screen], fallback: Screen?) -> NSRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let window = meetingWindow(app), let primary = screens.first?.frame else { return nil }
        AXUIElementSetMessagingTimeout(window, timeout)
        // A full-screen window is in a Space of its own: it can't be moved beside the Notepad.
        if values(window, ["AXFullScreen"])?[0] as? Bool == true { return nil }
        // The screen with the middle of the meeting window, so it isn't moved to another display.
        let current = values(window, [kAXPositionAttribute, kAXSizeAttribute]).flatMap {
            MeetingSpeakerPoller.frame(position: $0[0], size: $0[1])
        }
        let screen = current.flatMap { f in screens.first { $0.frame.contains(CGPoint(x: f.midX, y: primary.maxY - f.midY)) } }
            ?? fallback
        guard let vf = screen?.visible else { return nil }

        let notepadWidth = min(vf.width / 2, max(notepadMinWidth, (vf.width * notepadShare).rounded()))
        // Accessibility uses a top-left origin on the primary display.
        var origin = CGPoint(x: vf.minX, y: primary.maxY - vf.maxY)
        var size = CGSize(width: vf.width - notepadWidth - 1, height: vf.height)
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return nil }
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos) == .success
        let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz) == .success
        // Again: some apps clamp the size to where the window was first.
        let movedAgain = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos) == .success
        guard moved || movedAgain, sized else { return nil }
        return NSRect(x: vf.maxX - notepadWidth, y: vf.minY, width: notepadWidth, height: vf.height)
    }

    /// The focused window, else the main window, else the first standard window that isn't minimised (as Wispr
    /// Flow's helper picks it).
    nonisolated private static func meetingWindow(_ app: AXUIElement) -> AXUIElement? {
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attr as CFString, &value) == .success, let v = value,
               CFGetTypeID(v) == AXUIElementGetTypeID() {
                return (v as! AXUIElement)
            }
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return nil }
        for window in list.prefix(16) {
            // nil: the app stopped answering, so it won't move a window either.
            guard let v = values(window, [kAXSubroleAttribute, kAXMinimizedAttribute]) else { return nil }
            if v[0] as? String == kAXStandardWindowSubrole, v[1] as? Bool != true { return window }
        }
        return nil
    }

    /// Several attributes in one message; nil when the element didn't answer. Missing values come back as nil.
    nonisolated private static func values(_ element: AXUIElement, _ attributes: [String]) -> [Any?]? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(), &raw)
                == .success, let array = raw as? [Any], array.count == attributes.count else { return nil }
        return array.map { $0 is NSNull ? nil : $0 }
    }
}

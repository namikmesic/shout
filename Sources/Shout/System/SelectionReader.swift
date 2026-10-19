import AppKit
import ShoutKit

/// Text selected in the frontmost app: what it says, where it is on screen and, in an editor, which file and lines.
struct ScreenSelection: Equatable {
    var text: String
    /// In global coordinates with the origin at the top left of the main display (as Accessibility and
    /// ScreenCaptureKit use). Nil when the app doesn't say where the text is.
    var bounds: CGRect?
    /// The window's document, when it's a file.
    var file: String?
    var lines: ClosedRange<Int>?

    /// "/path/File.swift:12-18", "/path/File.swift:12", or just the file when the lines aren't known.
    var location: String? {
        guard let file else { return nil }
        guard let lines else { return file }
        return "\(file):\(lines.lowerBound)" + (lines.count > 1 ? "-\(lines.upperBound)" : "")
    }
}

/// Reads the selection for Prompt mode's ⌥ capture, which boxes it in the picture and quotes it in the prompt.
@MainActor
enum SelectionReader {
    /// Files read to find the selection's lines: bigger ones are only named.
    static let maxFileBytes = 5_000_000

    static func current() -> ScreenSelection? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = ContextReader.applicationElement(app)
        var focused: AXUIElement? = ContextReader.attribute(appElement, kAXFocusedUIElementAttribute)
        if focused == nil {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.25)
            focused = ContextReader.attribute(system, kAXFocusedUIElementAttribute)
        }
        guard let element = focused else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        let subrole: String? = ContextReader.attribute(element, kAXSubroleAttribute)
        guard subrole != (kAXSecureTextFieldSubrole as String),
              let text: String = ContextReader.attribute(element, kAXSelectedTextAttribute),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let range = ContextReader.selectedRange(element)
        let window: AXUIElement? = ContextReader.attribute(element, kAXWindowAttribute)
            ?? ContextReader.attribute(appElement, kAXFocusedWindowAttribute)
        var selection = ScreenSelection(text: text, bounds: range.flatMap { bounds(of: $0, in: element) })
        if let window, let document: String = ContextReader.attribute(window, kAXDocumentAttribute),
           let url = URL(string: document), url.isFileURL {
            selection.file = url.path
            selection.lines = lines(of: text, in: url.path, editorLine: range.flatMap { editorLine(element, $0, text) })
        }
        return selection
    }

    /// Where the range is on screen: the app's box for all of it, with its first and last characters' boxes added
    /// (some apps give only the first line for a range over several).
    static func bounds(of range: NSRange, in element: AXUIElement) -> CGRect? {
        func box(_ r: NSRange) -> CGRect? {
            var cf = CFRange(location: r.location, length: r.length)
            guard let value = AXValueCreate(.cfRange, &cf) else { return nil }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             value, &out) == .success,
                  let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(out as! AXValue, .cgRect, &rect), rect.width >= 1, rect.height >= 1,
                  rect.width < 20_000, rect.height < 20_000, rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
            return rect
        }
        guard range.length > 0 else { return nil }
        let parts = [box(range), box(NSRange(location: range.location, length: 1)),
                     box(NSRange(location: range.location + range.length - 1, length: 1))].compactMap { $0 }
        guard var union = parts.first else { return nil }
        for p in parts.dropFirst() { union = union.union(p) }
        return union
    }

    /// The line the selection's first visible character is on, counted in the editor's own text (which may hold the
    /// whole document, or only part of it as some editors do).
    private static func editorLine(_ element: AXUIElement, _ range: NSRange, _ text: String) -> Int? {
        let count: Int = ContextReader.attribute(element, kAXNumberOfCharactersAttribute) ?? -1
        guard count >= 0, count <= maxFileBytes, let value: String = ContextReader.attribute(element, kAXValueAttribute) else { return nil }
        let ns = value as NSString
        let lead = (text.prefix { $0.isWhitespace || $0.isNewline } as Substring).utf16.count
        let start = range.location + lead
        guard start <= ns.length else { return nil }
        return SelectionLines.line(at: start, in: ns)
    }

    /// The selection's lines in the saved file (`SelectionLines`).
    static func lines(of text: String, in path: String, editorLine: Int?) -> ClosedRange<Int>? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= maxFileBytes,
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return SelectionLines.lines(of: text, in: contents, editorLine: editorLine)
    }
}

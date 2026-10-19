import AppKit
import ScreenCaptureKit
import ShoutKit

/// Prompt mode's own screenshot (a tap of ⌥): the window under the mouse, with a ring where the mouse is (or a box
/// around the selected text), and what Accessibility says is there. Needs Screen Recording permission.
@MainActor
enum WindowCapture {
    enum Failure: LocalizedError {
        case noPermission, nothingUnderMouse, failed(String)
        var errorDescription: String? {
            switch self {
            case .noPermission: "⌥ screenshots need Screen Recording permission."
            case .nothingUnderMouse: "There was no window under the mouse to capture."
            case .failed(let why): "The screenshot failed: \(why)"
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures the window under the mouse into `folder` as `name`.png: any app's, Shout's own main window and
    /// Notepad included (the user may be describing a change to Shout). Only floating panels such as the Flow Bar
    /// are left out. Returns its path and a description of what was under the mouse ("under the mouse: button
    /// “Add Word”; window: Dictionary (Shout)"). `at`: a point in global top-left coordinates instead of the mouse.
    /// `highlight`: selected text's box (same coordinates): its window is captured, with the box drawn around it.
    static func captureUnderMouse(into folder: URL, name: String, at given: CGPoint? = nil,
                                  highlight: CGRect? = nil) async throws -> (path: String, detail: String?) {
        // Never asks here: a macOS question in the middle of a dictation gets in the way. Setup, Settings and the
        // Prompts page ask for it.
        guard hasPermission else { throw Failure.noPermission }
        let point = given ?? highlight.map { CGPoint(x: $0.midX, y: $0.midY) } ?? mouse()
        let detail = describe(at: point)

        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch { throw Failure.failed(error.localizedDescription) }
        let me = getpid()
        // The window under the mouse; over the desktop, the whole screen without Shout's floating panels.
        let filter: SCContentFilter
        let frame: CGRect
        var area: CGRect?
        if let id = frontWindow(at: point), let window = content.windows.first(where: { $0.windowID == id }),
           let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) })
            ?? content.displays.first(where: { $0.frame.intersects(window.frame) }) {
            // Only that window, cut from its display by its frame: the picture is then exactly the frame, so screen
            // positions map straight onto it. (A desktop-independent window capture came back shifted inside the image.)
            filter = SCContentFilter(display: display, including: [window])
            frame = window.frame.intersection(display.frame)
            area = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        } else if let display = content.displays.first(where: { $0.frame.contains(point) }) ?? content.displays.first {
            let panels = content.windows.filter { $0.owningApplication?.processID == me && $0.windowLayer != 0 }
            filter = SCContentFilter(display: display, excludingWindows: panels)
            frame = display.frame
        } else {
            throw Failure.nothingUnderMouse
        }

        // Captured at 1 pixel per point (not Retina): readable, and a quarter of the pixels an assistant pays for.
        let scale: CGFloat = 1
        let config = SCStreamConfiguration()
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.showsCursor = false
        if let area { config.sourceRect = area }
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch { throw Failure.failed(error.localizedDescription) }

        let marked: CGImage
        if let highlight {
            let local = CGRect(x: (highlight.minX - frame.minX) * scale, y: (highlight.minY - frame.minY) * scale,
                               width: highlight.width * scale, height: highlight.height * scale)
            marked = box(on: image, around: local, scale: scale) ?? image
        } else {
            marked = ring(on: image, at: CGPoint(x: (point.x - frame.minX) * scale, y: (point.y - frame.minY) * scale),
                          scale: scale) ?? image
        }
        let url = folder.appendingPathComponent("\(name).png")
        // A whole screen is also capped at `PromptImages.maxLongEdge`.
        guard (try? PromptImages.save(marked, to: url)) != nil else { throw Failure.failed("couldn't save the image") }
        return (url.path, detail)
    }

    /// The frontmost normal window (layer 0) at `point`, from the window server's front-to-back list. Floating
    /// panels (the Flow Bar, menus, the Dock) aren't layer 0, so they're never picked.
    static func frontWindow(at point: CGPoint) -> CGWindowID? {
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for info in order {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point),
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            return id
        }
        return nil
    }

    /// The mouse, in global coordinates with the origin at the top left of the main display (Quartz, ScreenCaptureKit).
    static func mouse() -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: mainHeight - m.y)
    }

    /// Just the window part of a description ("window: Notes (Notes)"): for a selection, the text is what matters.
    static func windowOnly(_ detail: String?) -> String? {
        let parts = (detail ?? "").components(separatedBy: "; ").filter { $0.hasPrefix("window: ") || $0.hasPrefix("app: ") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// The image with a box around selected text (`rect` in image pixels, from the top left), kept inside the image.
    private static func box(on image: CGImage, around rect: CGRect, scale: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let line = 3 * scale
        let bounds = CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: line, dy: line)
        let flipped = CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY, width: rect.width, height: rect.height)
        let outline = flipped.insetBy(dx: -5 * scale, dy: -4 * scale).intersection(bounds)
        guard !outline.isNull, outline.width > 0, outline.height > 0 else { return nil }
        let path = CGPath(roundedRect: outline, cornerWidth: 5 * scale, cornerHeight: 5 * scale, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.08).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(line)
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// The image with a ring where the mouse was (`point` in image pixels, from the top left).
    private static func ring(on image: CGImage, at point: CGPoint, scale: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let center = CGPoint(x: point.x, y: CGFloat(h) - point.y)
        let r = 22 * scale
        let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.12).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(3.5 * scale)
        ctx.strokeEllipse(in: rect)
        return ctx.makeImage()
    }

    /// What Accessibility says is at `point`, worded for the prompt: the thing ("row “Settings”", "button “Add”"), where
    /// it is ("in the sidebar", "in the toolbar") and its window ("window: Dictionary (Shout)").
    static func describe(at point: CGPoint) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let element = hit else {
            return nil
        }
        AXUIElementSetMessagingTimeout(element, 0.25)

        // The thing: its kind and label. Text or a cell inside a list row is the row, named by the text in it.
        var kind = text(element, kAXRoleDescriptionAttribute) ?? role(element)?.replacingOccurrences(of: "AX", with: "").lowercased()
        var label = ownLabel(element) ?? childText(element)
        var ancestors: [AXUIElement] = []
        var current = element
        for _ in 0..<8 {
            guard let parent: AXUIElement = ContextReader.attribute(current, kAXParentAttribute) else { break }
            ancestors.append(parent)
            current = parent
        }
        if [kAXStaticTextRole, kAXCellRole, kAXImageRole].contains(role(element) ?? ""),
           let row = ancestors.prefix(3).first(where: { role($0) == kAXRowRole }) {
            kind = "row"
            label = label ?? ownLabel(row) ?? childText(row)
        }

        // Where it is: the first telling container.
        let window: AXUIElement? = ContextReader.attribute(element, kAXWindowAttribute)
        var place: String?
        for a in ancestors {
            switch role(a) ?? "" {
            case kAXToolbarRole: place = "in the toolbar"
            case kAXTabGroupRole: place = "in the tabs"
            case kAXMenuBarRole, kAXMenuRole: place = "in the menu"
            case kAXOutlineRole, kAXListRole, kAXTableRole:
                // A narrow list along the window's left edge is a sidebar.
                if let f = frame(a), let w = window.flatMap(frame), f.minX - w.minX < 40, f.width < w.width * 0.4 { place = "in the sidebar" }
                else { place = "in a list" }
            default: continue
            }
            break
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
        let title = window.flatMap { text($0, kAXTitleAttribute) }
        var thing = kind ?? "item"
        if let label { thing += " “\(label)”" }
        if let place { thing += " \(place)" }
        var parts = [thing]
        if let title { parts.append("window: \(title)\(appName.map { " (\($0))" } ?? "")") }
        else if let appName { parts.append("app: \(appName)") }
        return parts.joined(separator: "; ")
    }

    private static func text(_ el: AXUIElement, _ attr: String) -> String? {
        guard let s: String = ContextReader.attribute(el, attr) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(60))
    }

    private static func role(_ el: AXUIElement) -> String? { ContextReader.attribute(el, kAXRoleAttribute) }

    /// The element's own name: its title, description, or a short value.
    private static func ownLabel(_ el: AXUIElement) -> String? {
        text(el, kAXTitleAttribute) ?? text(el, kAXDescriptionAttribute)
            ?? (role(el) == kAXStaticTextRole ? text(el, kAXValueAttribute) : nil)
    }

    /// The first text inside `el` (a row's or cell's label), looking a few levels down.
    private static func childText(_ el: AXUIElement) -> String? {
        var queue: [(AXUIElement, Int)] = [(el, 0)]
        var seen = 0
        while !queue.isEmpty && seen < 30 {
            let (node, depth) = queue.removeFirst()
            seen += 1
            if node != el, role(node) == kAXStaticTextRole, let t = text(node, kAXValueAttribute) ?? text(node, kAXTitleAttribute) { return t }
            guard depth < 3, let children: [AXUIElement] = ContextReader.attribute(node, kAXChildrenAttribute) else { continue }
            queue += children.prefix(8).map { ($0, depth + 1) }
        }
        return nil
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p: AXValue = ContextReader.attribute(el, kAXPositionAttribute), let s: AXValue = ContextReader.attribute(el, kAXSizeAttribute) else {
            return nil
        }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

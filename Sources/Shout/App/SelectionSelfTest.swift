import AppKit
import ScreenCaptureKit
import ShoutKit

/// Development aid: checks the ⌥ capture of selected text on a real app, inside the signed app so its permissions
/// apply:
///
///     open -n /Applications/Shout.app --env SHOUT_DEMO_DATA=1 --env SHOUT_SELECTION_SELFTEST=/path/report.txt
///
/// Uses TextEdit with a temporary file. It does nothing if TextEdit is already open, so no document of the user's is
/// touched, and quits TextEdit at the end. The picture is only taken when Screen Recording is already allowed.
@MainActor
enum SelectionSelfTest {
    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["SHOUT_SELECTION_SELFTEST"] else { return false }
        Task { @MainActor in
            var report: [String] = []
            func log(_ s: String) { report.append(s); try? report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
            // The boxed picture is kept next to the report, to look at.
            await run(log: log, keep: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("selection-boxed.png"))
            log("DONE")
            NSApp.terminate(nil)
        }
        return true
    }

    private static let textEditID = "com.apple.TextEdit"

    private static func run(log: (String) -> Void, keep: URL) async {
        guard AXIsProcessTrusted() else { log("SKIP: no Accessibility permission"); return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: textEditID).isEmpty else {
            log("SKIP: TextEdit is open; quit it and run again"); return
        }
        guard let editorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: textEditID) else {
            log("SKIP: TextEdit not found"); return
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shout-selection-selftest-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            log("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func plain(_ p: String?) -> String? { p.map { $0.hasPrefix("/private/") ? String($0.dropFirst("/private".count)) : $0 } }

        // Line 2 and line 6 are the same, so only the editor's position tells them apart.
        let lines = ["# Notes", "repeat me", "The Add Task button should be smaller.", "It sits at the top right.",
                     "Nothing else here.", "repeat me", "The end."]
        let file = dir.appendingPathComponent("notes.txt")
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.open([file], withApplicationAt: editorURL, configuration: config)
        defer { NSRunningApplication.runningApplications(withBundleIdentifier: textEditID).forEach { $0.terminate() } }

        var element: AXUIElement?
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: textEditID).first,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { continue }
            let (ctx, handle) = ContextReader.capture(includeText: true)
            if let handle, ctx.isEditable, (ctx.windowTitle ?? "").contains("notes") { element = handle.element; break }
        }
        guard let element else { log("FAIL: TextEdit didn't open a focused document"); return }
        func select(_ location: Int, _ length: Int) {
            var r = CFRange(location: location, length: length)
            if let v = AXValueCreate(.cfRange, &r) { AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v) }
        }
        let text = lines.joined(separator: "\n") as NSString

        // Lines 3–4.
        let start = text.range(of: "The Add Task").location
        let end = NSMaxRange(text.range(of: "top right."))
        select(start, end - start)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let two = SelectionReader.current()
        check("selected text read", two?.text == "The Add Task button should be smaller.\nIt sits at the top right.",
              two?.text.debugDescription ?? "nil")
        check("its file", plain(two?.file) == plain(file.path), two?.file ?? "nil")
        check("its lines", two?.lines == 3...4, two?.location ?? "nil")
        check("where it is on screen", (two?.bounds).map { $0.width > 40 && $0.height > 20 } == true,
              (two?.bounds).map { "\($0)" } ?? "nil")

        // The second "repeat me" (line 6), told apart from line 2 by where the editor says it is.
        let second = text.range(of: "repeat me", options: .backwards)
        select(second.location, second.length)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let repeated = SelectionReader.current()
        check("a repeated line is placed by the editor", repeated?.lines == 6...6, repeated?.location ?? "nil")

        select(0, 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        check("no selection, nothing to box", SelectionReader.current() == nil)

        // The picture, with the box around lines 3–4.
        guard WindowCapture.hasPermission else {
            log("SKIP  the boxed picture: Screen Recording isn't allowed for Shout (not asked during a self-test)")
            log("\(passed) passed, \(failed) failed")
            return
        }
        select(start, end - start)
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let sel = SelectionReader.current(), let box = sel.bounds else {
            check("selection for the picture", false); log("\(passed) passed, \(failed) failed"); return
        }
        do {
            let (path, detail) = try await WindowCapture.captureUnderMouse(into: dir, name: "boxed", highlight: box)
            try? FileManager.default.removeItem(at: keep)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: keep)
            let where_ = WindowCapture.windowOnly(detail)
            check("the window is named", where_?.contains("TextEdit") == true, where_ ?? "nil")
            // The box's left edge, halfway down, is red in the picture.
            let center = CGPoint(x: box.midX, y: box.midY)
            let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            let frame = WindowCapture.frontWindow(at: center).flatMap { id in
                windows.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
                    .flatMap { $0[kCGWindowBounds as String] as? NSDictionary }
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            }
            if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
               let id = WindowCapture.frontWindow(at: center), let w = content.windows.first(where: { $0.windowID == id }) {
                log("INFO  window \(id): ScreenCaptureKit frame \(w.frame), window list \(frame.map { "\($0)" } ?? "nil"), selection \(box)")
            }
            if let frame, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                log("INFO  image \(image.width)x\(image.height)")
                let scale = CGFloat(image.width) / frame.width
                let x = Int(((box.minX - 5) - frame.minX) * scale), y = Int((box.midY - frame.minY) * scale)
                var red = 0
                if let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                    let bpp = image.bitsPerPixel / 8
                    for dx in -4...4 where x + dx >= 0 && x + dx < image.width && y >= 0 && y < image.height {
                        let p = bytes + y * image.bytesPerRow + (x + dx) * bpp
                        if p[0] > 170 && p[1] < 120 && p[2] < 120 { red += 1 }
                    }
                }
                check("the selection is boxed in the picture", red > 0, "\(red) red pixels at x \(x), y \(y): \(path)")
            } else {
                check("the picture", false, "no window frame or image: \(path)")
            }
        } catch {
            check("the boxed picture", false, error.localizedDescription)
        }
        log("\(passed) passed, \(failed) failed")
    }
}

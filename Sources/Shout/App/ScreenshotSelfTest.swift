import AppKit
import ShoutKit

/// Development aid: checks Prompt mode's screenshot capture on the real system, inside the signed app:
///
///     open -n /Applications/Shout.app --env SHOUT_DEMO_DATA=1 --env SHOUT_SCREENSHOT_SELFTEST=/path/report.txt
///
/// A clipboard image (the user's clipboard is put back afterwards), a macOS-style screenshot file (in a temporary
/// folder, not the Desktop), Shout's ⌥ capture (only when Screen Recording is already allowed: no prompt), the
/// copies the prompt points to, and the archive History reads.
@MainActor
enum ScreenshotSelfTest {
    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["SHOUT_SCREENSHOT_SELFTEST"] else { return false }
        Task { @MainActor in
            var report: [String] = []
            func log(_ s: String) { report.append(s); try? report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
            await run(log: log)
            log("DONE")
            NSApp.terminate(nil)
        }
        return true
    }

    private static func run(log: (String) -> Void) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shout-shots-selftest-\(UUID().uuidString.prefix(6))")
        let shotFolder = root.appendingPathComponent("ScreenshotFolder")
        try? FileManager.default.createDirectory(at: shotFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            log("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func png(_ color: NSColor) -> Data {
            let image = NSImage(size: NSSize(width: 64, height: 40), flipped: false) { r in color.setFill(); r.fill(); return true }
            return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        }

        let watcher = ScreenshotWatcher(root: root.appendingPathComponent("Captures"))
        watcher.screenshotFolderOverride = shotFolder
        let audioStart = Date()
        watcher.start(audioStart: audioStart)

        // 1. An image on the clipboard, timed when it appears. The user's clipboard comes back afterwards.
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        pb.clearContents()
        pb.setData(png(.systemBlue), forType: .png)
        try? await Task.sleep(nanoseconds: 600_000_000)
        pb.clearContents()
        if !saved.isEmpty {
            pb.writeObjects(saved.map { dict in
                let item = NSPasteboardItem()
                for (t, d) in dict { item.setData(d, forType: t) }
                return item
            })
        }
        let clip = watcher.captures.first
        check("clipboard image caught", clip?.source == .clipboard && clip.map { FileManager.default.fileExists(atPath: $0.path) } == true,
              "\(watcher.captures.count) caught")
        check("clipboard image timed", clip.map { abs($0.time - 1.0) < 0.6 } == true, String(format: "%.2f s", clip?.time ?? -1))

        // 2. A macOS screenshot file, named the way macOS names it, timed by its name.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let shotTime = Date()
        let shotURL = shotFolder.appendingPathComponent("Screenshot \(f.string(from: shotTime)).png")
        // Full Retina size, as macOS saves it: the copy the prompt points to is capped.
        if let ctx = CGContext(data: nil, width: 2940, height: 1912, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(NSColor.systemPurple.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 2940, height: 1912))
            if let img = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                try? data.write(to: shotURL)
            }
        }
        let flag = "1"
        _ = flag.withCString { setxattr(shotURL.path, "com.apple.metadata:kMDItemIsScreenCapture", $0, 1, 0, 0) }
        // An image that isn't a screenshot is left out.
        try? png(.systemGreen).write(to: shotFolder.appendingPathComponent("holiday.png"))

        // 3. Shout's own capture of the window under the mouse, only if already allowed.
        if WindowCapture.hasPermission {
            let mouse = NSEvent.mouseLocation
            let point = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)
            let under = WindowCapture.frontWindow(at: point)
            let owner = under.flatMap { id in
                ((CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first?[kCGWindowOwnerName as String] as? String)
            }
            log("info  mouse at \(Int(point.x)),\(Int(point.y)); window under it: \(owner ?? "none, so the whole screen")")
            do {
                let (path, detail) = try await WindowCapture.captureUnderMouse(into: watcher.folder(), name: "capture-test")
                let image = NSImage(contentsOfFile: path)
                let px = image?.representations.first.map { max($0.pixelsWide, $0.pixelsHigh) } ?? 0
                check("⌥ capture saved, at most 1280 px", image != nil && px > 10 && px <= PromptImages.maxLongEdge, "\(px) px: \(path)")
                check("⌥ capture described", detail != nil, detail ?? "nil")
                watcher.add(PromptCapture(time: 2.5, path: path, source: .shout, detail: detail))
            } catch {
                check("⌥ capture", false, error.localizedDescription)
            }
            // Shout's own window is captured too (History entry 52 showed only the wallpaper: the user was
            // describing a change to Shout). A solid orange window of this process, captured at its centre.
            if let screen = NSScreen.screens.first {
                let size = NSSize(width: 360, height: 240)
                let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
                let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Shout self-test"
                window.backgroundColor = .systemOrange
                // In front of the user's windows (at the normal level: floating panels are never picked).
                let center = CGPoint(x: window.frame.midX, y: screen.frame.height - window.frame.midY)
                var inFront = false
                for _ in 0..<4 where !inFront {
                    NSApp.activate()
                    window.orderFrontRegardless()
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    inFront = WindowCapture.frontWindow(at: center) == CGWindowID(window.windowNumber)
                }
                if !inFront {
                    log("SKIP  Shout's own window: macOS didn't bring the test window to the front")
                } else {
                do {
                    let (path, _) = try await WindowCapture.captureUnderMouse(into: watcher.folder(), name: "own-window", at: center)
                    let rep = NSImage(contentsOfFile: path).flatMap { $0.tiffRepresentation }.flatMap(NSBitmapImageRep.init)
                    // The ring is drawn at the centre: sample a quarter of the way in instead.
                    let color = rep.flatMap { $0.colorAt(x: $0.pixelsWide / 4, y: $0.pixelsHigh / 2)?.usingColorSpace(.sRGB) }
                    let orange = color.map { $0.redComponent > 0.8 && $0.greenComponent > 0.35 && $0.greenComponent < 0.75 && $0.blueComponent < 0.35 } ?? false
                    check("Shout's own window captured, not the wallpaper", orange,
                          color.map { String(format: "r %.2f g %.2f b %.2f, %dx%d", $0.redComponent, $0.greenComponent, $0.blueComponent, rep?.pixelsWide ?? 0, rep?.pixelsHigh ?? 0) } ?? "no image")
                    try? FileManager.default.removeItem(atPath: path)
                } catch {
                    check("Shout's own window captured", false, error.localizedDescription)
                }
                }
                window.orderOut(nil)
            }
        } else {
            log("SKIP  ⌥ capture: Screen Recording isn't allowed for Shout (not asked during a self-test)")
        }

        let finished = await watcher.finish()
        let file = finished.first { $0.source == .screenshot }
        // /var and /private/var are the same folder.
        func plain(_ p: String) -> String { p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p }
        func same(_ a: String?, _ b: URL) -> Bool { a.map(plain) == plain(b.path) }
        check("screenshot file found", same(file?.path, shotURL), "\(finished.map(\.source.rawValue))")
        check("not-a-screenshot left out", !finished.contains { $0.path.hasSuffix("holiday.png") })
        check("screenshot timed by its name",
              file.map { abs($0.time - shotTime.timeIntervalSince(audioStart)) < 1.1 } == true, String(format: "%.2f s", file?.time ?? -1))
        check("in the order taken", finished.map(\.time) == finished.map(\.time).sorted())

        // 4. Copies next to the prompt: the screenshot survives leaving its folder.
        let kept = watcher.keepCopies(finished)
        let keptShot = kept.first { $0.source == .screenshot }
        try? FileManager.default.removeItem(at: shotURL)
        check("copied next to the prompt", keptShot.map { $0.path.hasPrefix(watcher.folder().path) && FileManager.default.fileExists(atPath: $0.path) } == true,
              keptShot?.path ?? "nil")
        check("original remembered", same(keptShot?.original, shotURL), keptShot?.original ?? "nil")
        let keptSize = keptShot.flatMap { NSImage(contentsOfFile: $0.path) }.flatMap { $0.representations.first }.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
        check("copy sized for the assistant", keptSize == CGSize(width: 1280, height: 832), keptSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")

        // 5. The archive History reads.
        if let folder = watcher.sessionFolder {
            let saved = PromptCaptureArchive.Saved(historyID: nil, createdAt: Date(), captures: kept.map { $0.record(said: "…this text box") })
            try? PromptCaptureArchive.save(saved, in: folder)
            PromptCaptureArchive.attach(folder: folder, historyID: 42, root: watcher.root)
            let loaded = PromptCaptureArchive.load(historyID: 42, root: watcher.root)
            check("History finds the pictures", loaded?.saved.captures.count == kept.count, "\(loaded?.saved.captures.count ?? 0) of \(kept.count)")

            // 6. A dictation cancelled afterwards (Esc, or a tap too short to transcribe) doesn't delete them.
            watcher.cancel()
            check("a later cancelled dictation keeps the pictures", FileManager.default.fileExists(atPath: folder.path)
                  && PromptCaptureArchive.load(historyID: 42, root: watcher.root)?.saved.captures.count == kept.count)
        } else {
            check("session folder", false)
        }

        // 7. A prompt cancelled while it's running deletes its own pictures.
        watcher.start(audioStart: Date())
        let running = watcher.folder()
        try? png(.systemBlue).write(to: running.appendingPathComponent("capture-1.png"))
        watcher.cancel()
        check("a cancelled prompt's pictures are deleted", !FileManager.default.fileExists(atPath: running.path), running.path)
        log("\(passed) passed, \(failed) failed")
    }
}

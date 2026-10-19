import AppKit
import ShoutKit

/// Development aid: checks that a dictation goes back to the field it started in (`ContextReader.returnTo`) on
/// real apps, inside the signed app so its Accessibility permission applies:
///
///     open -n /Applications/Shout.app --env SHOUT_DEMO_DATA=1 --env SHOUT_RETURN_SELFTEST=/path/report.txt
///
/// Uses TextEdit with temporary files, and Calculator as "somewhere else" (Finder with no window can't be brought
/// to the front from the background). It does nothing if TextEdit is already open, so no document of the user's
/// is touched, and quits what it opened at the end.
@MainActor
enum FocusReturnSelfTest {
    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["SHOUT_RETURN_SELFTEST"] else { return false }
        Task { @MainActor in
            var report: [String] = []
            func log(_ s: String) { report.append(s); try? report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
            await run(log: log)
            log("DONE")
            NSApp.terminate(nil)
        }
        return true
    }

    private static let textEditID = "com.apple.TextEdit"

    private static func run(log: (String) -> Void) async {
        guard AXIsProcessTrusted() else { log("SKIP: no Accessibility permission"); return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: textEditID).isEmpty else {
            log("SKIP: TextEdit is open; quit it and run again"); return
        }
        guard let editorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: textEditID),
              let calcURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") else {
            log("SKIP: TextEdit or Calculator not found"); return
        }
        let calcWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").isEmpty
        let calcConfig = NSWorkspace.OpenConfiguration()
        calcConfig.activates = false
        guard let elsewhere = try? await NSWorkspace.shared.openApplication(at: calcURL, configuration: calcConfig) else {
            log("SKIP: Calculator didn't open"); return
        }
        defer { if !calcWasRunning { elsewhere.terminate() } }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shout-return-selftest-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            log("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }

        /// Opens a file in TextEdit and waits for its text view to have the focus.
        func open(_ name: String, _ text: String) async -> (ContextReader.FocusHandle?, NSRunningApplication?) {
            let url = dir.appendingPathComponent(name)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: editorURL, configuration: config)
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: textEditID).first,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { continue }
                let (ctx, handle) = ContextReader.capture(includeText: true)
                if let handle, ctx.isEditable, (ctx.windowTitle ?? "").contains(url.deletingPathExtension().lastPathComponent) {
                    return (handle, app)
                }
            }
            return (nil, nil)
        }
        func front() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing" }
        func goElsewhere() async {
            _ = await ContextReader.bringToFront(elsewhere)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        func setRange(_ el: AXUIElement, _ location: Int, _ length: Int) {
            var r = CFRange(location: location, length: length)
            if let v = AXValueCreate(.cfRange, &r) { AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) }
        }
        func value(_ el: AXUIElement) -> String? { ContextReader.value(of: el) }

        // 1. Away and back: the caret's field gets the text.
        let (a, editor) = await open("first.txt", "Hello ")
        guard let a, let editor else { log("FAIL: TextEdit didn't open a focused document"); return }
        setRange(a.element, 6, 0)
        let (_, handleA) = ContextReader.capture(includeText: true)
        check("window recorded", handleA?.window != nil)
        check("caret recorded", handleA?.caret == NSRange(location: 6, length: 0), "\(String(describing: handleA?.caret))")
        await goElsewhere()
        check("left for Calculator", NSWorkspace.shared.frontmostApplication?.processIdentifier == elsewhere.processIdentifier,
              "front: \(front())")
        let back = await ContextReader.returnTo(handleA, app: editor, selection: nil)
        check("returned to the field", back == .field, "\(back)")
        check("TextEdit in front", NSWorkspace.shared.frontmostApplication?.processIdentifier == editor.processIdentifier, "front: \(front())")
        let inserter = TextInserter()
        let outcome = await inserter.insert("world")
        try? await Task.sleep(nanoseconds: 400_000_000)
        check("pasted where the caret was", outcome == .pasted && value(a.element) == "Hello world",
              "\(outcome), \(value(a.element)?.debugDescription ?? "nil")")

        // 2. Another window of the same app took the focus meanwhile: the first one comes back.
        let (second, _) = await open("second.txt", "Other")
        check("second document open", second != nil)
        await goElsewhere()
        let back2 = await ContextReader.returnTo(handleA, app: editor, selection: nil)
        let focused = ContextReader.focusedElement(pid: editor.processIdentifier)
        check("the first window's field, not the newer window's", back2 == .field && focused.map { CFEqual($0, a.element) } == true,
              "\(back2)")

        // 3. The selection to replace is restored after it moved.
        let (c, _) = await open("third.txt", "Alpha Beta")
        if let c {
            setRange(c.element, 6, 4)
            let (ctxC, handleC) = ContextReader.capture(includeText: true)
            check("selection read", ctxC.selectedText == "Beta", ctxC.selectedText ?? "nil")
            await goElsewhere()
            setRange(c.element, 0, 5)  // the selection moves while the user is away
            let back3 = await ContextReader.returnTo(handleC, app: editor, selection: "Beta")
            let selected: String? = ContextReader.attribute(c.element, kAXSelectedTextAttribute)
            check("selection restored", back3 == .field && selected == "Beta", "\(back3), \(selected ?? "nil")")

            // 4. The selected text itself changed: nothing is replaced.
            AXUIElementSetAttributeValue(c.element, kAXValueAttribute as CFString, "Gamma Delta" as CFString)
            await goElsewhere()
            let back4 = await ContextReader.returnTo(handleC, app: editor, selection: "Beta")
            check("changed selection refused", back4 == .lost("the selected text changed"), "\(back4)")
        } else {
            check("third document open", false)
        }

        // 5. The window was closed: nothing is pasted anywhere else.
        if let window = handleA?.window,
           let close: AXUIElement = ContextReader.attribute(window, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(close, kAXPressAction as CFString)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await goElsewhere()
            let back5 = await ContextReader.returnTo(handleA, app: editor, selection: nil)
            check("closed window refused", back5 == .lost("its window was closed"), "\(back5)")
        } else {
            check("close button found", false)
        }

        // TextEdit was opened by this test: quit it (it autosaves the temporary files).
        editor.terminate()
        for _ in 0..<30 where !editor.isTerminated { try? await Task.sleep(nanoseconds: 100_000_000) }
        if !editor.isTerminated { editor.forceTerminate() }
        log("\(passed) passed, \(failed) failed")
    }
}

import AppKit
import Carbon.HIToolbox

/// Inserts text into the focused app by temporarily placing it on the clipboard and posting ⌘V,
/// then restoring the user's clipboard. Uses a lazily-rendered pasteboard item so we can tell
/// whether any app actually consumed the paste.
@MainActor
final class TextInserter: NSObject {
    nonisolated static let syntheticEventTag: Int64 = 0x5749_5350 // "WISP"

    /// `notPasted`: nothing took the paste and the clipboard holds something newer, so the text is only in History.
    enum Outcome { case pasted, copiedOnly, notPasted }

    /// Serves the promised text of the item currently on the clipboard (kept alive here).
    private var provider: PasteProvider?
    private var restoreWorkItem: DispatchWorkItem?
    /// The user's clipboard, saved by a paste whose item is still on the clipboard (restore not yet run).
    private var pendingRestore: (snapshot: Snapshot, change: Int)?

    /// Saved clipboard contents (all items, all types).
    private struct Snapshot { let items: [[NSPasteboard.PasteboardType: Data]] }

    var restoreClipboard = true

    func insert(_ text: String) async -> Outcome {
        guard !text.isEmpty else { return .pasted }
        let pb = NSPasteboard.general
        // Right after a paste the clipboard still holds our own item: the user's contents are in that
        // paste's snapshot, and reading the clipboard now would save our text in their place.
        let snapshot: Snapshot?
        if let due = pendingRestore, due.change == pb.changeCount { snapshot = restoreClipboard ? due.snapshot : nil }
        else { snapshot = restoreClipboard ? Self.snapshot(pb) : nil }
        restoreWorkItem?.cancel(); restoreWorkItem = nil
        pendingRestore = nil

        let provider = PasteProvider(text)
        self.provider = provider
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        // Ask clipboard managers not to record this transient value.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        pb.writeObjects([item])
        let ourChange = pb.changeCount
        if let snapshot { pendingRestore = (snapshot, ourChange) }

        Self.postPaste()

        // Wait up to ~700 ms for the target app to request the data. ⌘V is already posted, so the wait
        // runs to the end even if the dictation is cancelled meanwhile (a cancelled sleep returns at once,
        // which would report no paste and leave the user's clipboard unrestored). A cancelled caller still gets
        // the outcome, and must check it still owns the UI before reporting it.
        let pasted = await Task { await Self.waitForRequest(provider) }.value

        // A newer paste or the user's own copy has replaced our item: that clipboard isn't ours to touch. A newer
        // paste reports for itself (the app may have answered both ⌘Vs from it).
        guard pb.changeCount == ourChange else { return pasted || self.provider !== provider ? .pasted : .notPasted }

        if pasted {
            if let snapshot {
                let work = DispatchWorkItem { [weak self] in
                    guard pb.changeCount == ourChange else { return } // user copied something new
                    Self.restore(snapshot, to: pb)
                    self?.pendingRestore = nil
                }
                restoreWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
            return .pasted
        } else {
            // Nothing accepted the paste: leave the text on the clipboard as plain data.
            pb.clearContents()
            pb.setString(text, forType: .string)
            pendingRestore = nil
            return .copiedOnly
        }
    }

    private static func waitForRequest(_ provider: PasteProvider) async -> Bool {
        for _ in 0..<35 {
            if provider.wasRequested { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return provider.wasRequested
    }

    /// Puts text on the clipboard permanently (e.g. "copy" actions).
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Keystrokes

    nonisolated static func postPaste() {
        let src = CGEventSource(stateID: .privateState)
        let v = CGKeyCode(keyCodeForCharacter("v") ?? UInt16(kVK_ANSI_V))
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        for e in [down, up] {
            e?.flags = .maskCommand
            e?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        }
        down?.post(tap: .cgSessionEventTap)
        usleep(8_000)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Posts a single key press (used for voice commands like "press enter").
    nonisolated static func pressKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            e?.post(tap: .cgSessionEventTap)
            usleep(5_000)
        }
    }

    /// Finds the virtual key code that types `char` in the current keyboard layout (Dvorak, AZERTY…).
    nonisolated static func keyCodeForCharacter(_ char: Character) -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let target = String(char)
        return data.withUnsafeBytes { raw -> UInt16? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<UInt16(128) {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == target { return code }
            }
            return nil
        }
    }

    // MARK: - Clipboard snapshot

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        let items = (pb.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { dict[t] = d } }
            return dict
        }
        return Snapshot(items: items)
    }

    private static func restore(_ s: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard !s.items.isEmpty else { return }
        let items = s.items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        }
        pb.writeObjects(items)
    }
}

/// Lazily provides one paste's text and records that an app asked for it. AppKit normally calls it on
/// the main thread, but nothing guarantees that (a read from another thread in this process, for one),
/// so it keeps its own locked state instead of assuming the main actor.
private final class PasteProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let lock = NSLock()
    private var requested = false

    init(_ text: String) { self.text = text }

    var wasRequested: Bool { lock.withLock { requested } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        lock.withLock { requested = true }
        item.setString(text, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}

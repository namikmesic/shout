import AppKit
import CoreGraphics
import ShoutKit

/// What the hotkey layer asks the app to do. Delivered on the main thread.
enum HotkeyEvent {
    case pushToTalkDown        // start recording (hold)
    case pushToTalkUp          // keys released: stop + process (unless hands-free locked)
    case handsFreeToggle       // lock recording on / stop a locked recording
    case commandDown           // start (or convert to) Command Mode
    case commandUp
    case promptDown            // start (or convert to) Prompt mode
    case promptUp
    case markTap               // a lone tap of ⌥ during a session: "this" (Prompt mode takes a screenshot)
    case screenshotKeys        // ⌘⇧3/4/5 during a session: macOS is taking a screenshot
    case cancel                // Esc during a session
    case interrupted           // another key was pressed together with the push-to-talk key
    case pasteLast
    case copyLast
    case scribeToggle       // start or stop the meeting Scribe
}

/// Global keyboard/mouse shortcut detection through a CGEventTap running on its own thread.
/// Matched shortcut keys are swallowed so they do not reach the focused app.
final class HotkeyManager: @unchecked Sendable {
    struct Config: Equatable {
        var pushToTalk: KeyCombo
        var handsFree: KeyCombo
        var command: KeyCombo
        var pasteLast: KeyCombo?
        var copyLast: KeyCombo?
        var scribe: KeyCombo? = nil
        var prompt: KeyCombo = KeyCombo([])
    }

    var onEvent: ((HotkeyEvent) -> Void)?
    /// Called on the main thread while capturing a new shortcut: (currently held, final?)
    var onCapture: ((Set<UInt16>, Bool) -> Void)?

    private let lock = NSLock()
    private var config: Config
    private var pressed: Set<UInt16> = []
    private var swallowed: Set<UInt16> = []
    private var sessionActive = false     // a recording is running (set by the app)
    private var pttHeld = false
    private var commandHeld = false
    private var promptHeld = false
    /// An ⌥ pressed during a session with nothing else since: released quickly, it's a mark tap.
    private var optionTap: (key: UInt16, at: Date)?
    private var capturing = false
    private var captureMax: Set<UInt16> = []

    private var tap: CFMachPort?          // guarded by `lock` (re-enabled from the tap thread)
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private(set) var isRunning = false
    private var resignObserver: NSObjectProtocol?

    init(config: Config) { self.config = config }

    func update(config: Config) {
        lock.lock(); defer { lock.unlock() }
        let old = self.config
        self.config = config
        // A hold that began on the old shortcut can't be released by matching the new one.
        if pttHeld && config.pushToTalk != old.pushToTalk { pttHeld = false; emit(.pushToTalkUp) }
        if commandHeld && config.command != old.command { commandHeld = false; emit(.commandUp) }
        if promptHeld && config.prompt != old.prompt { promptHeld = false; emit(.promptUp) }
    }

    func setSessionActive(_ active: Bool) {
        lock.lock(); sessionActive = active; lock.unlock()
    }

    /// Call on the main thread.
    func beginCapture() {
        lock.lock(); capturing = true; captureMax = []; lock.unlock()
        // Capturing swallows every key system-wide: it ends when the user leaves Shout, even if the
        // view that started it never calls `endCapture()`.
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.cancelCapture()
            }
        }
    }

    /// Call on the main thread.
    func endCapture() {
        lock.lock(); capturing = false; lock.unlock()
        removeResignObserver()
    }

    private func cancelCapture() {
        lock.lock(); let wasCapturing = capturing; capturing = false; lock.unlock()
        removeResignObserver()
        if wasCapturing { onCapture?([], true) }
    }

    private func removeResignObserver() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    // MARK: Tap lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        // The tap's refcon keeps the manager alive until the tap thread has left its run loop, so no
        // callback can run on a freed manager.
        let retained = Unmanaged.passRetained(self)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: hotkeyTapCallback, userInfo: retained.toOpaque()) else {
            retained.release()
            return false
        }
        lock.lock(); self.tap = tap; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
            retained.release()
        }
        thread.name = "shout.hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        lock.lock(); let tap = self.tap; self.tap = nil; lock.unlock()
        // Invalidating the port also removes its source from the tap thread's run loop.
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil; thread = nil; isRunning = false
        lock.lock()
        pressed = []; swallowed = []; pttHeld = false; commandHeld = false; promptHeld = false; capturing = false; captureMax = []
        optionTap = nil
        lock.unlock()
    }

    /// The tap was disabled (timeout or user input): turn it back on and forget keys, modifiers (fn included) and
    /// mouse buttons whose release was lost meanwhile, so a push-to-talk hold that ended is released.
    fileprivate func reenable() {
        lock.lock()
        let tap = self.tap
        pressed = pressed.filter { Self.isPhysicallyDown($0) }
        swallowed.formIntersection(pressed)
        let cfg = config
        if pttHeld && !pressed.isSuperset(of: cfg.pushToTalk.keys) { pttHeld = false; emit(.pushToTalkUp) }
        if commandHeld && !pressed.isSuperset(of: cfg.command.keys) { commandHeld = false; emit(.commandUp) }
        if promptHeld && !pressed.isSuperset(of: cfg.prompt.keys) { promptHeld = false; emit(.promptUp) }
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// The hardware state: unlike the session state, it also counts keys this tap swallowed.
    private static func isPhysicallyDown(_ key: UInt16) -> Bool {
        if key >= KeyCombo.mouseBase {
            guard let button = CGMouseButton(rawValue: UInt32(key - KeyCombo.mouseBase)) else { return false }
            return CGEventSource.buttonState(.hidSystemState, button: button)
        }
        // A modifier counts as down by its key state or its flag (fn's key state isn't reliable everywhere).
        if let mask = deviceMasks[key], CGEventSource.flagsState(.hidSystemState).rawValue & mask != 0 { return true }
        return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key))
    }

    // MARK: Event handling (tap thread)

    private static let deviceMasks: [UInt16: UInt64] = [
        KeyCombo.Key.leftControl: 0x0000_0001, KeyCombo.Key.leftShift: 0x0000_0002,
        KeyCombo.Key.rightShift: 0x0000_0004, KeyCombo.Key.leftCommand: 0x0000_0008,
        KeyCombo.Key.rightCommand: 0x0000_0010, KeyCombo.Key.leftOption: 0x0000_0020,
        KeyCombo.Key.rightOption: 0x0000_0040, KeyCombo.Key.rightControl: 0x0000_2000,
        KeyCombo.Key.fn: 0x0080_0000,
    ]

    private func emit(_ e: HotkeyEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    /// Returns true when the event should be swallowed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var key: UInt16
        var isDown: Bool
        switch type {
        case .keyDown, .keyUp:
            key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            isDown = type == .keyDown
            if isDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return swallowed.contains(key)
            }
        case .flagsChanged:
            key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let mask = Self.deviceMasks[key] else { return false }
            isDown = event.flags.rawValue & mask != 0
        case .otherMouseDown, .otherMouseUp:
            key = KeyCombo.mouseBase + UInt16(event.getIntegerValueField(.mouseEventButtonNumber))
            isDown = type == .otherMouseDown
        default:
            return false
        }

        // Heal missed key-ups (e.g. while the tap was disabled): drop modifiers the event says are up.
        if type != .otherMouseDown && type != .otherMouseUp {
            let flags = event.flags.rawValue
            for k in pressed where k != key {
                if let mask = Self.deviceMasks[k], flags & mask == 0 { pressed.remove(k) }
            }
        }

        let wasPressed = pressed
        if isDown { pressed.insert(key) } else { pressed.remove(key) }

        // Shortcut recording mode: report keys, swallow everything.
        if capturing {
            if key == KeyCombo.Key.escape && isDown {
                capturing = false
                DispatchQueue.main.async { [weak self] in self?.onCapture?([], true) }
                return true
            }
            if isDown && (pressed.count > captureMax.count || !pressed.isSubset(of: captureMax)) {
                captureMax = captureMax.union(pressed)
            }
            let snapshot = captureMax, done = pressed.isEmpty && !captureMax.isEmpty
            if done { capturing = false }
            DispatchQueue.main.async { [weak self] in self?.onCapture?(snapshot, done) }
            return true
        }

        if sessionActive { trackMarks(type: type, key: key, isDown: isDown, flags: event.flags) }

        let cfg = config
        // Key release: swallow if its press was swallowed.
        if !isDown {
            var swallow = swallowed.remove(key) != nil
            if pttHeld && !pressed.isSuperset(of: cfg.pushToTalk.keys) {
                pttHeld = false
                emit(.pushToTalkUp)
            }
            if commandHeld && !pressed.isSuperset(of: cfg.command.keys) {
                commandHeld = false
                emit(.commandUp)
            }
            if promptHeld && !pressed.isSuperset(of: cfg.prompt.keys) {
                promptHeld = false
                emit(.promptUp)
            }
            // Fn release should never reach apps while it is a shortcut key (avoids the Globe popup).
            if key == KeyCombo.Key.fn && Self.usesFn(cfg) { swallow = true }
            return swallow
        }

        // Escape cancels an active session.
        if key == KeyCombo.Key.escape && sessionActive {
            swallowed.insert(key)
            pttHeld = false; commandHeld = false; promptHeld = false
            emit(.cancel)
            return true
        }

        guard pressed != wasPressed else { return false }

        // Most specific shortcut first.
        if !cfg.handsFree.isEmpty && pressed == cfg.handsFree.keys {
            swallowKeys(cfg.handsFree.keys)
            pttHeld = false
            emit(.handsFreeToggle)
            return shouldSwallow(key)
        }
        if !cfg.command.isEmpty && pressed == cfg.command.keys {
            swallowKeys(cfg.command.keys)
            commandHeld = true
            pttHeld = false
            emit(.commandDown)
            return shouldSwallow(key)
        }
        if !cfg.prompt.isEmpty && pressed == cfg.prompt.keys {
            swallowKeys(cfg.prompt.keys)
            promptHeld = true
            pttHeld = false
            emit(.promptDown)
            return shouldSwallow(key)
        }
        if let pl = cfg.pasteLast, !pl.isEmpty, pressed == pl.keys {
            swallowKeys(pl.keys)
            emit(.pasteLast)
            return shouldSwallow(key)
        }
        if let nt = cfg.scribe, !nt.isEmpty, pressed == nt.keys {
            swallowKeys(nt.keys)
            emit(.scribeToggle)
            return shouldSwallow(key)
        }
        if let cl = cfg.copyLast, !cl.isEmpty, pressed == cl.keys {
            swallowKeys(cl.keys)
            emit(.copyLast)
            return shouldSwallow(key)
        }
        if !cfg.pushToTalk.isEmpty && pressed == cfg.pushToTalk.keys {
            swallowKeys(cfg.pushToTalk.keys)
            pttHeld = true
            emit(.pushToTalkDown)
            return shouldSwallow(key)
        }

        // Another key joined the push-to-talk key (e.g. fn+arrow): the user meant a normal shortcut.
        if pttHeld && !isPartOfAnyShortcut(key, cfg) {
            pttHeld = false
            emit(.interrupted)
        }
        return false
    }

    /// Prompt mode's screenshot cues during a session: a lone ⌥ tap (pressed and released within 0.6 s with no other
    /// key between), and macOS's screenshot keys (⌘⇧3, ⌘⇧4, ⌘⇧5). Neither is swallowed.
    private func trackMarks(type: CGEventType, key: UInt16, isDown: Bool, flags: CGEventFlags) {
        let options: Set<UInt16> = [KeyCombo.Key.leftOption, KeyCombo.Key.rightOption]
        if type == .flagsChanged && options.contains(key) {
            // ⌥ as part of a Shout shortcut isn't a mark.
            let cfg = config
            let inShortcut = [cfg.pushToTalk, cfg.handsFree, cfg.command, cfg.prompt].contains { $0.keys.contains(key) }
            if isDown && !inShortcut { optionTap = (key, Date()) }
            else if !isDown, let tap = optionTap, tap.key == key, Date().timeIntervalSince(tap.at) < 0.6 {
                optionTap = nil
                emit(.markTap)
            } else { optionTap = nil }
            return
        }
        if isDown { optionTap = nil }
        let screenshotKeys: Set<UInt16> = [20, 21, 23]  // 3, 4, 5
        if type == .keyDown && screenshotKeys.contains(key) && flags.contains(.maskCommand) && flags.contains(.maskShift) {
            emit(.screenshotKeys)
        }
    }

    private func swallowKeys(_ keys: Set<UInt16>) {
        // Only swallow non-modifier keys (and fn). Swallowing ⌃/⌥/⌘ can leave apps with stuck modifiers.
        for k in keys where !KeyCombo.modifierKeys.contains(k) || k == KeyCombo.Key.fn { swallowed.insert(k) }
    }

    private func shouldSwallow(_ key: UInt16) -> Bool { swallowed.contains(key) }

    private func isPartOfAnyShortcut(_ key: UInt16, _ cfg: Config) -> Bool {
        cfg.handsFree.keys.contains(key) || cfg.command.keys.contains(key) || cfg.prompt.keys.contains(key)
    }

    private static func usesFn(_ cfg: Config) -> Bool {
        cfg.pushToTalk.keys.contains(KeyCombo.Key.fn) || cfg.handsFree.keys.contains(KeyCombo.Key.fn) ||
            cfg.command.keys.contains(KeyCombo.Key.fn) || cfg.prompt.keys.contains(KeyCombo.Key.fn)
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        manager.reenable()
        return Unmanaged.passUnretained(event)
    }
    // Ignore events we synthesised ourselves (paste keystrokes).
    if event.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticEventTag {
        return Unmanaged.passUnretained(event)
    }
    return manager.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

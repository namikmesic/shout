import Carbon
import Foundation

/// A shortcut defined as the exact set of keys (virtual key codes) that must be held together.
/// Modifier keys are represented by their own key codes so left/right sides are distinct,
/// and extra mouse buttons use pseudo key codes starting at `mouseBase`.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keys: Set<UInt16>

    public init(_ keys: Set<UInt16>) { self.keys = keys }

    public static let mouseBase: UInt16 = 0x1000

    public enum Key {
        public static let fn: UInt16 = 63
        public static let leftCommand: UInt16 = 55, rightCommand: UInt16 = 54
        public static let leftShift: UInt16 = 56, rightShift: UInt16 = 60
        public static let leftOption: UInt16 = 58, rightOption: UInt16 = 61
        public static let leftControl: UInt16 = 59, rightControl: UInt16 = 62
        public static let capsLock: UInt16 = 57
        public static let space: UInt16 = 49, escape: UInt16 = 53, returnKey: UInt16 = 36, tab: UInt16 = 48
    }

    public static let modifierKeys: Set<UInt16> = [
        Key.fn, Key.leftCommand, Key.rightCommand, Key.leftShift, Key.rightShift,
        Key.leftOption, Key.rightOption, Key.leftControl, Key.rightControl,
    ]

    public var isEmpty: Bool { keys.isEmpty }
    public var isModifierOnly: Bool { !keys.isEmpty && keys.isSubset(of: Self.modifierKeys) }

    /// One of the two can't be pressed without passing through or completing the other: one's keys contain the
    /// other's (Left ⌥ and ⌥M, ⌃⌘V and ⌃⌘⇧V). Shortcuts match exact key sets, so pressing the longer fires both.
    public func overlaps(_ other: KeyCombo) -> Bool {
        !isEmpty && !other.isEmpty && (keys.isSubset(of: other.keys) || other.keys.isSubset(of: keys))
    }

    public var displayString: String {
        let order: [UInt16] = [Key.fn, Key.leftControl, Key.rightControl, Key.leftOption, Key.rightOption,
                               Key.leftShift, Key.rightShift, Key.leftCommand, Key.rightCommand]
        let mods = order.filter(keys.contains)
        let others = keys.subtracting(order).sorted()
        return (mods + others).map(Self.name(for:)).joined(separator: " + ")
    }

    public static func name(for key: UInt16) -> String {
        switch key {
        case Key.fn: return "fn"
        // Left-side modifiers are the default, so they show as the bare symbol (as macOS menus do).
        case Key.leftCommand: return "⌘"
        case Key.rightCommand: return "Right ⌘"
        case Key.leftShift: return "⇧"
        case Key.rightShift: return "Right ⇧"
        case Key.leftOption: return "⌥"
        case Key.rightOption: return "Right ⌥"
        case Key.leftControl: return "⌃"
        case Key.rightControl: return "Right ⌃"
        case Key.capsLock: return "⇪"
        case Key.space: return "Space"
        case Key.escape: return "Esc"
        case Key.returnKey: return "Return"
        case Key.tab: return "Tab"
        case 51: return "Delete"
        case 122: return "F1"; case 120: return "F2"; case 99: return "F3"; case 118: return "F4"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"; case 100: return "F8"
        case 101: return "F9"; case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        case 105: return "F13"; case 107: return "F14"; case 113: return "F15"; case 106: return "F16"
        case 64: return "F17"; case 79: return "F18"; case 80: return "F19"
        default:
            if key >= mouseBase { return "Mouse \(key - mouseBase + 1)" }
            return KeyNames.character(for: key) ?? "Key \(key)"
        }
    }

    // Defaults mirror the familiar Flow-style layout: hold fn to talk, fn+Space for hands-free,
    // fn+Control for Command Mode.
    public static let defaultPushToTalk = KeyCombo([Key.fn])
    public static let defaultHandsFree = KeyCombo([Key.fn, Key.space])
    public static let defaultCommand = KeyCombo([Key.fn, Key.leftControl])
    public static let defaultPrompt = KeyCombo([Key.fn, Key.leftShift])
    public static let defaultPasteLast = KeyCombo([Key.leftControl, Key.leftCommand, 9]) // ⌃⌘V
    public static let defaultCopyLast = KeyCombo([Key.leftControl, Key.leftCommand, 8])  // ⌃⌘C
    /// Starts or stops the Scribe (left ⌥, so Right ⌥ + M still types "µ"). M is the key that types "m" in the
    /// keyboard layout: on AZERTY that isn't ANSI key 46, which types ",".
    public static let defaultScribe = KeyCombo([Key.leftOption, KeyNames.keyCode(typing: "m") ?? 46])  // ⌥M
}

/// Names of character keys: what they type in the keyboard layout, as macOS menus show shortcuts (AZERTY's key 46
/// reads ","), else the US ANSI name.
enum KeyNames {
    /// US ANSI key codes → characters.
    static let map: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 50: "`", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    static let arrows: ClosedRange<UInt16> = 123...126

    static func character(for key: UInt16) -> String? {
        guard let ansi = map[key] else { return nil }
        if arrows.contains(key) { return ansi }
        return typed(by: key)?.uppercased() ?? ansi
    }

    /// The character key that types `character` in the keyboard layout.
    static func keyCode(typing character: String) -> UInt16? {
        map.keys.sorted().first { !arrows.contains($0) && typed(by: $0) == character }
    }

    /// What `key` types with no modifiers in the current ASCII-capable layout (the one shortcuts follow, also while a
    /// non-Latin input source is selected). Nil off the main thread, where Text Input Sources mustn't be used.
    static func typed(by key: UInt16) -> String? {
        guard Thread.isMainThread,
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        // The layout data belongs to `source`: keep it alive while UCKeyTranslate reads the CFData's own bytes.
        return withExtendedLifetime(source) { () -> String? in
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length)
            return s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty ? nil : s
        }
    }
}

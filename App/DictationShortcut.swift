import AppKit
import Carbon

/// A physical trigger key plus the modifiers held with it. Existing key-only settings use modifiers = 0.
nonisolated struct DictationShortcut: Equatable, Sendable {
    struct Modifiers: OptionSet, Sendable {
        let rawValue: Int
        static let control = Self(rawValue: 1 << 0)
        static let option = Self(rawValue: 1 << 1)
        static let shift = Self(rawValue: 1 << 2)
        static let command = Self(rawValue: 1 << 3)
        static let function = Self(rawValue: 1 << 4)
        static let all: Self = [.control, .option, .shift, .command, .function]

        init(rawValue: Int) { self.rawValue = rawValue }
        init(_ flags: NSEvent.ModifierFlags) {
            var result: Self = []
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.command) { result.insert(.command) }
            if flags.contains(.function) { result.insert(.function) }
            self = result
        }
    }

    let code: Int
    let modifiers: Modifiers

    init(code: Int, modifiers: Int = 0) {
        self.code = code
        self.modifiers = Modifiers(rawValue: modifiers).intersection(.all).subtracting(Self.modifier(for: code) ?? [])
    }

    static func modifier(for code: Int) -> Modifiers? {
        switch code {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        case 63: .function
        default: nil
        }
    }

    var name: String {
        var prefix = ""
        for (flag, label) in [(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"), (.function, "Fn+")] {
            if modifiers.contains(flag) { prefix += label }
        }
        return prefix + Self.keyName(code)
    }

    static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [
            36: "Return ↩", 48: "Tab ⇥", 49: String(localized: "空格"), 51: "Delete ⌫", 53: "Esc",
            54: String(localized: "右 Command ⌘"), 55: String(localized: "左 Command ⌘"),
            56: String(localized: "左 Shift ⇧"), 57: "Caps Lock ⇪", 58: String(localized: "左 Option ⌥"),
            59: String(localized: "左 Control ⌃"), 60: String(localized: "右 Shift ⇧"),
            61: String(localized: "右 Option ⌥"), 62: String(localized: "右 Control ⌃"), 63: String(localized: "Fn / 地球仪键"),
            76: String(localized: "数字键盘 Enter"), 71: "Clear", 114: "Insert", 115: "Home", 116: "Page Up",
            117: "Delete ⌦", 119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        if let name = special[code] { return name }
        let functionKeys = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if let index = functionKeys.firstIndex(of: code) { return "F\(index + 1)" }
        let keypad = [65: ".", 67: "*", 69: "+", 75: "/", 78: "−", 81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9"]
        if let key = keypad[code] { return String(localized: "数字键盘") + " " + key }
        // Use a keyboard layout instead of characters from the active input method (e.g. Chinese IME).
        if (0...127).contains(code), let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = unsafeBitCast(property, to: CFData.self)
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKey: UInt32 = 0, count = 0
                var chars = [UniChar](repeating: 0, count: 8)
                if UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKey, chars.count, &count, &chars) == noErr, count > 0 {
                    let text = String(utf16CodeUnits: chars, count: count)
                    if text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { return text.uppercased() }
                }
            }
        }
        return String(localized: "按键 \(code)")
    }
}

nonisolated struct DictationKeyEvent: Sendable {
    let code: Int
    let down: Bool
    let modifiers: DictationShortcut.Modifiers
    var repeating = false
}

/// Track the consumed key until its key-up, even when a modifier is released first.
nonisolated struct DictationShortcutTracker {
    struct Result { var press = false; var release = false; var suppress = false }
    private(set) var active = false
    private var pressed: Set<Int> = []
    private var consumed: Set<Int> = []

    mutating func reset() { active = false; pressed = []; consumed = [] }

    mutating func handle(_ event: DictationKeyEvent, shortcut: DictationShortcut) -> Result {
        let wasDown = pressed.contains(event.code)
        if event.down { pressed.insert(event.code) } else { pressed.remove(event.code) }
        var result = Result(suppress: consumed.contains(event.code))
        if !event.down { consumed.remove(event.code) }
        let own = DictationShortcut.modifier(for: shortcut.code) ?? []
        let modifiersMatch = event.modifiers.subtracting(own) == shortcut.modifiers
        if active, (event.code == shortcut.code && !event.down || !modifiersMatch) {
            active = false
            result.release = true
        }
        if !active, event.down, event.code == shortcut.code, !event.repeating, !wasDown, modifiersMatch {
            active = true
            result.press = true
            // Modifier events must pass through to keep the OS modifier state balanced.
            if own.isEmpty { consumed.insert(event.code); result.suppress = true }
        }
        return result
    }
}

nonisolated struct DictationShortcutRecorder {
    private(set) var candidate: DictationShortcut?
    mutating func reset() { candidate = nil }

    mutating func handle(_ event: DictationKeyEvent) -> DictationShortcut? {
        guard event.code != 57 else { candidate = nil; return nil } // A lock key has no reliable hold/release pair.
        if event.down, !event.repeating {
            // Once a normal key is down, releasing a modifier first must not change the recorded chord.
            if candidate == nil || DictationShortcut.modifier(for: candidate!.code) != nil {
                candidate = DictationShortcut(code: event.code, modifiers: event.modifiers.rawValue)
            }
        } else if !event.down, let candidate, candidate.code == event.code {
            self.candidate = nil
            return candidate
        }
        return nil
    }
}

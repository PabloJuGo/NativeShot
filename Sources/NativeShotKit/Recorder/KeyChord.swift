import Foundation

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1), option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4), command = KeyModifiers(rawValue: 8)
}

/// Text for the on-screen shortcut overlay. Plain typing never yields a label, so passwords or prose
/// can't leak; nothing here stores keys.
public enum KeyChord {
    public static func label(keyCode: UInt16, character: String?, modifiers: KeyModifiers) -> String? {
        guard !modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        guard let key = special[keyCode] ?? character?.trimmingCharacters(in: .controlCharacters).uppercased(),
              !key.isEmpty else { return nil }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key
    }

    private static let special: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "␣", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

import Carbon.HIToolbox
import Foundation

/// Label of a physical key under the current keyboard layout, so shortcut labels follow layout changes (UTL).
public enum KeyboardLayoutLabels {
    /// Notification posted (distributed) when the selected input source changes.
    public static let changedNotification = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    /// Printable label for `keyCode` with no modifiers, or nil for keys without one (F-keys, arrows, space…).
    public static func label(forKeyCode keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length).uppercased()
        return isPrintable(s) ? s : nil
    }

    static func isPrintable(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

extension ShortcutRegistry {
    /// Recomputes `keyLabel` of every binding. Pass a custom `label` in tests.
    public func refreshLabels(label: (UInt32) -> String? = KeyboardLayoutLabels.label(forKeyCode:)) {
        for (action, combo) in bindings {
            guard let l = label(combo.keyCode), l != combo.keyLabel else { continue }
            setLabel(l, for: action)
        }
    }
}

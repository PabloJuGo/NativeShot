import Carbon.HIToolbox
import Foundation

/// A global key combination. `modifiers` uses Carbon masks (cmdKey, shiftKey, optionKey, controlKey).
public struct KeyCombo: Hashable, Codable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// Human label of the key as typed when recorded ("5", "A", "F1").
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }

    public static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.keyCode == b.keyCode && a.modifiers == b.modifiers }
    public func hash(into h: inout Hasher) { h.combine(keyCode); h.combine(modifiers) }

    /// macOS glyph order: ⌃⌥⇧⌘.
    public var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    /// Global hotkeys without ⌘/⌃/⌥ would steal ordinary typing; reject them.
    public var isAcceptableGlobal: Bool {
        modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    /// Converts NSEvent.ModifierFlags raw values (device independent bits) to Carbon masks.
    public static func carbonModifiers(fromCocoa raw: UInt) -> UInt32 {
        var m: UInt32 = 0
        if raw & (1 << 17) != 0 { m |= UInt32(shiftKey) }
        if raw & (1 << 18) != 0 { m |= UInt32(controlKey) }
        if raw & (1 << 19) != 0 { m |= UInt32(optionKey) }
        if raw & (1 << 20) != 0 { m |= UInt32(cmdKey) }
        return m
    }

    public static let commandShift5 = KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "5")
}

public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case selector, region, window, display, lastRegion, textRecognition, recordScreen, scrolling // ids follow the order: append only
    case pinClipboard, openLibrary, openSettings, togglePrivateSession, closePins // UTL: no default combos

    /// Defaults avoid every built-in macOS combo so first launch never collides (HOTKEY fallback ⌃⌥⌘5).
    public var defaultCombo: KeyCombo? {
        let hyper = UInt32(controlKey | optionKey | cmdKey)
        switch self {
        case .selector: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: hyper, keyLabel: "5")
        case .region: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: hyper, keyLabel: "4")
        case .display: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: hyper, keyLabel: "3")
        case .window: return KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: hyper, keyLabel: "6")
        case .textRecognition: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: hyper, keyLabel: "2")
        case .scrolling: return KeyCombo(keyCode: UInt32(kVK_ANSI_8), modifiers: hyper, keyLabel: "8")
        case .lastRegion, .recordScreen, .pinClipboard, .openLibrary, .openSettings, .togglePrivateSession, .closePins: return nil
        }
    }
}

public enum ShortcutError: Error, Equatable, Sendable {
    case duplicate(ShortcutAction)
    case notAcceptable
    case systemRefused(Int32)
}

/// Seam over the OS registration API so the registry logic is testable.
@MainActor
public protocol HotKeyRegistrar: AnyObject {
    func register(_ combo: KeyCombo, id: UInt32) throws(ShortcutError)
    func unregister(id: UInt32)
}

/// Single owner of global shortcuts: no duplicates, registration verified,
/// a failed change leaves the previous shortcut working.
@MainActor
public final class ShortcutRegistry {
    private let registrar: HotKeyRegistrar
    private let defaults: UserDefaults
    private static let key = "shortcuts.v1"
    public private(set) var bindings: [ShortcutAction: KeyCombo] = [:]
    public var onTrigger: ((ShortcutAction) -> Void)?

    public init(registrar: HotKeyRegistrar, defaults: UserDefaults = .standard) {
        self.registrar = registrar
        self.defaults = defaults
    }

    private static func id(_ a: ShortcutAction) -> UInt32 { UInt32(ShortcutAction.allCases.firstIndex(of: a)! + 1) }
    public static func action(for id: UInt32) -> ShortcutAction? {
        let i = Int(id) - 1
        return ShortcutAction.allCases.indices.contains(i) ? ShortcutAction.allCases[i] : nil
    }

    /// Loads persisted bindings (or defaults) and registers each. Returns actions that failed to register.
    @discardableResult
    public func activate() -> [ShortcutAction: ShortcutError] {
        let stored: [ShortcutAction: KeyCombo?]
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([ShortcutAction: KeyCombo?].self, from: data) {
            stored = decoded
        } else {
            stored = [:]
        }
        var failures: [ShortcutAction: ShortcutError] = [:]
        for action in ShortcutAction.allCases {
            let combo = stored.keys.contains(action) ? stored[action]! : action.defaultCombo
            guard let combo else { continue }
            do { try bind(action, to: combo, persist: false) } catch { failures[action] = error }
        }
        return failures
    }

    /// Binds `combo` to `action`. On failure the previous binding stays registered.
    public func bind(_ action: ShortcutAction, to combo: KeyCombo, persist: Bool = true) throws(ShortcutError) {
        guard combo.isAcceptableGlobal else { throw .notAcceptable }
        if let other = bindings.first(where: { $0.value == combo && $0.key != action })?.key {
            throw .duplicate(other)
        }
        let id = Self.id(action)
        let previous = bindings[action]
        if previous != nil { registrar.unregister(id: id) }
        do {
            try registrar.register(combo, id: id)
        } catch {
            if let previous { try? registrar.register(previous, id: id) }
            throw error
        }
        bindings[action] = combo
        if persist { save() }
    }

    public func unbind(_ action: ShortcutAction) {
        guard bindings.removeValue(forKey: action) != nil else { return }
        registrar.unregister(id: Self.id(action))
        save()
    }

    public func deactivateAll() {
        for action in bindings.keys { registrar.unregister(id: Self.id(action)) }
        bindings.removeAll()
    }

    public func trigger(id: UInt32) {
        if let a = Self.action(for: id) { onTrigger?(a) }
    }

    func setLabel(_ label: String, for action: ShortcutAction) {
        bindings[action]?.keyLabel = label
        save()
    }

    private func save() {
        // Store every action explicitly so an unbound default stays unbound after relaunch.
        var all: [ShortcutAction: KeyCombo?] = [:]
        for a in ShortcutAction.allCases { all[a] = .some(bindings[a]) }
        defaults.set(try? JSONEncoder().encode(all), forKey: Self.key)
    }
}

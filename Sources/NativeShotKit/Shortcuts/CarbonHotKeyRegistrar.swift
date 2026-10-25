import Carbon.HIToolbox
import Foundation

/// Public, non-intercepting global hotkeys via RegisterEventHotKey (ADR-0003). Receives only the
/// registered combos — never a global key stream — so no Accessibility/Input Monitoring is needed.
@MainActor
public final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    private static let signature: OSType = 0x4E53_4854 // 'NSHT'
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let onPress: (UInt32) -> Void

    public init(onPress: @escaping (UInt32) -> Void) {
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr, hk.signature == CarbonHotKeyRegistrar.signature, let ctx else { return status }
            let me = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(ctx).takeUnretainedValue()
            let id = hk.id
            MainActor.assumeIsolated { me.onPress(id) } // Carbon dispatches on the main run loop
            return noErr
        }, 1, &spec, ctx, &handler)
    }

    public func register(_ combo: KeyCombo, id: UInt32) throws(ShortcutError) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw .systemRefused(status) }
        refs[id] = ref
    }

    public func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }
}

/// Read-only hint about Apple's own screenshot shortcuts. macOS has no public API for this; the
/// symbolic hotkeys domain is read (never written) and the result is shown as "possibly active".
public enum SystemScreenshotShortcutProbe {
    public enum State: Sendable, Equatable { case possiblyActive, appearsDisabled, unknown }

    /// 184 = "Screenshot and recording options" (⇧⌘5). 28/29/30/31 = ⇧⌘3/⇧⌘4 variants.
    public static func state(ofSymbolicHotKey id: Int = 184) -> State {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let all = domain["AppleSymbolicHotKeys"] as? [String: Any] else { return .unknown }
        guard let entry = all[String(id)] as? [String: Any] else { return .possiblyActive } // absent = factory default (on)
        if let enabled = entry["enabled"] as? Bool { return enabled ? .possiblyActive : .appearsDisabled }
        if let enabled = entry["enabled"] as? Int { return enabled != 0 ? .possiblyActive : .appearsDisabled }
        return .unknown
    }
}

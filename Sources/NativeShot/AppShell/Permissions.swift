import AVFoundation
import SwiftUI

/// Read-only view of the permissions NativeShot can need. Never triggers a system prompt.
enum PermState {
    case granted, denied, notDetermined

    init(_ s: AVAuthorizationStatus) {
        switch s {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }

    static var microphone: PermState { PermState(AVCaptureDevice.authorizationStatus(for: .audio)) }
    static var camera: PermState { PermState(AVCaptureDevice.authorizationStatus(for: .video)) }
    @MainActor static var screen: PermState { ScreenCaptureAdapter.hasPermission ? .granted : .denied }

    var label: LocalizedStringKey {
        switch self {
        case .granted: "Concedido"
        case .denied: "Denegado"
        case .notDetermined: "Se pedirá al usarlo"
        }
    }

    /// Text and symbol both carry the state, so it never relies on color alone.
    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "questionmark.circle"
        }
    }

    var color: Color {
        switch self { case .granted: .green; case .denied: .red; case .notDetermined: .secondary }
    }

    var diagnosticName: String {
        switch self { case .granted: "granted"; case .denied: "denied"; case .notDetermined: "notDetermined" }
    }
}

struct PermissionBadge: View {
    let state: PermState
    var body: some View {
        Label(state.label, systemImage: state.symbol).foregroundStyle(state.color)
    }
}

/// Small reusable host for the onboarding and help windows: one window each, reused between openings.
@MainActor
final class AuxWindow {
    private var window: NSWindow?
    private let title: String
    private let size: NSSize
    private let autosave: String

    init(title: String, size: NSSize, autosave: String) {
        self.title = title; self.size = size; self.autosave = autosave
    }

    func show<V: View>(_ content: () -> V) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: content())
            w.setFrameAutosaveName(autosave)
            if !w.setFrameUsingName(autosave) { w.center() }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

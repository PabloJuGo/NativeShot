import AppKit
import SwiftUI
import NativeShotKit

@MainActor
enum OnboardingWindow {
    private static let window = AuxWindow(title: String(localized: "Bienvenido a NativeShot"),
                                          size: NSSize(width: 520, height: 640), autosave: "NativeShotOnboarding")
    static func show(app: AppController) { window.show { OnboardingView(app: app, done: close) } }
    static func close() { window.close() }
}

/// UI-01. States: new (never asked), partial (screen granted, mic/camera refused), granted, denied.
struct OnboardingView: View {
    @ObservedObject var app: AppController
    let done: () -> Void
    @AppStorage("screenPermissionAsked") private var asked = false
    @State private var screen = PermState.screen
    @State private var mic = PermState.microphone
    @State private var camera = PermState.camera

    private enum Stage { case new, partial, granted, denied }

    private var stage: Stage {
        if screen != .granted { return asked ? .denied : .new }
        return mic == .denied || camera == .denied ? .partial : .granted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "camera.viewfinder").font(.system(size: 40)).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bienvenido a NativeShot").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Capturas y grabaciones de pantalla, nativas de macOS.").foregroundStyle(.secondary)
                }
            }
            Label("NativeShot funciona sin conexión: no hay cuentas, telemetría ni subidas. Todo se queda en este Mac.",
                  systemImage: "lock.shield")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Permisos") {
                VStack(alignment: .leading, spacing: 12) {
                    permissionRow("Grabación de pantalla", screen,
                                  "Imprescindible para capturar y grabar la pantalla.")
                    if screen != .granted { screenActions }
                    Divider()
                    permissionRow("Micrófono", mic, "Solo si activas la narración al grabar. macOS lo pedirá entonces.")
                    Divider()
                    permissionRow("Cámara", camera, "Solo si activas la superposición de webcam al grabar. macOS lo pedirá entonces.")
                }
                .padding(4)
            }
            statusLine

            GroupBox("Atajos") {
                VStack(alignment: .leading, spacing: 6) {
                    shortcutRow("Selector de captura", .selector)
                    shortcutRow("Capturar región", .region)
                    shortcutRow("Capturar ventana", .window)
                    shortcutRow("Pantalla completa", .display)
                    shortcutRow("Capturar texto (OCR)", .textRecognition)
                    Button("Usar ⌘⇧5 como atajo del selector…") { app.openSettings() }
                        .buttonStyle(.link)
                        .padding(.top, 4)
                }
                .padding(4)
            }

            Spacer(minLength: 0)
            HStack {
                Button("Hacer una captura de prueba") { done(); app.perform(.region) }
                    .disabled(screen != .granted)
                Spacer()
                Button("Empezar") { UserDefaults.standard.set(true, forKey: Prefs.onboardingDone); done() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 640)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    @ViewBuilder private var screenActions: some View {
        HStack {
            if asked {
                Text("Actívalo en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla. macOS puede pedir reiniciar NativeShot.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(asked ? LocalizedStringKey("Abrir Ajustes del Sistema") : LocalizedStringKey("Conceder…")) {
                if asked {
                    ScreenCaptureAdapter.openPrivacySettings()
                } else {
                    asked = true
                    ScreenCaptureAdapter.requestPermission()
                    refresh()
                }
            }
        }
    }

    private var statusLine: some View {
        Group {
            switch stage {
            case .new: Text("Concede la grabación de pantalla para empezar.")
            case .partial: Text("Listo para capturar. Sin micrófono o cámara, esas funciones de la grabación quedarán desactivadas.")
            case .granted: Text("Todo listo.")
            case .denied: Text("Falta el permiso de grabación de pantalla: la captura está desactivada hasta concederlo.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func permissionRow(_ title: LocalizedStringKey, _ state: PermState, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) { PermissionBadge(state: state) }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func shortcutRow(_ title: LocalizedStringKey, _ action: ShortcutAction) -> some View {
        LabeledContent(title) {
            Text(app.shortcuts?.bindings[action]?.displayString ?? String(localized: "Sin asignar")).monospacedDigit()
        }
    }

    private func refresh() {
        screen = .screen; mic = .microphone; camera = .camera
    }
}

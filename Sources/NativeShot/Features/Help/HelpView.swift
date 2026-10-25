import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NativeShotKit

@MainActor
enum HelpWindow {
    private static let window = AuxWindow(title: String(localized: "Ayuda y diagnóstico"),
                                          size: NSSize(width: 520, height: 560), autosave: "NativeShotHelp")
    static func show(app: AppController) { window.show { HelpView(app: app) } }
}

/// UI-20: offline documentation, permission state and a local diagnostic export.
struct HelpView: View {
    @ObservedObject var app: AppController
    @State private var screen = PermState.screen
    @State private var mic = PermState.microphone
    @State private var camera = PermState.camera

    var body: some View {
        Form {
            Section("Permisos") {
                LabeledContent("Grabación de pantalla") { PermissionBadge(state: screen) }
                LabeledContent("Micrófono") { PermissionBadge(state: mic) }
                LabeledContent("Cámara") { PermissionBadge(state: camera) }
                HStack {
                    Button("Abrir Ajustes del Sistema") { ScreenCaptureAdapter.openPrivacySettings() }
                    Button("Abrir bienvenida…") { OnboardingWindow.show(app: app) }
                }
            }
            Section("Documentación") {
                topic("Capturar", "Usa el selector (⌃⌥⌘5 por defecto) para elegir región, ventana o pantalla. Pulsa R, W o D para cambiar de modo y Esc para cancelar. Tras capturar aparece una miniatura: copia (⌘C), guarda (⌘S), edita, fija, comparte o arrástrala a otra app.")
                topic("Captura con scroll y texto", "La captura con scroll une varias pantallas de contenido que desplazas tú. «Capturar texto» copia el texto y los códigos QR de la región sin guardar nada.")
                topic("Grabar", "Graba la pantalla, una ventana o una región, con audio del sistema y micrófono opcionales. El micrófono y la cámara solo se piden cuando los activas.")
                topic("Atajos", "Todos los atajos se cambian en Ajustes › Atajos. Si usas ⌘⇧5, desactiva antes el atajo de Apple desde Ajustes del Sistema; NativeShot no toca los ajustes del sistema.")
                topic("Biblioteca y privacidad", "Las capturas se guardan solo en este Mac, con búsqueda por el texto que contienen. No hay cuentas, telemetría ni subidas.")
            }
            Section {
                Button("Exportar diagnóstico…") { export() }
            } footer: {
                Text("Genera un archivo JSON local con versión, permisos y ajustes. No incluye capturas, nombres de archivo, texto reconocido ni rutas personales.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screen = .screen; mic = .microphone; camera = .camera
        }
    }

    private func topic(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        DisclosureGroup(title) {
            Text(body).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "NativeShot-diagnostico.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await DiagnosticsCollector.report(app: app).json().write(to: url, options: .atomic)
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }
}

@MainActor
enum DiagnosticsCollector {
    private static let preferenceKeys = [Prefs.afterCapture, Prefs.showsCursor, Prefs.windowShadow, Prefs.playSound,
                                         Prefs.timerSeconds, Prefs.overlayDuration, Prefs.overlayCorner, Prefs.keepHistory,
                                         Prefs.ocrIndex, Prefs.historyMaxCount, Prefs.trashRetentionDays,
                                         Prefs.exportFormat, Prefs.jpegQuality, Prefs.exportScale, Prefs.showDockIcon]

    static func report(app: AppController) async -> DiagnosticReport {
        let d = UserDefaults.standard
        var prefs: [String: String] = [:]
        for k in preferenceKeys { if let v = d.object(forKey: k) { prefs[k] = "\(v)" } }
        // File name templates and folder names can be personal; only say whether they were customized.
        prefs["customSaveFolder"] = String(!(d.string(forKey: Prefs.saveFolder) ?? "").isEmpty)
        prefs["customFileNameTemplate"] = String((d.string(forKey: Prefs.fileNameTemplate) ?? FileNamingPolicy.default.template) != FileNamingPolicy.default.template)
        var shortcuts: [String: String] = [:]
        for a in ShortcutAction.allCases { shortcuts[a.rawValue] = app.shortcuts?.bindings[a]?.displayString ?? "-" }
        for (a, e) in app.shortcutFailures { shortcuts[a.rawValue + ".error"] = "\(e)" }
        var counts: [String: Int] = [:]
        if let store = app.library.store {
            counts["library"] = (try? await store.count(HistoryQuery())) ?? 0
            counts["trash"] = (try? await store.count(HistoryQuery(trashedOnly: true))) ?? 0
        }
        let info = Bundle.main.infoDictionary
        return DiagnosticReport(
            app: "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            locale: Locale.current.identifier,
            permissions: ["screenRecording": PermState.screen.diagnosticName,
                          "microphone": PermState.microphone.diagnosticName,
                          "camera": PermState.camera.diagnosticName,
                          "heicEncoding": String(ImageExporter.supportsHEIC)],
            preferences: prefs, shortcuts: shortcuts, counts: counts)
    }
}

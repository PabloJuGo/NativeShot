import AppKit
import UniformTypeIdentifiers
import NativeShotKit

/// UTL: URL scheme, manual update check and preferences backup. Everything here runs only on an explicit user
/// action or an incoming URL that the user has to confirm; nothing runs at launch and nothing is sent anywhere
/// except the one releases request the user asks for.
extension AppController {
    // MARK: URL scheme

    static var urlAllowlist: Set<URLSchemeCommand> {
        get { Set((UserDefaults.standard.string(forKey: Prefs.urlSchemeAllowed) ?? "").split(separator: ",").compactMap { URLSchemeCommand(rawValue: String($0)) }) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted().joined(separator: ","), forKey: Prefs.urlSchemeAllowed) }
    }

    static func title(of c: URLSchemeCommand) -> String {
        switch c {
        case .region: String(localized: "Capturar una región")
        case .window: String(localized: "Capturar una ventana")
        case .display: String(localized: "Capturar la pantalla completa")
        case .ocr: String(localized: "Capturar texto (OCR)")
        case .record: String(localized: "Iniciar o detener la grabación")
        case .lastRegion: String(localized: "Repetir la última región")
        case .openLibrary: String(localized: "Abrir la biblioteca")
        case .pinClipboard: String(localized: "Fijar la imagen del portapapeles")
        }
    }

    private static var confirmingURL = false

    /// An external request never acts on its own: it is parsed strictly, checked against the allowlist and the
    /// user must confirm in a dialog (Cancel is the default button).
    func handle(url: URL) {
        let d = UserDefaults.standard
        switch URLSchemeCommand.parse(url, enabled: d.bool(forKey: Prefs.urlSchemeEnabled), allowed: Self.urlAllowlist) {
        case .failure(.disabled):
            Toast.show(String(localized: "Las acciones por URL están desactivadas en Ajustes › Privacidad"), symbol: "link.badge.plus")
        case .failure(.notAllowed(let c)):
            Toast.show(String(localized: "La acción «\(Self.title(of: c))» no está permitida por URL"), symbol: "hand.raised")
        case .failure:
            Toast.show(String(localized: "URL de NativeShot no válida"), symbol: "exclamationmark.triangle")
        case .success(let cmd):
            guard !Self.confirmingURL else { return }
            Self.confirmingURL = true
            defer { Self.confirmingURL = false }
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = String(localized: "Una aplicación pide a NativeShot: \(Self.title(of: cmd))")
            alert.informativeText = cmd.capturesScreen
                ? String(localized: "Esto usará la pantalla. Solo continúa si has sido tú quien lo ha pedido.")
                : String(localized: "Solo continúa si has sido tú quien lo ha pedido.")
            alert.addButton(withTitle: String(localized: "Cancelar"))
            alert.addButton(withTitle: String(localized: "Permitir"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            perform(Self.action(for: cmd))
        }
    }

    private static func action(for c: URLSchemeCommand) -> ShortcutAction {
        switch c {
        case .region: .region
        case .window: .window
        case .display: .display
        case .ocr: .textRecognition
        case .record: .recordScreen
        case .lastRegion: .lastRegion
        case .openLibrary: .openLibrary
        case .pinClipboard: .pinClipboard
        }
    }

    // MARK: Update check

    /// Repository from Info.plist (`NativeShotRepositoryURL`). Empty means not configured: nothing is requested.
    static var repositoryURL: String { (Bundle.main.object(forInfoDictionaryKey: "NativeShotRepositoryURL") as? String) ?? "" }

    func checkForUpdates() {
        guard let endpoint = UpdateCheck.latestReleaseEndpoint(repository: Self.repositoryURL) else {
            Self.info(String(localized: "Comprobación de actualizaciones no configurada"),
                      String(localized: "Esta compilación no tiene un repositorio de versiones configurado, así que NativeShot no consulta nada."))
            return
        }
        let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        Task {
            var request = URLRequest(url: endpoint, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.httpShouldHandleCookies = false
            do {
                let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let release = UpdateCheck.parseLatest(data) else {
                    Self.info(String(localized: "No se pudo comprobar"), String(localized: "El repositorio no devolvió una versión publicada."))
                    return
                }
                if UpdateCheck.isNewer(release.tag, than: current) {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Hay una versión nueva: \(release.tag)")
                    alert.informativeText = String(localized: "Tienes la \(current). Se abrirá la página de la versión en tu navegador; la descarga la haces tú.")
                    alert.addButton(withTitle: String(localized: "Ver versión"))
                    alert.addButton(withTitle: String(localized: "Ahora no"))
                    NSApp.activate()
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
                } else {
                    Self.info(String(localized: "NativeShot está al día"), String(localized: "Versión instalada: \(current)."))
                }
            } catch {
                Self.info(String(localized: "No se pudo comprobar"), error.localizedDescription)
            }
        }
    }

    private static func info(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: Preferences backup

    /// Only these keys travel. The URL scheme switch and its allowlist are left out on purpose: an imported file
    /// must never be able to turn on external control.
    static let backup = PreferencesBackup(rules: [
        Prefs.afterCapture: .string(allowed: Set(AfterCapture.allCases.map(\.rawValue)), maxLength: 16),
        Prefs.showsCursor: .bool, Prefs.windowShadow: .bool, Prefs.playSound: .bool,
        Prefs.timerSeconds: .int(0...60), Prefs.overlayDuration: .double(0...120),
        Prefs.overlayCorner: .string(allowed: Set(OverlayCorner.allCases.map(\.rawValue)), maxLength: 16),
        Prefs.keepHistory: .bool, Prefs.ocrIndex: .bool, Prefs.historyMaxCount: .int(0...1_000_000),
        Prefs.trashRetentionDays: .int(0...3650),
        Prefs.fileNameTemplate: .string(allowed: nil, maxLength: 200),
        Prefs.exportFormat: .string(allowed: ["png", "jpeg", "heic"], maxLength: 8),
        Prefs.jpegQuality: .double(0.1...1), Prefs.exportScale: .int(1...2),
        Prefs.showDockIcon: .bool, Prefs.ocrOpensWindow: .bool,
        Prefs.saveFolder: .path,
    ])

    func exportPreferences() {
        let d = UserDefaults.standard
        var values: [String: Any] = [:]
        for k in Self.backup.rules.keys { if let v = d.object(forKey: k) { values[k] = v } }
        var includeSensitive = false
        let sensitive = Self.backup.sensitiveKeys(in: values)
        if !sensitive.isEmpty {
            // Review step: show exactly what is personal and let the user leave it out (the default).
            let alert = NSAlert()
            alert.messageText = String(localized: "Revisa los datos personales antes de exportar")
            alert.informativeText = String(localized: "El archivo incluiría estas rutas de tu Mac:") + "\n\n"
                + sensitive.map { "• \(values[$0] ?? "")" }.joined(separator: "\n")
            let box = NSButton(checkboxWithTitle: String(localized: "Incluir estas rutas"), target: nil, action: nil)
            alert.accessoryView = box
            alert.addButton(withTitle: String(localized: "Continuar"))
            alert.addButton(withTitle: String(localized: "Cancelar"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            includeSensitive = box.state == .on
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "NativeShot-ajustes.json"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.backup.export(values, includeSensitive: includeSensitive).write(to: url, options: .atomic)
            Toast.show(String(localized: "Ajustes exportados"), symbol: "square.and.arrow.up")
        } catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle") }
    }

    func importPreferences() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try Self.backup.validate(Data(contentsOf: url))
            let alert = NSAlert()
            alert.messageText = String(localized: "¿Importar \(result.accepted.count) ajustes?")
            var text = String(localized: "Los ajustes actuales de esos valores se sustituirán.")
            if !result.rejected.isEmpty {
                text += "\n\n" + String(localized: "Se ignorarán \(result.rejected.count) valores no válidos:") + "\n"
                    + result.rejected.prefix(8).map { "• \($0.key): \($0.reason)" }.joined(separator: "\n")
            }
            if result.accepted[Prefs.saveFolder] != nil { text += "\n\n" + String(localized: "Incluye una carpeta de guardado.") }
            alert.informativeText = text
            alert.addButton(withTitle: String(localized: "Importar"))
            alert.addButton(withTitle: String(localized: "Cancelar"))
            guard !result.accepted.isEmpty, alert.runModal() == .alertFirstButtonReturn else { return }
            for (k, v) in result.accepted { UserDefaults.standard.set(v.any, forKey: k) }
            applyDockPolicy()
            Toast.show(String(localized: "Ajustes importados"), symbol: "square.and.arrow.down")
        } catch {
            Self.info(String(localized: "Archivo no válido"), String(localized: "No es un archivo de ajustes de NativeShot de esta versión."))
        }
    }
}

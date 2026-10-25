import AppKit
import SwiftUI
import NativeShotKit

struct SettingsView: View {
    @ObservedObject var app: AppController

    var body: some View {
        TabView {
            GeneralSettings(app: app).tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettings().tabItem { Label("Capturas", systemImage: "camera.viewfinder") }
            ShortcutSettings(app: app).tabItem { Label("Atajos", systemImage: "keyboard") }
            RecordingSettings().tabItem { Label("Grabación", systemImage: "record.circle") }
            PrivacySettings(app: app).tabItem { Label("Privacidad", systemImage: "hand.raised") }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: UI-13

struct GeneralSettings: View {
    @ObservedObject var app: AppController
    @AppStorage(Prefs.playSound) private var playSound = true
    @AppStorage(Prefs.saveFolder) private var saveFolder = ""
    @AppStorage(Prefs.showDockIcon) private var showDockIcon = false

    var body: some View {
        Form {
            Toggle("Abrir al iniciar sesión", isOn: Binding(get: { app.launchAtLogin }, set: { app.launchAtLogin = $0 }))
            Toggle("Mostrar el icono en el Dock", isOn: $showDockIcon)
                .onChange(of: showDockIcon) { app.applyDockPolicy() }
            Toggle("Reproducir sonido al capturar", isOn: $playSound)
            LabeledContent("Carpeta de guardado") {
                HStack {
                    Text(Prefs.saveFolderURL.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Elegir…") { chooseFolder() }
                }
            }
            Section("Ajustes y actualizaciones") {
                HStack {
                    Button("Exportar ajustes…") { app.exportPreferences() }
                    Button("Importar ajustes…") { app.importPreferences() }
                    Button("Buscar actualizaciones…") { app.checkForUpdates() }
                }
                Text("La comprobación de actualizaciones solo se hace cuando pulsas el botón.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url.path }
    }
}

// MARK: UI-14

struct CaptureSettings: View {
    @AppStorage(Prefs.afterCapture) private var afterCapture = AfterCapture.overlay.rawValue
    @AppStorage(Prefs.showsCursor) private var showsCursor = false
    @AppStorage(Prefs.windowShadow) private var windowShadow = true
    @AppStorage(Prefs.timerSeconds) private var timer = 0
    @AppStorage(Prefs.adjustRegion) private var adjustRegion = false
    @AppStorage(Prefs.freezeScreen) private var freezeScreen = false
    @AppStorage(Prefs.showLoupe) private var showLoupe = false
    @AppStorage(Prefs.multiRegionJoin) private var multiRegionJoin = true
    @AppStorage(Prefs.hideDesktopIcons) private var hideDesktopIcons = false
    @AppStorage(Prefs.excludeNotch) private var excludeNotch = false
    @AppStorage(Prefs.scrollAxis) private var scrollAxis = ScrollAxis.vertical.rawValue
    @AppStorage(Prefs.scrollPDF) private var scrollPDF = false
    @AppStorage(Prefs.scrollCrop) private var scrollCrop = true
    @AppStorage(Prefs.overlayDuration) private var duration = 6.0
    @AppStorage(Prefs.overlayCorner) private var corner = OverlayCorner.bottomLeft.rawValue
    @AppStorage(Prefs.keepHistory) private var keepHistory = true
    @AppStorage(Prefs.ocrIndex) private var ocrIndex = true
    @AppStorage(Prefs.historyMaxCount) private var maxCount = 0
    @AppStorage(Prefs.ocrOpensWindow) private var ocrWindow = false

    var body: some View {
        Form {
            Section("Después de capturar") {
                Picker("Acción", selection: $afterCapture) {
                    Text("Mostrar miniatura").tag(AfterCapture.overlay.rawValue)
                    Text("Copiar al portapapeles").tag(AfterCapture.copy.rawValue)
                    Text("Guardar en la carpeta").tag(AfterCapture.save.rawValue)
                    Text("Copiar y guardar").tag(AfterCapture.copyAndSave.rawValue)
                }
                Picker("Esquina de la miniatura", selection: $corner) {
                    Text("Abajo a la izquierda").tag(OverlayCorner.bottomLeft.rawValue)
                    Text("Abajo a la derecha").tag(OverlayCorner.bottomRight.rawValue)
                    Text("Arriba a la izquierda").tag(OverlayCorner.topLeft.rawValue)
                    Text("Arriba a la derecha").tag(OverlayCorner.topRight.rawValue)
                }
                Picker("Ocultar miniatura tras", selection: $duration) {
                    Text("4 s").tag(4.0); Text("6 s").tag(6.0); Text("10 s").tag(10.0); Text("Nunca").tag(0.0)
                }
            }
            Section("Captura") {
                Picker("Temporizador", selection: $timer) {
                    Text("Sin temporizador").tag(0); Text("3 s").tag(3); Text("5 s").tag(5); Text("10 s").tag(10)
                }
                Toggle("«Capturar texto» abre una ventana con el resultado", isOn: $ocrWindow)
                Toggle("Incluir el cursor", isOn: $showsCursor)
                Toggle("Sombra en capturas de ventana", isOn: $windowShadow)
                Toggle("Ocultar los iconos del escritorio", isOn: $hideDesktopIcons)
                if NSScreen.screens.contains(where: { $0.safeAreaInsets.top > 0 }) {
                    Toggle("Excluir el notch en capturas de pantalla completa", isOn: $excludeNotch)
                }
            }
            Section("Selección") {
                Toggle("Ajustar la región tras soltar el ratón", isOn: $adjustRegion)
                Toggle("Congelar la pantalla al seleccionar", isOn: $freezeScreen)
                Toggle("Lupa con coordenadas y color", isOn: $showLoupe)
                Picker("Varias regiones (⌘)", selection: $multiRegionJoin) {
                    Text("Unir en una imagen").tag(true)
                    Text("Una captura por región").tag(false)
                }
                Text("Con el ajuste activo, Retorno o doble clic confirman la región. Mantén ⌘ al arrastrar para añadir otra región; Mayúsculas fija un cuadrado.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Captura con scroll") {
                Picker("Dirección", selection: $scrollAxis) {
                    Text("Vertical").tag(ScrollAxis.vertical.rawValue)
                    Text("Horizontal").tag(ScrollAxis.horizontal.rawValue)
                }
                Toggle("Recortar el resultado antes de guardar", isOn: $scrollCrop)
                Toggle("Guardar también como PDF de varias páginas", isOn: $scrollPDF)
            }
            ExportSettingsSection()
            Section("Historial") {
                Toggle("Guardar capturas en el historial", isOn: $keepHistory)
                Toggle("Indexar el texto reconocido para buscar", isOn: $ocrIndex)
                Picker("Conservar", selection: $maxCount) {
                    Text("Nunca borrar automáticamente").tag(0)
                    Text("Últimas 100").tag(100); Text("Últimas 500").tag(500); Text("Últimas 2.000").tag(2000)
                }
                HistoryCleanupSettings(library: AppController.shared.library)
            }
        }
        .formStyle(.grouped)
    }
}

/// EXP: file name template, format, quality and scale used when saving.
struct ExportSettingsSection: View {
    @AppStorage(Prefs.fileNameTemplate) private var template = FileNamingPolicy.default.template
    @AppStorage(Prefs.exportFormat) private var format = "png"
    @AppStorage(Prefs.jpegQuality) private var quality = 0.9
    @AppStorage(Prefs.exportScale) private var scale = 2

    var body: some View {
        Section("Guardado") {
            TextField("Plantilla del nombre", text: $template)
            LabeledContent("Vista previa") {
                Text(FileNamingPolicy(template: template).name(date: Date(), type: "screenshot", app: "Safari", ext: ext))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Variables: {date} {time} {type} {app} {n}")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Formato", selection: $format) {
                Text("PNG").tag("png")
                Text("JPEG").tag("jpeg")
                if ImageExporter.supportsHEIC { Text("HEIC").tag("heic") }
            }
            if format != "png" {
                LabeledContent("Calidad") {
                    Slider(value: $quality, in: 0.5...1, step: 0.05) { Text("Calidad") }
                        .frame(width: 160)
                        .accessibilityValue(Text("\(Int(quality * 100)) %"))
                    Text("\(Int(quality * 100)) %").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Picker("Escala", selection: $scale) {
                Text("2× (píxeles completos)").tag(2)
                Text("1× (mitad de píxeles)").tag(1)
            }
        }
    }

    private var ext: String { format == "jpeg" ? "jpg" : (format == "heic" && ImageExporter.supportsHEIC ? "heic" : "png") }
}

// MARK: UI-16 + HOTKEY wizard

struct ShortcutSettings: View {
    @ObservedObject var app: AppController
    @State private var error: String?

    private let titles: [(ShortcutAction, LocalizedStringKey)] = [
        (.selector, "Selector de captura"), (.region, "Capturar región"), (.window, "Capturar ventana"),
        (.display, "Pantalla completa"), (.lastRegion, "Repetir última región"), (.textRecognition, "Capturar texto (OCR)"),
        (.recordScreen, "Grabar pantalla…"),
        (.scrolling, "Captura con scroll"),
        (.pinClipboard, "Fijar imagen del portapapeles"), (.openLibrary, "Abrir biblioteca"),
        (.openSettings, "Abrir ajustes"), (.togglePrivateSession, "Sesión privada (sin historial)"),
        (.closePins, "Cerrar imágenes fijadas"),
    ]

    var body: some View {
        Form {
            Section("Atajos globales") {
                ForEach(titles, id: \.0) { action, title in
                    LabeledContent(title) {
                        ShortcutRecorder(combo: app.shortcuts?.bindings[action]) { combo in
                            do throws(ShortcutError) { try app.rebind(action, to: combo); error = nil }
                            catch { self.error = message(for: error) }
                        }
                    }
                    if let failure = app.shortcutFailures[action] {
                        Text(message(for: failure)).font(.caption).foregroundStyle(.red)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            CommandShift5Wizard(app: app)
        }
        .formStyle(.grouped)
    }
}

func message(for e: ShortcutError) -> String {
    switch e {
    case .duplicate: String(localized: "Esa combinación ya está asignada a otra acción.")
    case .notAcceptable: String(localized: "Usa al menos ⌘, ⌃ u ⌥ para un atajo global.")
    case .systemRefused(let code): String(localized: "macOS no ha permitido registrar el atajo (código \(code)). Prueba otra combinación.")
    }
}

/// HOTKEY Guided replacement of Apple's ⇧⌘5. Never edits system settings itself.
struct CommandShift5Wizard: View {
    @ObservedObject var app: AppController
    @State private var systemState = SystemScreenshotShortcutProbe.state()
    @State private var error: String?

    private var registered: Bool { app.shortcuts?.bindings[.selector] == .commandShift5 }

    var body: some View {
        Section {
            LabeledContent("Estado") { statusText }
            if !registered {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Abre Ajustes del Sistema › Teclado › Funciones rápidas de teclado › Capturas de pantalla.")
                    Text("2. Desactiva «Opciones de captura y grabación de pantalla» (⇧⌘5). El nombre puede variar según idioma y versión.")
                    Text("3. Vuelve aquí y pulsa «Activar ⌘⇧5».")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Abrir ajustes de teclado de macOS") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    Button("Activar ⌘⇧5") { activate() }.buttonStyle(.borderedProminent)
                }
            } else {
                Text("Para comprobarlo, pulsa «Probar atajo», cambia a otra app (Finder o Safari) y pulsa ⌘⇧5.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(app.testingSelectorShortcut ? LocalizedStringKey("Esperando ⌘⇧5…") : LocalizedStringKey("Probar atajo")) { app.testingSelectorShortcut = true }
                        .disabled(app.testingSelectorShortcut)
                    Button("Restaurar macOS") { restore() }
                }
                if app.selectorShortcutVerified {
                    Label("NativeShot ha recibido ⌘⇧5.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Sustituir el acceso de captura de macOS (⌘⇧5)")
        } footer: {
            Text("NativeShot no cambia los ajustes del sistema. ⇧⌘3 y ⇧⌘4 de Apple no se tocan.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemState = SystemScreenshotShortcutProbe.state()
        }
    }

    @ViewBuilder private var statusText: some View {
        if registered {
            if systemState == .possiblyActive {
                Text("Registrado, pero el atajo de Apple parece seguir activo").foregroundStyle(.orange)
            } else {
                Text("Registrado en NativeShot").foregroundStyle(.green)
            }
        } else {
            switch systemState {
            case .possiblyActive: Text("Atajo del sistema posiblemente activo").foregroundStyle(.orange)
            case .appearsDisabled: Text("Disponible").foregroundStyle(.secondary)
            case .unknown: Text("No se puede determinar").foregroundStyle(.secondary)
            }
        }
    }

    private func activate() {
        systemState = SystemScreenshotShortcutProbe.state()
        do {
            try app.rebind(.selector, to: .commandShift5)
            error = systemState == .possiblyActive
                ? String(localized: "Atajo registrado, pero macOS podría seguir abriendo su propia utilidad. Desactívalo en Ajustes del Sistema y pruébalo.")
                : nil
        } catch {
            // Previous binding stays active (ShortcutRegistry guarantees it); offer the fallback.
            self.error = message(for: error) + " " + String(localized: "El selector sigue disponible con ⌃⌥⌘5.")
        }
    }

    private func restore() {
        try? app.rebind(.selector, to: ShortcutAction.selector.defaultCombo)
        error = String(localized: "⌘⇧5 liberado. Para recuperar la utilidad de Apple, vuelve a activar «Opciones de captura y grabación de pantalla» en Ajustes del Sistema.")
    }
}

/// Click, then press the new combination. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let combo: KeyCombo?
    let onChange: (KeyCombo?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? String(localized: "Pulsa la combinación…") : (combo?.displayString ?? String(localized: "Sin asignar")))
                .monospacedDigit()
                .frame(minWidth: 130)
        }
        .accessibilityHint(Text("Activa para grabar un atajo nuevo"))
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        // Local monitor: only keys typed into this Settings window, never a global key stream.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 53: stop()
            case 51, 117: stop(); onChange(nil)
            default:
                let mods = KeyCombo.carbonModifiers(fromCocoa: e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
                let label = (e.charactersIgnoringModifiers ?? "").uppercased()
                stop()
                onChange(KeyCombo(keyCode: UInt32(e.keyCode), modifiers: mods, keyLabel: label.isEmpty ? "?" : label))
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: UI-18

struct PrivacySettings: View {
    @ObservedObject var app: AppController
    @State private var granted = ScreenCaptureAdapter.hasPermission

    var body: some View {
        Form {
            Section("Permisos") {
                LabeledContent("Grabación de pantalla") {
                    if granted {
                        Label("Concedido", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Conceder…") {
                            granted = ScreenCaptureAdapter.requestPermission()
                            if !granted { ScreenCaptureAdapter.openPrivacySettings() }
                        }
                    }
                }
                LabeledContent("Micrófono") { PermissionBadge(state: .microphone) }
                LabeledContent("Cámara") { PermissionBadge(state: .camera) }
                Text("Necesario para capturar. Tras concederlo, macOS puede pedir reiniciar NativeShot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacidad") {
                Text("NativeShot funciona sin conexión: no hay cuentas, telemetría ni subidas. Las capturas se guardan solo en este Mac.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Mostrar la biblioteca en Finder") { app.openLibraryFolder() }
            }
            URLSchemeSettings()
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = ScreenCaptureAdapter.hasPermission
        }
    }
}

/// UTL: nativeshot:// actions. Off by default; each action must be allowed one by one and still asks for confirmation.
struct URLSchemeSettings: View {
    @AppStorage(Prefs.urlSchemeEnabled) private var enabled = false
    @State private var allowed = AppController.urlAllowlist

    var body: some View {
        Section {
            Toggle("Permitir acciones por URL (nativeshot://)", isOn: $enabled)
            if enabled {
                ForEach(URLSchemeCommand.allCases, id: \.self) { c in
                    Toggle(AppController.title(of: c), isOn: Binding(
                        get: { allowed.contains(c) },
                        set: { on in
                            if on { allowed.insert(c) } else { allowed.remove(c) }
                            AppController.urlAllowlist = allowed
                        }))
                }
            }
        } header: {
            Text("Acciones por URL")
        } footer: {
            Text("Desactivado por defecto. Aunque lo actives, cada petición pide tu confirmación y nunca captura en silencio. Ejemplo: nativeshot://region")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

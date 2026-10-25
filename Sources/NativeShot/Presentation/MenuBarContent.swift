import SwiftUI
import NativeShotKit

/// UI-02: everything is reachable from the menu bar, even before any shortcut works.
struct MenuBarContent: View {
    @ObservedObject var app: AppController
    @ObservedObject var recents: Library

    var body: some View {
        Button { app.perform(.selector) } label: { item("Selector de captura…", .selector) }
        Button { app.perform(.region) } label: { item("Capturar región", .region) }
        Button { app.perform(.window) } label: { item("Capturar ventana", .window) }
        Button { app.perform(.display) } label: { item("Capturar pantalla completa", .display) }
        Button { app.perform(.lastRegion) } label: { item("Repetir última región", .lastRegion) }
        Button("Repetir última captura") { app.repeatCapture() }.disabled(!app.canRepeat)
        Button { app.perform(.scrolling) } label: { item("Captura con scroll", .scrolling) }
        Button { app.perform(.textRecognition) } label: { item("Capturar texto (OCR)", .textRecognition) }
        Button { app.perform(.recordScreen) } label: { item("Grabar pantalla…", .recordScreen) }
        Divider()
        Button { app.perform(.openLibrary) } label: { item("Abrir biblioteca…", .openLibrary) }
        Button("Abrir proyecto .nshot…") { NSApp.activate(); ImageEditorController.openProject() }
        Button("Abrir vídeo en el editor…") { VideoEditorController.openWithPanel(library: recents) }
        Menu("Capturas recientes") {
            if recents.recent.isEmpty {
                Text("Sin capturas")
            }
            ForEach(recents.recent) { a in
                Menu(a.createdAt.formatted(date: .abbreviated, time: .shortened) + "  ·  \(a.width)×\(a.height)") {
                    Button("Copiar") { app.capture(from: a).map(app.copy) }
                    Button("Editar") { app.capture(from: a).map(app.edit) }
                    Button("Fijar") { app.capture(from: a).map(app.pin) }
                    Button("Mostrar en Finder") { app.capture(from: a).map(app.reveal) }
                }
            }
            Divider()
            Button("Abrir carpeta de la biblioteca") { app.openLibraryFolder() }
        }
        Button("Restaurar última miniatura") { app.restoreLastThumbnail() }
        Button("Enfocar última miniatura") { app.focusThumbnail() }
        Button { app.perform(.pinClipboard) } label: { item("Fijar imagen del portapapeles", .pinClipboard) }
        Button { app.perform(.closePins) } label: { item("Cerrar imágenes fijadas", .closePins) }
        Button("Bloquear imágenes fijadas (clics las atraviesan)") { app.setPinsLocked(true) }
        Button("Desbloquear imágenes fijadas") { app.setPinsLocked(false) }
        Divider()
        Toggle(isOn: Binding(get: { app.privateSession }, set: { _ in app.perform(.togglePrivateSession) })) { item("Sesión privada (sin historial)", .togglePrivateSession) }
        Divider()
        Button("Ajustes…") { app.openSettings() } // not SettingsLink: it leaves the window behind the frontmost app
        Button("Buscar actualizaciones…") { app.checkForUpdates() }
        Button("Ayuda y diagnóstico…") { HelpWindow.show(app: app) }
        Button("Salir de NativeShot") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func item(_ title: LocalizedStringKey, _ action: ShortcutAction) -> Text {
        if let combo = app.shortcuts?.bindings[action] {
            return Text(title) + Text("    " + combo.displayString).foregroundColor(.secondary)
        }
        return Text(title)
    }
}

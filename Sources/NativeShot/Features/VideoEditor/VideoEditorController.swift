import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NativeShotKit

/// One editor window per video (UI-11). Opening resolves everything through the library root so a
/// project and its source stay relocatable together.
@MainActor
final class VideoEditorController: NSObject, NSWindowDelegate {
    private static var open: Set<VideoEditorController> = []

    private let model: VideoEditorModel
    private let window: NSWindow

    /// Opens a video that lives in the library; `.nshotvideo` packages are accepted too.
    static func open(url: URL, library: Library) {
        let root = library.root
        Task {
            do {
                let model: VideoEditorModel
                if url.pathExtension.lowercased() == "nshotvideo" {
                    let opened = try await Task.detached { try VideoProjectPackage.read(from: url, libraryRoot: root) }.value
                    model = try await VideoEditorModel.load(source: opened.sourceURL, libraryRoot: root, project: opened.project, projectURL: url)
                } else {
                    let inside = url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/")
                    guard inside else {
                        Toast.show(String(localized: "Solo se pueden editar vídeos de la biblioteca de NativeShot."), symbol: "exclamationmark.triangle")
                        return
                    }
                    // Edits left by a crash or a window closed without saving come back only if the user wants them.
                    let auto = VideoProjectPackage.autosaveURL(libraryRoot: root, source: url)
                    var restored: VideoProject?
                    if FileManager.default.fileExists(atPath: auto.path),
                       let opened = try? await Task.detached(operation: { try VideoProjectPackage.read(from: auto, libraryRoot: root) }).value {
                        if askRestore() { restored = opened.project } else { try? FileManager.default.removeItem(at: auto) }
                    }
                    model = try await VideoEditorModel.load(source: url, libraryRoot: root, project: restored)
                    if restored != nil { model.markRestored() }
                }
                present(model)
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Menu entry: pick an MP4 from the library (or a saved project).
    static func openWithPanel(library: Library) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true // .nshotvideo is a package directory
        panel.allowedContentTypes = [.mpeg4Movie, UTType(filenameExtension: "nshotvideo", conformingTo: .package) ?? .package]
        panel.directoryURL = library.root.appendingPathComponent("originals")
        panel.message = String(localized: "Elige un vídeo de la biblioteca o un proyecto .nshotvideo")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url, library: library)
    }

    private static func askRestore() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Hay una edición autoguardada de este vídeo")
        alert.informativeText = String(localized: "NativeShot guardó automáticamente los cambios de una sesión anterior que no se llegó a guardar. ¿Quieres recuperarlos?")
        alert.addButton(withTitle: String(localized: "Recuperar"))
        alert.addButton(withTitle: String(localized: "Empezar de cero"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func present(_ model: VideoEditorModel) {
        let c = VideoEditorController(model: model)
        open.insert(c)
        NSApp.activate()
        c.window.makeKeyAndOrderFront(nil)
    }

    private init(model: VideoEditorModel) {
        self.model = model
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1180, vf.width * 0.9), height: min(780, vf.height * 0.9)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        model.window = window
        window.title = String(localized: "Editor de vídeo")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.delegate = self
        window.contentView = NSHostingView(rootView: VideoEditorView(model: model))
        window.center()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.isExporting { NSSound.beep(); return false }
        guard model.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "¿Cerrar sin guardar el proyecto?")
        alert.informativeText = String(localized: "Se perderán las ediciones del vídeo. Puedes guardarlas como proyecto .nshotvideo.")
        alert.addButton(withTitle: String(localized: "Cerrar sin guardar"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        model.shutdown()
        Self.open.remove(self)
    }
}

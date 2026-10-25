import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NativeShotKit

/// "Exportar GIF…": FPS and width choices, progress, cancel and a size warning. Sampling runs off the MainActor.
@MainActor
final class GIFExportModel: ObservableObject {
    let video: URL
    @Published var fps = 15
    @Published var maxWidth = 640 // 0 = original size
    @Published private(set) var progress: Double?
    @Published private(set) var message: String?
    @Published private(set) var result: URL?
    private var task: Task<Void, Never>?

    init(video: URL) { self.video = video }

    var isRunning: Bool { progress != nil }

    func start() {
        let save = NSSavePanel()
        save.allowedContentTypes = [.gif]
        save.nameFieldStringValue = video.deletingPathExtension().lastPathComponent + ".gif"
        save.directoryURL = Prefs.saveFolderURL
        guard save.runModal() == .OK, let dest = save.url else { return }
        message = nil; result = nil; progress = 0
        let options = GIFExporter.Options(fps: fps, maxWidth: maxWidth == 0 ? nil : maxWidth)
        let video = video
        task = Task {
            do {
                let r = try await GIFExporter.export(video: video, to: dest, options: options) { [weak self] p in
                    Task { @MainActor in self?.progress = p }
                }
                result = dest
                let mb = Double(r.byteSize) / 1_000_000
                message = r.isLarge
                    ? String(localized: "El GIF pesa \(String(format: "%.0f", mb)) MB. Prueba con menos FPS o una anchura menor.")
                    : String(localized: "GIF guardado (\(String(format: "%.1f", mb)) MB)")
            } catch is CancellationError {
                message = String(localized: "Exportación cancelada")
            } catch {
                message = error.localizedDescription
            }
            progress = nil
        }
    }

    func cancel() { task?.cancel() }
}

struct GIFExportView: View {
    @ObservedObject var model: GIFExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Fotogramas por segundo", selection: $model.fps) {
                ForEach([10, 15, 20], id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Anchura máxima", selection: $model.maxWidth) {
                Text("480 px").tag(480)
                Text("640 px").tag(640)
                Text("800 px").tag(800)
                Text("Original").tag(0)
            }
            if let p = model.progress {
                ProgressView(value: p)
                Button("Cancelar") { model.cancel() }
            } else {
                HStack {
                    Button("Exportar…") { model.start() }.keyboardShortcut(.defaultAction)
                    if let url = model.result {
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(20)
        .frame(width: 340)
    }
}

@MainActor
final class GIFExportPanel: NSPanel {
    private static var open: [GIFExportPanel] = []
    private let model: GIFExportModel

    /// Entry point for any video (just recorded or from the library).
    static func present(video: URL) {
        let p = GIFExportPanel(model: GIFExportModel(video: video))
        open.append(p)
        NSApp.activate()
        p.center()
        p.makeKeyAndOrderFront(nil)
    }

    /// Lets the user pick any video file, starting at the library's originals.
    static func chooseVideo(startingAt root: URL) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        open.directoryURL = root.appendingPathComponent("originals")
        if open.runModal() == .OK, let url = open.url { present(video: url) }
    }

    private init(model: GIFExportModel) {
        self.model = model
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = String(localized: "Exportar GIF")
        level = .floating
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: GIFExportView(model: model))
        contentView = host
        setContentSize(host.fittingSize)
    }

    override func close() {
        model.cancel()
        Self.open.removeAll { $0 === self }
        super.close()
    }
}

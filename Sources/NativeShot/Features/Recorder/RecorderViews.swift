import AppKit
import AVFoundation
import SwiftUI
import NativeShotKit

/// UI-09: source, audio, FPS, cursor and start.
struct RecorderPanelView: View {
    @ObservedObject var controller: RecorderController
    @AppStorage(RecorderPrefs.fps) private var fps = 30
    @AppStorage(RecorderPrefs.systemAudio) private var systemAudio = true
    @AppStorage(RecorderPrefs.microphone) private var microphone = false
    @AppStorage(RecorderPrefs.cursor) private var cursor = true
    @AppStorage(RecorderPrefs.webcam) private var webcam = false
    @AppStorage(RecorderPrefs.clicks) private var clicks = true
    @AppStorage(RecorderPrefs.countdown) private var countdown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Fuente") {
                Text(controller.sourceDescription).foregroundStyle(.secondary)
            }
            HStack {
                Button("Pantalla") { controller.chooseSource(.display) }
                Button("Ventana…") { controller.chooseSource(.window) }
                Button("Región…") { controller.chooseSource(.region) }
            }
            Divider()
            Toggle("Audio del sistema", isOn: $systemAudio)
            Toggle("Micrófono", isOn: $microphone)
            Toggle("Mostrar cursor", isOn: $cursor)
            Toggle("Webcam flotante", isOn: $webcam)
            Toggle("Resaltar clics", isOn: $clicks)
            KeyOverlayToggle()
            Picker("Fotogramas por segundo", selection: $fps) {
                ForEach([15, 24, 30, 60], id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Cuenta atrás", selection: $countdown) {
                Text("Sin").tag(0)
                ForEach([3, 5, 10], id: \.self) { Text("\($0) s").tag($0) }
            }
            .pickerStyle(.segmented)
            Button { controller.start() } label: {
                Label("Iniciar grabación", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            Button("Convertir un vídeo a GIF…") { GIFExportPanel.chooseVideo(startingAt: controller.libraryRoot) }
                .buttonStyle(.link).controlSize(.small)
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// UI-10: always-visible bar with timer, level, pause/resume, stop and cancel.
struct RecordingBarView: View {
    @ObservedObject var controller: RecorderController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let paused = controller.phase == .paused
        let finalizing = controller.phase == .finalizing
        HStack(spacing: 12) {
            Circle().fill(paused || finalizing ? Color.secondary : Color.red).frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(Self.format(controller.elapsed))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .accessibilityLabel(Text("Tiempo grabado"))
                .accessibilityValue(Text(Self.format(controller.elapsed)))
            Capsule().fill(.secondary.opacity(0.35)).frame(width: 48, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(.green).frame(width: 48 * CGFloat(controller.level), height: 6)
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: controller.level)
                }
                .accessibilityHidden(true)
            storageIndicator
            if finalizing {
                ProgressView().controlSize(.small)
            } else {
                if controller.hasWebcam {
                    Button { controller.toggleWebcam() } label: { Image(systemName: controller.webcamVisible ? "video.fill" : "video.slash") }
                        .help(controller.webcamVisible ? "Ocultar webcam" : "Mostrar webcam")
                        .accessibilityLabel(Text(controller.webcamVisible ? "Ocultar webcam" : "Mostrar webcam"))
                }
                Button { controller.togglePause() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                    .help(paused ? "Reanudar" : "Pausar")
                    .accessibilityLabel(Text(paused ? "Reanudar" : "Pausar"))
                Button { controller.stop() } label: { Image(systemName: "stop.fill") }
                    .help("Detener")
                    .accessibilityLabel(Text("Detener"))
                Button { controller.confirmCancel() } label: { Image(systemName: "xmark") }
                    .help("Cancelar grabación")
                    .accessibilityLabel(Text("Cancelar grabación"))
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .panelBackground(Capsule())
        .padding(1)
    }

    /// UI-10 states: normal (free space), almacenamiento bajo (orange) and fallo (red). Fixed width: the panel is sized once.
    private var storageIndicator: some View {
        let failed = controller.failure != nil
        let low = controller.storage != .normal
        let free = controller.freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        return HStack(spacing: 3) {
            Image(systemName: failed ? "exclamationmark.octagon.fill" : (low ? "exclamationmark.triangle.fill" : "internaldrive"))
            Text(failed ? String(localized: "Error") : free).lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.caption)
        .foregroundStyle(failed ? Color.red : (low ? Color.orange : Color.secondary))
        .frame(width: 78, alignment: .leading)
        .help(failed ? Text(controller.failure ?? "") : (low ? Text("Almacenamiento bajo") : Text("Espacio libre en disco")))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(failed ? String(localized: "Error de grabación") : (low ? String(localized: "Almacenamiento bajo") : String(localized: "Espacio libre en disco"))))
        .accessibilityValue(Text(failed ? (controller.failure ?? "") : free))
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Floating result for a finished video (the image thumbnail needs a `Capture`, which a video is not).
@MainActor
final class RecordingResultPanel: NSPanel {
    let url: URL
    private let artifactID: UUID
    private let library: Library
    private let onClose: (RecordingResultPanel) -> Void

    init(url: URL, id: UUID, info: MovieInfo, library: Library, onClose: @escaping (RecordingResultPanel) -> Void) {
        self.url = url; self.artifactID = id; self.library = library; self.onClose = onClose
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView.fixed(RecordingResultView(url: url, info: info,
            edit: { [weak self] in VideoEditorController.open(url: url, library: library); self?.dismiss() },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            copyPath: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) },
            exportGIF: { GIFExportPanel.present(video: url) },
            delete: { [weak self] in self?.deleteVideo() },
            close: { [weak self] in self?.dismiss() }))
        contentView = host
        setContentSize(host.fittingSize)
    }

    func present() {
        if let f = NSScreen.main?.visibleFrame { setFrameOrigin(NSPoint(x: f.maxX - frame.width - 16, y: f.minY + 16)) }
        orderFrontRegardless()
    }

    private func deleteVideo() {
        let lib = library, id = artifactID
        Task { await lib.delete(id: id) }
        dismiss()
    }

    private func dismiss() { orderOut(nil); onClose(self) }
}

struct RecordingResultView: View {
    let url: URL
    let info: MovieInfo
    let edit: () -> Void
    let reveal: () -> Void, copyPath: () -> Void, exportGIF: () -> Void, delete: () -> Void, close: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() } else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 240, height: 135)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            Text("Grabación guardada · \(RecordingBarView.format(info.duration)) · \(info.width)×\(info.height)").font(.caption)
            HStack {
                Button("Editar vídeo", action: edit)
                Button("Mostrar en Finder", action: reveal)
                Button("Copiar ruta", action: copyPath)
                Button("Exportar GIF…", action: exportGIF)
                Button("Eliminar", role: .destructive, action: delete)
                Button { close() } label: { Image(systemName: "xmark") }.accessibilityLabel(Text("Cerrar"))
            }
            .controlSize(.small)
        }
        .padding(12)
        .panelBackground(RoundedRectangle(cornerRadius: 14))
        .padding(1)
        .task {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 270)
            if let cg = try? await gen.image(at: .zero).image { thumbnail = NSImage(cgImage: cg, size: .zero) }
        }
    }
}

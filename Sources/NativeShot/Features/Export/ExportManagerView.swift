import AppKit
import SwiftUI
import NativeShotKit

/// UI-19: export one capture with explicit name, folder, format, quality, scale and metadata choices.
/// Starts from the saved preferences but never writes them back.
@MainActor
enum ExportManager {
    static func show(image: CGImage, sourceApp: String? = nil) {
        ToolWindow.show(title: String(localized: "Exportar captura"), size: NSSize(width: 460, height: 440), resizable: false) {
            ExportManagerView(image: image, sourceApp: sourceApp)
        }
    }
}

struct ExportManagerView: View {
    let image: CGImage
    let sourceApp: String?

    private enum Phase: Equatable { case idle, working, done(URL), failed(String) }

    @State private var folder = Prefs.saveFolderURL
    @State private var template = ExportSettings.policy.template
    @State private var format = UserDefaults.standard.string(forKey: Prefs.exportFormat) ?? "png"
    @State private var quality = UserDefaults.standard.double(forKey: Prefs.jpegQuality)
    @State private var scale = UserDefaults.standard.integer(forKey: Prefs.exportScale) == 1 ? 1 : 2
    @State private var stripMetadata = true
    @State private var phase = Phase.idle

    private var ext: String { format == "jpeg" ? "jpg" : (format == "heic" && ImageExporter.supportsHEIC ? "heic" : "png") }
    private var outputSize: String {
        let f = scale == 1 ? 2 : 1
        return "\(max(1, image.width / f)) × \(max(1, image.height / f)) px"
    }

    var body: some View {
        Form {
            Section("Archivo") {
                TextField("Nombre", text: $template)
                    .accessibilityHint(Text("Variables: {date} {time} {type} {app} {n}"))
                LabeledContent("Vista previa") {
                    Text(FileNamingPolicy(template: template).name(date: Date(), type: "screenshot", app: sourceApp, ext: ext))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                LabeledContent("Destino") {
                    HStack {
                        Text(folder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Elegir…") { chooseFolder() }
                    }
                }
            }
            Section("Imagen") {
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
                LabeledContent("Tamaño final") { Text(outputSize).foregroundStyle(.secondary) }
                Toggle("Quitar metadatos (EXIF y ubicación)", isOn: $stripMetadata)
            }
            Section {
                HStack {
                    status
                    Spacer()
                    if case .done(let url) = phase {
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Exportar") { export() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(phase == .working)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .idle: EmptyView()
        case .working: ProgressView("Exportando…").controlSize(.small)
        case .done(let url):
            Label(String(localized: "Guardada: \(url.lastPathComponent)"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func export() {
        phase = .working
        let fmt: ExportFormat = switch format {
        case "jpeg": .jpeg(quality: quality)
        case "heic" where ImageExporter.supportsHEIC: .heic(quality: quality)
        default: .png
        }
        let request = ExportRequest(folder: folder, template: template, app: sourceApp, format: fmt,
                                    downscale: scale == 1 ? 2 : 1, keepMetadata: !stripMetadata)
        let image = image
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) { try ExportJob.run(image, request) }.value
                phase = .done(url)
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: String(localized: "Captura exportada")])
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

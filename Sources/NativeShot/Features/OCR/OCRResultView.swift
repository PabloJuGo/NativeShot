import AppKit
import SwiftUI
import NativeShotKit

/// UI-07: the captured image with the recognized lines. Pick lines (click a box or a row), choose the
/// language, copy the selection or everything. Codes are listed as text and never opened without a confirmation.
@MainActor
enum OCRWindow {
    static func show(image: CGImage, result: TextRecognizer.Result) {
        ToolWindow.show(title: String(localized: "Texto reconocido"), size: NSSize(width: 860, height: 560)) {
            OCRResultView(image: image, initial: result)
        }
    }
}

struct OCRResultView: View {
    let image: CGImage
    @State var initial: TextRecognizer.Result
    @State private var language = "auto"
    @State private var selection = Set<Int>()
    @State private var running = false
    @State private var failure: String?

    private let languages = TextRecognizer.supportedLanguages

    init(image: CGImage, initial: TextRecognizer.Result) {
        self.image = image
        _initial = State(initialValue: initial)
    }

    var body: some View {
        HSplitView {
            preview.frame(minWidth: 300)
            VStack(spacing: 0) {
                controls.padding(10)
                Divider()
                list
                Divider()
                actions.padding(10)
            }
            .frame(minWidth: 320)
        }
    }

    // MARK: Image with boxes

    private var preview: some View {
        GeometryReader { geo in
            let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
            let fit = min(geo.size.width / aspect, geo.size.height)
            let size = CGSize(width: fit * aspect, height: fit)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                ForEach(Array(initial.blocks.enumerated()), id: \.offset) { i, b in
                    let on = selection.contains(i)
                    Rectangle()
                        .fill(on ? Color.accentColor.opacity(0.35) : Color.yellow.opacity(0.12))
                        .overlay(Rectangle().stroke(on ? Color.accentColor : Color.yellow.opacity(0.6), lineWidth: 1))
                        .frame(width: b.w * size.width, height: b.h * size.height)
                        .offset(x: b.x * size.width, y: (1 - b.y - b.h) * size.height) // Vision's origin is bottom-left
                        .onTapGesture { toggle(i) }
                        .accessibilityElement()
                        .accessibilityLabel(b.text)
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.quaternary.opacity(0.4))
    }

    // MARK: Side panel

    private var controls: some View {
        HStack {
            Picker("Idioma", selection: $language) {
                Text("Automático").tag("auto")
                ForEach(languages, id: \.self) { code in
                    Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                }
            }
            .onChange(of: language) { rerun() }
            .accessibilityLabel("Idioma del reconocimiento")
            if running { ProgressView().controlSize(.small) }
        }
    }

    private var list: some View {
        List(selection: $selection) {
            Section("Texto") {
                if initial.blocks.isEmpty {
                    Text("No se ha encontrado texto").foregroundStyle(.secondary)
                }
                ForEach(Array(initial.blocks.enumerated()), id: \.offset) { i, b in
                    Text(b.text).tag(i)
                }
            }
            if !initial.barcodes.isEmpty {
                Section("Códigos QR y de barras") {
                    ForEach(initial.barcodes, id: \.self) { code in
                        HStack {
                            Text(code).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            if Self.webURL(code) != nil {
                                Button("Abrir…") { open(code) }
                                    .accessibilityLabel("Abrir el enlace \(code)")
                            }
                            Button { copy(code) } label: { Image(systemName: "doc.on.doc") }
                                .help("Copiar")
                                .accessibilityLabel("Copiar el código")
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Líneas reconocidas")
    }

    private var actions: some View {
        HStack {
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            Spacer()
            Button("Copiar selección") { copy(selectedText) }
                .disabled(selection.isEmpty)
            Button("Copiar todo") { copy(initial.text) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(initial.text.isEmpty)
        }
    }

    // MARK: Logic

    private var selectedText: String {
        selection.sorted().compactMap { initial.blocks.indices.contains($0) ? initial.blocks[$0].text : nil }.joined(separator: "\n")
    }

    private func toggle(_ i: Int) {
        if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        Toast.show(String(localized: "Texto copiado (\(s.count) caracteres)"), symbol: "doc.on.clipboard")
    }

    private func rerun() {
        running = true; failure = nil
        let lang = language == "auto" ? nil : [language]
        Task {
            do {
                initial = try await TextRecognizer.recognize(image, languages: lang)
                selection = []
            } catch {
                failure = error.localizedDescription
            }
            running = false
        }
    }

    /// Only web links are offered for opening; other payloads (Wi-Fi, vCard, plain text) stay text.
    static func webURL(_ s: String) -> URL? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return u
    }

    private func open(_ code: String) {
        guard let url = Self.webURL(code) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "¿Abrir este enlace?")
        alert.informativeText = String(localized: "El código apunta a \(url.absoluteString). NativeShot no lo ha visitado; se abrirá en tu navegador.")
        alert.addButton(withTitle: String(localized: "Abrir"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }
}

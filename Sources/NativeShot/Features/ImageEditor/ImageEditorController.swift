import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import NativeShotKit

final class EditorWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyHandler?(event) == true || super.performKeyEquivalent(with: event)
    }
}

/// One editor window per document (IMG). Owns the toolbar and file actions; the canvas and inspector share `EditorState`.
@MainActor
final class ImageEditorController: NSObject, NSToolbarDelegate, NSToolbarItemValidation, NSWindowDelegate {
    private static var open: Set<ImageEditorController> = []

    static func edit(_ image: CGImage) {
        present(EditorDocument(original: image))
    }

    static func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true // .nshot is a package directory
        panel.canChooseFiles = true
        panel.message = String(localized: "Elige un proyecto .nshot")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let doc = try await Task.detached { try NShotPackage.read(from: url) }.value
                present(doc)
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }

    private static func present(_ doc: EditorDocument) {
        let c = ImageEditorController(document: doc)
        open.insert(c)
        NSApp.activate()
        c.window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { c.fit() }
    }

    private let state: EditorState
    private let window: EditorWindow
    private let scroll = NSScrollView()
    private let canvas: CanvasView
    private var toolGroups: [NSToolbarItemGroup] = []
    private var lastSize: CGSize
    private var bag = Set<AnyCancellable>()

    private enum ID {
        static let tools = NSToolbarItem.Identifier("tools")
        static let effects = NSToolbarItem.Identifier("effects")
        static let undo = NSToolbarItem.Identifier("undo")
        static let redo = NSToolbarItem.Identifier("redo")
        static let zoom = NSToolbarItem.Identifier("zoom")
        static let copy = NSToolbarItem.Identifier("copy")
        static let saveAs = NSToolbarItem.Identifier("saveAs")
        static let saveProject = NSToolbarItem.Identifier("saveProject")
    }

    private init(document: EditorDocument) {
        state = EditorState(document: document)
        lastSize = document.imageSize
        canvas = CanvasView(state: state)
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = document.imageSize
        let w = min(max(size.width + 290, 760), vf.width * 0.9)
        let h = min(max(size.height + 40, 520), vf.height * 0.9)
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = String(localized: "Editor de imagen")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 460)
        window.delegate = self
        window.keyHandler = { [weak self] in self?.handleKey($0) ?? false }

        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 16
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let inspector = NSHostingView(rootView: InspectorView(state: state))
        inspector.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(inspector)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: content.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 250),
        ])
        window.contentView = content

        let toolbar = NSToolbar(identifier: "ImageEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()

        state.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                window.toolbar?.validateVisibleItems()
                syncToolSelection()
                window.isDocumentEdited = state.dirty
                if state.document.imageSize != lastSize { lastSize = state.document.imageSize; fit() }
            }
        }.store(in: &bag)
    }

    // MARK: Zoom

    private func fit() {
        let clip = scroll.contentSize, img = state.document.imageSize
        scroll.magnification = max(scroll.minMagnification, min(clip.width / img.width, clip.height / img.height, 1))
    }

    private func syncToolSelection() {
        for g in toolGroups {
            let i = (g.itemIdentifier == ID.tools ? EditorTool.drawing : EditorTool.effects).firstIndex(of: state.tool) ?? -1
            if g.selectedIndex != i { g.selectedIndex = i }
        }
    }

    private func zoom(by f: CGFloat) { scroll.magnification *= f }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.tools, ID.effects, ID.undo, ID.redo, ID.zoom, ID.copy, ID.saveAs, ID.saveProject, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.tools, ID.effects, .space, ID.undo, ID.redo, .space, ID.zoom, .flexibleSpace, ID.copy, ID.saveAs, ID.saveProject]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        switch id {
        case ID.tools, ID.effects:
            let tools = id == ID.tools ? EditorTool.drawing : EditorTool.effects
            let g = NSToolbarItemGroup(itemIdentifier: id, images: tools.map { image($0.symbol, $0.label) },
                                       selectionMode: .selectOne, labels: tools.map(\.label), target: self, action: #selector(toolChosen(_:)))
            g.label = id == ID.tools ? String(localized: "Herramientas") : String(localized: "Efectos")
            g.paletteLabel = g.label
            g.selectedIndex = tools.firstIndex(of: state.tool) ?? -1
            for (item, tool) in zip(g.subitems, tools) {
                item.toolTip = tool.hint
                item.label = tool.label
            }
            toolGroups.removeAll { $0.itemIdentifier == id }
            toolGroups.append(g)
            return g
        case ID.zoom:
            let labels = [String(localized: "Alejar"), String(localized: "Ajustar a la ventana"), String(localized: "Acercar")]
            let g = NSToolbarItemGroup(itemIdentifier: id, images: [image("minus.magnifyingglass", labels[0]), image("arrow.up.left.and.arrow.down.right", labels[1]),
                                                                    image("plus.magnifyingglass", labels[2])],
                                       selectionMode: .momentary, labels: labels, target: self, action: #selector(zoomChosen(_:)))
            g.label = String(localized: "Zoom")
            g.paletteLabel = g.label
            for (item, l) in zip(g.subitems, labels) { item.toolTip = l }
            return g
        case ID.undo: return button(id, String(localized: "Deshacer"), "arrow.uturn.backward", #selector(undo))
        case ID.redo: return button(id, String(localized: "Rehacer"), "arrow.uturn.forward", #selector(redo))
        case ID.copy: return button(id, String(localized: "Copiar"), "doc.on.doc", #selector(copyImage))
        case ID.saveAs: return button(id, String(localized: "Guardar como…"), "square.and.arrow.down", #selector(saveAs))
        case ID.saveProject: return button(id, String(localized: "Guardar proyecto"), "folder.badge.plus", #selector(saveProject))
        default: return nil
        }
    }

    private func image(_ symbol: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = image(symbol, label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ID.undo: state.session.canUndo
        case ID.redo: state.session.canRedo
        default: true
        }
    }

    @objc private func toolChosen(_ sender: NSToolbarItemGroup) {
        let tools = sender.itemIdentifier == ID.tools ? EditorTool.drawing : EditorTool.effects
        if tools.indices.contains(sender.selectedIndex) { state.tool = tools[sender.selectedIndex] }
    }

    @objc private func zoomChosen(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: zoom(by: 0.8)
        case 1: fit()
        default: zoom(by: 1.25)
        }
    }

    // MARK: Keys

    private func handleKey(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.command), !f.contains(.option), let k = e.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = f.contains(.shift)
        switch k {
        case "z": shift ? redo() : undo()
        case "c" where !shift: copyImage()
        case "v" where !shift: pasteImage()
        case "d" where !shift: state.duplicateSelection()
        case "]": state.moveSelectedLayer(by: shift ? 10_000 : 1)
        case "[": state.moveSelectedLayer(by: shift ? -10_000 : -1)
        case "l" where !shift: state.toggleLock()
        case "'": state.showGrid.toggle()
        case "s": shift ? saveAs() : saveProject()
        case "o" where !shift: Self.openProject()
        case "p" where !shift: printImage()
        case "+", "=": zoom(by: 1.25)
        case "-": zoom(by: 0.8)
        case "0": fit()
        default: return false
        }
        return true
    }

    // MARK: Actions

    @objc private func undo() { state.undo() }
    @objc private func redo() { state.redo() }

    private func pasteImage() {
        let pb = NSPasteboard.general
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .prefix(10).compactMap(EditorImageLoader.load)
        if !files.isEmpty {
            files.forEach { state.insertImage($0) }
        } else if let i = NSImage(pasteboard: pb)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            state.insertImage(i)
        } else { NSSound.beep() }
    }

    @objc private func copyImage() {
        let doc = state.document
        Task {
            do {
                let png = try await Task.detached { try ImageExporter.data(for: doc, format: .png) }.value
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
                Toast.show(String(localized: "Imagen copiada"), symbol: "doc.on.clipboard")
            } catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle") }
        }
    }

    /// Prints the flattened result, so redactions are burnt in exactly as on export.
    private func printImage() {
        guard let image = EditorRenderer.render(state.document) else { NSSound.beep(); return }
        PrintAction.print(image)
    }

    private var saveFormat = ExportFormat.writableExtensions[0]

    @objc private func saveAs() {
        let panel = NSSavePanel()
        panel.directoryURL = Prefs.saveFolderURL
        panel.nameFieldStringValue = FileNamingPolicy.default.name(date: Date(), type: "screenshot", ext: saveFormat)
        panel.allowedContentTypes = [UTType(filenameExtension: saveFormat) ?? .png]
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24), pullsDown: false)
        popup.addItems(withTitles: ExportFormat.writableExtensions.map { $0.uppercased() })
        popup.selectItem(withTitle: saveFormat.uppercased())
        popup.setAccessibilityLabel(String(localized: "Formato de exportación"))
        let label = NSTextField(labelWithString: String(localized: "Formato:"))
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        panel.accessoryView = row
        let formatTarget = PopupAction { [weak self, weak panel] in
            guard let self, let panel, let ext = popup.titleOfSelectedItem?.lowercased() else { return }
            saveFormat = ext
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .png]
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + ext
        }
        popup.target = formatTarget
        popup.action = #selector(PopupAction.fire)
        let doc = state.document
        Task {
            defer { withExtendedLifetime(formatTarget) {} }
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            let format = ExportFormat.forExtension(url.pathExtension)
            do {
                try await Task.detached {
                    try ImageExporter.data(for: doc, format: format).write(to: url, options: .atomic)
                }.value
                Toast.show(String(localized: "Guardada en \(url.deletingLastPathComponent().lastPathComponent)"), symbol: "checkmark.circle")
            } catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle") }
        }
    }

    @objc private func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nshot", conformingTo: .package) ?? .package]
        panel.directoryURL = Prefs.saveFolderURL
        panel.nameFieldStringValue = FileNamingPolicy.default.name(date: Date(), type: "project", ext: "nshot")
        panel.message = String(localized: "El proyecto conserva la imagen original sin censurar. Exporta como PNG para compartir.")
        let doc = state.document
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            do {
                try await Task.detached { try NShotPackage.write(doc, to: url) }.value
                state.markSaved()
                Toast.show(String(localized: "Proyecto guardado"), symbol: "checkmark.circle")
            } catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle") }
        }
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard state.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "¿Cerrar sin guardar el proyecto?")
        alert.informativeText = String(localized: "Se perderán las anotaciones. Puedes guardarlas como proyecto .nshot.")
        alert.addButton(withTitle: String(localized: "Cerrar sin guardar"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }
}

/// Target for the save panel's format popup.
final class PopupAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

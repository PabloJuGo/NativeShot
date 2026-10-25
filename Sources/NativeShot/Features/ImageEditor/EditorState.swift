import AppKit
import ImageIO
import NativeShotKit

enum EditorTool: Int, CaseIterable {
    case select, arrow, curvedArrow, doubleArrow, line, rectangle, filledRectangle, ellipse, freehand, highlighter, text, counter, underline, strikethrough
    case spotlight, magnifier, pixelate, blur, redact, crop, eyedropper

    /// The toolbar shows two groups so it stays readable.
    static let drawing: [EditorTool] = [.select, .arrow, .curvedArrow, .doubleArrow, .line, .rectangle, .filledRectangle, .ellipse, .freehand,
                                        .highlighter, .text, .counter, .underline, .strikethrough]
    static let effects: [EditorTool] = [.spotlight, .magnifier, .pixelate, .blur, .redact, .crop, .eyedropper]

    var kind: AnnotationKind? {
        switch self {
        case .select, .crop, .eyedropper: nil
        case .arrow, .curvedArrow, .doubleArrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .filledRectangle: .filledRectangle
        case .ellipse: .ellipse
        case .freehand: .freehand
        case .highlighter: .highlighter
        case .text: .text
        case .counter: .counter
        case .underline: .underline
        case .strikethrough: .strikethrough
        case .spotlight: .spotlight
        case .magnifier: .magnifier
        case .pixelate: .pixelate
        case .blur: .blur
        case .redact: .redact
        }
    }

    /// Tool-specific parameters of a freshly drawn object.
    func configure(_ a: inout Annotation) {
        switch self {
        case .curvedArrow: a.curve = 0.35
        case .doubleArrow: a.headStart = true
        case .spotlight: a.cornerRadius = 12
        default: break
        }
    }

    /// Colour and opacity that make sense for the tool, if it has its own.
    var stylePreset: (color: EditorColor, opacity: Double)? {
        switch self {
        case .highlighter: (.yellow, 0.5)
        case .spotlight: (.black, 0.55)
        default: nil
        }
    }

    /// Plain letter (no modifiers) that selects the tool while the canvas has focus.
    var shortcut: String? {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .curvedArrow: "q"
        case .doubleArrow: "d"
        case .line: "l"
        case .rectangle: "r"
        case .filledRectangle: "g"
        case .ellipse: "e"
        case .freehand: "p"
        case .highlighter: "h"
        case .text: "t"
        case .counter: "n"
        case .underline: "u"
        case .strikethrough: "k"
        case .spotlight: "f"
        case .magnifier: "m"
        case .pixelate: "z"
        case .blur: "b"
        case .redact: "x"
        case .crop: "c"
        case .eyedropper: "i"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .curvedArrow: "arrow.turn.up.right"
        case .doubleArrow: "arrow.left.and.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .filledRectangle: "rectangle.fill"
        case .ellipse: "circle"
        case .freehand: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .spotlight: "flashlight.on.fill"
        case .magnifier: "magnifyingglass"
        case .pixelate: "squareshape.split.2x2"
        case .blur: "drop"
        case .redact: "eye.slash"
        case .crop: "crop"
        case .eyedropper: "eyedropper"
        }
    }

    var label: String {
        switch self {
        case .select: String(localized: "Seleccionar")
        case .arrow: String(localized: "Flecha")
        case .curvedArrow: String(localized: "Flecha curva")
        case .doubleArrow: String(localized: "Flecha bidireccional")
        case .line: String(localized: "Línea")
        case .rectangle: String(localized: "Rectángulo")
        case .filledRectangle: String(localized: "Rectángulo relleno")
        case .ellipse: String(localized: "Elipse")
        case .freehand: String(localized: "Mano alzada")
        case .highlighter: String(localized: "Resaltador")
        case .text: String(localized: "Texto")
        case .counter: String(localized: "Numeración")
        case .underline: String(localized: "Subrayado")
        case .strikethrough: String(localized: "Tachado")
        case .spotlight: String(localized: "Foco")
        case .magnifier: String(localized: "Lupa")
        case .pixelate: String(localized: "Pixelar")
        case .blur: String(localized: "Desenfocar")
        case .redact: String(localized: "Censurar con bloque")
        case .crop: String(localized: "Recortar")
        case .eyedropper: String(localized: "Cuentagotas")
        }
    }

    /// Label with the key hint, for tooltips.
    var hint: String { shortcut.map { "\(label) (\($0.uppercased()))" } ?? label }
}

/// Reads a local picture for pasting or as backdrop, refusing absurd sizes before decoding.
enum EditorImageLoader {
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) >= 1,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w >= 1, h >= 1, w <= 16_384, h <= 16_384 else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// Editor document plus everything the canvas and inspector share. Heavy rendering runs off the main
/// thread; only the latest requested frame is kept.
@MainActor
final class EditorState: ObservableObject {
    @Published private(set) var session: EditorSession
    @Published var tool: EditorTool = .select { didSet { toolChanged(from: oldValue) } }
    /// Style for new objects; edits also apply to the selected object.
    @Published private(set) var style = AnnotationStyle()
    @Published var selection: UUID? { didSet { if selection == nil { extraSelection = [] } } }
    /// Shift-click additions, used by align, distribute, lock, delete.
    @Published var extraSelection: Set<UUID> = []
    @Published private(set) var draft: Annotation?
    @Published private(set) var draftCrop: CGRect?
    @Published private(set) var rendered: CGImage?
    @Published private(set) var dirty = false
    @Published var showGrid = false
    @Published var snapToGrid = false

    static let gridSize = 16.0

    let stylePresets = PresetStore<AnnotationStyle>(key: "editor.stylePresets")
    let backdropPresets = PresetStore<BackdropStyle>(key: "editor.backdropPresets")

    private var rendering = false
    private var renderAgain = false
    private var coalesceKey: UUID?

    init(document: EditorDocument) {
        session = EditorSession(document: document)
        scheduleRender()
    }

    var document: EditorDocument { session.document }

    var displayDocument: EditorDocument {
        var d = session.document
        if let dr = draft {
            if let i = d.objects.firstIndex(where: { $0.id == dr.id }) { d.objects[i] = dr } else { d.objects.append(dr) }
        }
        return d
    }

    var selected: Annotation? {
        guard let id = selection else { return nil }
        return draft?.id == id ? draft : session.document.objects.first { $0.id == id }
    }

    var allSelected: Set<UUID> { selection.map { extraSelection.union([$0]) } ?? [] }

    var effectiveStyle: AnnotationStyle { selected?.style ?? style }

    // MARK: Mutations

    func perform(_ c: EditorCommand, coalescing: Bool = false) {
        session.perform(c, coalescing: coalescing)
        afterChange()
    }

    func undo() { session.undo(); coalesceKey = nil; afterChange(); dropStaleSelection() }
    func redo() { session.redo(); coalesceKey = nil; afterChange(); dropStaleSelection() }

    func add(_ a: Annotation) {
        coalesceKey = nil
        perform(.insert(a, at: session.document.objects.count))
        selection = a.id
    }

    func deleteSelection() {
        let ids = allSelected
        guard !ids.isEmpty else { return }
        coalesceKey = nil
        session.delete(ids: ids) // locked objects survive
        afterChange()
        dropStaleSelection()
    }

    func moveSelectedLayer(by n: Int) {
        guard let id = selection else { return }
        coalesceKey = nil
        session.moveLayer(id: id, by: n)
        afterChange()
    }

    func duplicateSelection() {
        guard let id = selection else { return }
        coalesceKey = nil
        if let copy = session.duplicate(id: id) { selection = copy.id; afterChange() }
    }

    func toggleLock() {
        guard let s = selected else { return }
        coalesceKey = nil
        session.setLocked(!s.locked, ids: allSelected)
        afterChange()
    }

    func align(_ edge: AlignEdge) { coalesceKey = nil; session.align(ids: allSelected, edge); afterChange() }
    func distribute(_ axis: DistributeAxis) { coalesceKey = nil; session.distribute(ids: allSelected, axis); afterChange() }

    func replace(_ old: Annotation, with new: Annotation) {
        coalesceKey = nil
        perform(.replace(old: old, new: new))
    }

    func setDraft(_ a: Annotation?) { draft = a; scheduleRender() }
    func setDraftCrop(_ r: CGRect?) { draftCrop = r }

    func setCrop(_ r: CGRect?) {
        coalesceKey = nil
        perform(.setCrop(old: session.document.crop, new: r))
    }

    func setBackground(_ b: BackdropStyle?) {
        let old = session.document.background
        perform(.setBackground(old: old, new: b), coalescing: true)
    }

    func setBorder(_ b: ImageBorder?) {
        perform(.setBorder(old: session.document.border, new: b), coalescing: true)
    }

    func setBackgroundImage(_ image: CGImage?) {
        var bg = session.document.background ?? BackdropStyle()
        bg.imageID = image.map { session.register($0) }
        coalesceKey = nil
        perform(.setBackground(old: session.document.background, new: bg))
    }

    func insertImage(_ image: CGImage, center: CGPoint? = nil) {
        coalesceKey = nil
        tool = .select
        let a = session.addImage(image, center: center)
        selection = a.id
        afterChange()
    }

    /// Rotate / flip / resize; returns false when the size is not allowed.
    @discardableResult
    func apply(_ op: GeometryOp) -> Bool {
        coalesceKey = nil
        selection = nil
        guard session.apply(op) else { return false }
        afterChange()
        return true
    }

    func updateStyle(_ edit: (inout AnnotationStyle) -> Void) {
        edit(&style)
        guard let sel = selected, !sel.locked else { return }
        var n = sel
        edit(&n.style)
        perform(.replace(old: sel, new: n), coalescing: coalesceKey == sel.id)
        coalesceKey = sel.id
    }

    /// Per-object parameters (heads, curve, corners, shadow, zoom) of the selection.
    func updateObject(_ edit: (inout Annotation) -> Void) {
        guard let sel = selected, !sel.locked else { return }
        var n = sel
        edit(&n)
        perform(.replace(old: sel, new: n), coalescing: coalesceKey == sel.id)
        coalesceKey = sel.id
    }

    /// Eyedropper: takes the colour under `p` from the image as it looks now.
    func pickColor(at p: CGPoint) {
        let img = rendered ?? session.document.original
        guard let c = ImageSampler.color(in: img, at: p), c.a > 0 else { return }
        updateStyle { $0.color = EditorColor(c.r, c.g, c.b) }
    }

    func markSaved() { dirty = false }

    func refreshPresets() { objectWillChange.send() }

    // MARK: Internals

    private func toolChanged(from old: EditorTool) {
        if tool != .eyedropper { selection = nil } // the eyedropper recolours the current selection
        if let p = tool.stylePreset { style.color = p.color; style.opacity = p.opacity }
        else if old.stylePreset != nil { style.color = .red; style.opacity = 1 }
    }

    private func dropStaleSelection() {
        if let id = selection, !session.document.objects.contains(where: { $0.id == id }) { selection = nil }
        extraSelection = extraSelection.filter { id in session.document.objects.contains { $0.id == id } }
    }

    private func afterChange() {
        dirty = true
        scheduleRender()
    }

    private func scheduleRender() {
        guard !rendering else { renderAgain = true; return }
        rendering = true
        let doc = displayDocument
        Task { [weak self] in
            let img = await Task.detached(priority: .userInitiated) { EditorRenderer.render(doc, applyCrop: false, applyBackground: false) }.value
            guard let self else { return }
            rendered = img
            rendering = false
            if renderAgain { renderAgain = false; scheduleRender() }
        }
    }
}

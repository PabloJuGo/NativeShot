import AppKit
import Combine
import NativeShotKit

/// Keeps a document smaller than the viewport centred while zooming out.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        if doc.frame.width < r.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if doc.frame.height < r.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

/// Image-pixel coordinate space (flipped, 1 unit = 1 image pixel); zoom and pan come from the enclosing scroll view.
final class CanvasView: NSView {
    private let state: EditorState
    private var bag = Set<AnyCancellable>()

    private enum Drag {
        case create
        case move(orig: Annotation, from: CGPoint)
        case handle(orig: Annotation, movesStart: Bool)
        case crop(origin: CGPoint)
    }
    private var drag: Drag?

    init(state: EditorState) {
        self.state = state
        let size = state.document.imageSize
        super.init(frame: NSRect(origin: .zero, size: size))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Lienzo de edición de la captura"))
        setAccessibilityHelp(String(localized: "Elige una herramienta en la barra y arrastra para anotar. Suprimir borra el objeto seleccionado."))
        registerForDraggedTypes([.fileURL, .png, .tiff])
        state.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if frame.size != state.document.imageSize { setFrameSize(state.document.imageSize) }
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
                setAccessibilityValue(String(localized: "\(state.document.objects.count) anotaciones"))
            }
        }.store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: state.tool == .select ? .arrow : .crosshair)
    }

    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let hasRedaction = state.document.objects.contains { $0.kind.isRedaction }
        guard let img = state.rendered ?? (hasRedaction ? nil : state.document.original) else {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            return
        }
        NSImage(cgImage: img, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                                                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let px = 1 / zoom
        if state.showGrid, EditorState.gridSize * zoom >= 4 {
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            cg.setLineWidth(px)
            let g = EditorState.gridSize
            var x = g
            while x < bounds.width { cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: bounds.height)); x += g }
            var y = g
            while y < bounds.height { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: bounds.width, y: y)); y += g }
            cg.strokePath()
        }
        if let crop = state.draftCrop ?? state.document.crop {
            cg.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            cg.addRect(bounds); cg.addRect(crop)
            cg.fillPath(using: .evenOdd)
            cg.setStrokeColor(NSColor.white.cgColor)
            cg.setLineWidth(px * 1.5)
            cg.stroke(crop)
        }
        for id in state.extraSelection {
            guard let o = state.document.objects.first(where: { $0.id == id }) else { continue }
            cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
            cg.setLineWidth(px * 1.5)
            cg.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
            cg.stroke(o.bounds.insetBy(dx: -2 * px, dy: -2 * px))
            cg.setLineDash(phase: 0, lengths: [])
        }
        if let s = state.selected {
            cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
            cg.setLineWidth(px * 1.5)
            cg.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
            cg.stroke(s.bounds.insetBy(dx: -2 * px, dy: -2 * px))
            cg.setLineDash(phase: 0, lengths: [])
            if hasHandles(s), !s.locked {
                for p in [s.start, s.end] {
                    let r = CGRect(x: p.x - 4 * px, y: p.y - 4 * px, width: 8 * px, height: 8 * px)
                    cg.setFillColor(NSColor.white.cgColor); cg.fill(r)
                    cg.stroke(r)
                }
            }
        }
    }

    private func hasHandles(_ a: Annotation) -> Bool {
        switch a.kind {
        case .freehand, .highlighter, .text, .counter, .magnifier: false
        default: true
        }
    }

    // MARK: Mouse

    private func point(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return state.snapToGrid ? EditorLayout.snap(p, grid: EditorState.gridSize) : p
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        switch state.tool {
        case .select:
            if let s = state.selected, hasHandles(s), !s.locked {
                let r = 8 / zoom
                if hypot(s.start.x - p.x, s.start.y - p.y) <= r { drag = .handle(orig: s, movesStart: true); return }
                if hypot(s.end.x - p.x, s.end.y - p.y) <= r { drag = .handle(orig: s, movesStart: false); return }
            }
            let tol = 4 / zoom
            if let hit = state.document.objects.last(where: { $0.hit(p, tolerance: tol) }) {
                if event.modifierFlags.contains(.shift), let current = state.selection {
                    if hit.id == current { return }
                    if state.extraSelection.contains(hit.id) { state.extraSelection.remove(hit.id) } else { state.extraSelection.insert(hit.id) }
                    return
                }
                state.selection = hit.id
                if event.clickCount == 2, hit.kind == .text { editText(hit) } else if !hit.locked { drag = .move(orig: hit, from: p) }
            } else {
                state.selection = nil
            }
        case .eyedropper:
            state.pickColor(at: p)
            state.tool = .select
        case .crop:
            drag = .crop(origin: p)
            state.setDraftCrop(CGRect(origin: p, size: .zero))
        case .text:
            promptText(initial: "") { [self] text in
                guard !text.isEmpty else { return }
                state.add(Annotation(kind: .text, start: p, end: p, text: text, style: state.style))
            }
        case .counter:
            state.add(Annotation(kind: .counter, start: p, end: p, number: state.document.nextCounterNumber, style: state.style))
        default:
            guard let kind = state.tool.kind else { return }
            var a = Annotation(kind: kind, start: p, end: p, points: [p], style: state.style)
            state.tool.configure(&a)
            state.setDraft(a)
            drag = .create
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .create:
            guard var a = state.draft else { return }
            a.end = p
            if a.kind == .freehand || a.kind == .highlighter { a.points.append(p) }
            state.setDraft(a)
        case .move(let orig, let from):
            state.setDraft(orig.translated(by: CGSize(width: p.x - from.x, height: p.y - from.y)))
        case .handle(let orig, let movesStart):
            var a = orig
            if movesStart { a.start = p } else { a.end = p }
            state.setDraft(a)
        case .crop(let origin):
            state.setDraftCrop(CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y), width: abs(p.x - origin.x), height: abs(p.y - origin.y))
                .intersection(bounds))
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        switch drag {
        case .create:
            guard let a = state.draft else { return }
            state.setDraft(nil)
            let tiny = a.bounds.width < 3 && a.bounds.height < 3
            if !tiny { state.add(a) }
        case .move(let orig, _), .handle(let orig, _):
            guard let a = state.draft else { return }
            state.setDraft(nil)
            if a != orig { state.replace(orig, with: a) }
        case .crop:
            if let r = state.draftCrop, r.width >= 4, r.height >= 4 { state.setCrop(r.integral) }
            state.setDraftCrop(nil)
            state.tool = .select
        case nil: break
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: state.deleteSelection() // delete, forward delete
        case 53: // escape
            drag = nil
            state.setDraft(nil); state.setDraftCrop(nil)
            state.selection = nil
            state.tool = .select
        default:
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            if mods.isEmpty, let k = event.charactersIgnoringModifiers?.lowercased(), let t = EditorTool.allCases.first(where: { $0.shortcut == k }) {
                state.tool = t
            } else { super.keyDown(with: event) }
        }
    }

    // MARK: Drag & drop of pictures

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { pictures(from: sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let imgs = pictures(from: sender)
        let at = convert(sender.draggingLocation, from: nil)
        for i in imgs { state.insertImage(i, center: at) }
        return !imgs.isEmpty
    }

    private func pictures(from info: NSDraggingInfo) -> [CGImage] {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let imgs = urls.prefix(10).compactMap(EditorImageLoader.load)
            if !imgs.isEmpty { return imgs }
        }
        return (NSImage(pasteboard: pb)?.cgImage(forProposedRect: nil, context: nil, hints: nil)).map { [$0] } ?? []
    }

    // MARK: Text entry

    private func editText(_ a: Annotation) {
        promptText(initial: a.text) { [self] text in
            guard !text.isEmpty, text != a.text else { return }
            var n = a
            n.text = text
            state.replace(a, with: n)
        }
    }

    // shortcut: text is typed in a sheet, not in place on the canvas; upgrade to an inline NSTextView overlay.
    private func promptText(initial: String, done: @escaping @MainActor (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Texto")
        alert.addButton(withTitle: String(localized: "Aceptar"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityLabel(String(localized: "Texto de la anotación"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let text = field.stringValue
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { done(text) } }
        }
    }
}

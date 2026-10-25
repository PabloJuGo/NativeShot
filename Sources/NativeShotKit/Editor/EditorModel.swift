import CoreGraphics
import Foundation

public struct EditorColor: Codable, Sendable, Equatable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
    public static let red = EditorColor(1, 0.23, 0.19)
    public static let black = EditorColor(0, 0, 0)
    public static let white = EditorColor(1, 1, 1)
    public static let yellow = EditorColor(1, 0.85, 0)
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
}

public struct AnnotationStyle: Codable, Sendable, Equatable {
    public var color: EditorColor
    public var width: Double
    public var opacity: Double
    public init(color: EditorColor = .red, width: Double = 4, opacity: Double = 1) {
        (self.color, self.width, self.opacity) = (color, width, opacity)
    }
}

public enum AnnotationKind: String, Codable, Sendable, CaseIterable {
    case arrow, line, rectangle, filledRectangle, ellipse, freehand, highlighter, text, counter
    case pixelate, blur, redact
    /// Added in format v2.
    case underline, strikethrough, spotlight, magnifier, image

    /// Kinds that rewrite bitmap pixels instead of drawing vectors (irreversible redaction).
    public var isRedaction: Bool { self == .pixelate || self == .blur || self == .redact }
}

/// Coordinates are image pixels, origin top-left, in the space of the original image (before crop).
public struct Annotation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: AnnotationKind
    public var start: CGPoint
    public var end: CGPoint
    /// Freehand and highlighter strokes.
    public var points: [CGPoint]
    public var text: String
    public var number: Int
    public var style: AnnotationStyle
    /// Arrow heads (a double-headed arrow has both).
    public var headStart = false
    public var headEnd = true
    /// Arrow bend as a fraction of its length (0 = straight, sign picks the side).
    public var curve = 0.0
    public var cornerRadius = 0.0
    public var shadow = false
    public var locked = false
    /// Key into `EditorDocument.images` for `.image` objects.
    public var imageID: UUID?
    /// Magnifier zoom factor.
    public var magnification = 2.0

    public init(id: UUID = UUID(), kind: AnnotationKind, start: CGPoint, end: CGPoint, points: [CGPoint] = [],
                text: String = "", number: Int = 0, style: AnnotationStyle = .init()) {
        (self.id, self.kind, self.start, self.end, self.points, self.text, self.number, self.style) =
            (id, kind, start, end, points, text, number, style)
    }

    // Files written before format v2 lack the newer keys: decode them with defaults.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(AnnotationKind.self, forKey: .kind)
        start = try c.decode(CGPoint.self, forKey: .start)
        end = try c.decode(CGPoint.self, forKey: .end)
        points = try c.decode([CGPoint].self, forKey: .points)
        text = try c.decode(String.self, forKey: .text)
        number = try c.decode(Int.self, forKey: .number)
        style = try c.decode(AnnotationStyle.self, forKey: .style)
        headStart = try c.decodeIfPresent(Bool.self, forKey: .headStart) ?? false
        headEnd = try c.decodeIfPresent(Bool.self, forKey: .headEnd) ?? true
        curve = try c.decodeIfPresent(Double.self, forKey: .curve) ?? 0
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        imageID = try c.decodeIfPresent(UUID.self, forKey: .imageID)
        magnification = try c.decodeIfPresent(Double.self, forKey: .magnification) ?? 2
    }

    /// Quadratic control point of a (possibly straight) arrow.
    var controlPoint: CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        return CGPoint(x: (start.x + end.x) / 2 - dy * curve, y: (start.y + end.y) / 2 + dx * curve)
    }

    func curvePoint(_ t: Double) -> CGPoint {
        let c = controlPoint, u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * c.x + t * t * end.x, y: u * u * start.y + 2 * u * t * c.y + t * t * end.y)
    }

    public var fontSize: Double { max(10, style.width * 6) }
    public var counterRadius: Double { 10 + style.width * 2 }
    var highlighterWidth: Double { kind == .highlighter ? max(14, style.width * 3) : 0 }

    public var bounds: CGRect {
        switch kind {
        case .freehand, .highlighter:
            let pts = points.isEmpty ? [start, end] : points
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let w = max(style.width, highlighterWidth) / 2
            return CGRect(x: xs.min()! - w, y: ys.min()! - w, width: xs.max()! - xs.min()! + 2 * w, height: ys.max()! - ys.min()! + 2 * w)
        case .text:
            return CGRect(origin: start, size: TextLayout.size(text, fontSize: fontSize))
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: 2 * r, height: 2 * r)
        case .arrow where curve != 0:
            let m = curvePoint(0.5)
            let xs = [start.x, end.x, m.x], ys = [start.y, end.y, m.y]
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        default:
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
    }

    public func translated(by d: CGSize) -> Annotation {
        var a = self
        a.start.x += d.width; a.start.y += d.height
        a.end.x += d.width; a.end.y += d.height
        a.points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        return a
    }

    public func hit(_ p: CGPoint, tolerance: Double) -> Bool {
        switch kind {
        case .arrow where curve != 0:
            let pts = (0...24).map { curvePoint(Double($0) / 24) }
            return zip(pts, pts.dropFirst()).contains { Self.distance(p, toSegment: $0, $1) <= style.width / 2 + tolerance }
        case .arrow, .line:
            return Self.distance(p, toSegment: start, end) <= style.width / 2 + tolerance
        case .freehand, .highlighter:
            let pts = points.isEmpty ? [start, end] : points
            let r = max(style.width, highlighterWidth) / 2 + tolerance
            return pts.contains { hypot($0.x - p.x, $0.y - p.y) <= r }
                || zip(pts, pts.dropFirst()).contains { Self.distance(p, toSegment: $0, $1) <= r }
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

public enum BackdropPattern: String, Codable, Sendable, CaseIterable { case dots, grid, stripes }

/// Output aspect ratios for social/document export; the capture stays centred and the backdrop grows.
public enum BackdropAspect: String, Codable, Sendable, CaseIterable {
    case square, r4x3, r3x2, r16x9, r9x16, r4x5, a4
    public var ratio: Double {
        switch self {
        case .square: 1
        case .r4x3: 4.0 / 3
        case .r3x2: 3.0 / 2
        case .r16x9: 16.0 / 9
        case .r9x16: 9.0 / 16
        case .r4x5: 4.0 / 5
        case .a4: 210.0 / 297
        }
    }
    public var label: String {
        switch self {
        case .square: "1:1"
        case .r4x3: "4:3"
        case .r3x2: "3:2"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        case .r4x5: "4:5"
        case .a4: "A4"
        }
    }
}

public struct BackdropStyle: Codable, Sendable, Equatable {
    public var padding: Double
    public var color: EditorColor
    /// When set, the fill is a diagonal gradient from `color` to this one.
    public var gradientEnd: EditorColor?
    public var cornerRadius: Double
    public var shadow: Bool
    public var pattern: BackdropPattern?
    public var aspect: BackdropAspect?
    /// Local image used as the backdrop (key into `EditorDocument.images`), drawn aspect-fill.
    public var imageID: UUID?
    /// Ignores `padding` and uses a margin proportional to the capture size.
    public var autoBalance = false
    public init(padding: Double = 64, color: EditorColor = EditorColor(0.35, 0.45, 0.95), gradientEnd: EditorColor? = EditorColor(0.65, 0.35, 0.9),
                cornerRadius: Double = 12, shadow: Bool = true) {
        (self.padding, self.color, self.gradientEnd, self.cornerRadius, self.shadow) = (padding, color, gradientEnd, cornerRadius, shadow)
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        padding = try c.decode(Double.self, forKey: .padding)
        color = try c.decode(EditorColor.self, forKey: .color)
        gradientEnd = try c.decodeIfPresent(EditorColor.self, forKey: .gradientEnd)
        cornerRadius = try c.decode(Double.self, forKey: .cornerRadius)
        shadow = try c.decode(Bool.self, forKey: .shadow)
        pattern = try c.decodeIfPresent(BackdropPattern.self, forKey: .pattern)
        aspect = try c.decodeIfPresent(BackdropAspect.self, forKey: .aspect)
        imageID = try c.decodeIfPresent(UUID.self, forKey: .imageID)
        autoBalance = try c.decodeIfPresent(Bool.self, forKey: .autoBalance) ?? false
    }
}

/// Frame drawn just inside the edge of the (cropped) capture.
public struct ImageBorder: Codable, Sendable, Equatable {
    public var width: Double
    public var color: EditorColor
    public init(width: Double = 4, color: EditorColor = .black) { (self.width, self.color) = (width, color) }
}

/// Everything a geometry operation (rotate, flip, resize) rewrites together, so one command can undo it.
public struct BaseSnapshot: Sendable {
    public var original: CGImage
    public var objects: [Annotation]
    public var crop: CGRect?
    public var images: [UUID: CGImage]
}

public struct EditorDocument: Sendable {
    public var original: CGImage
    public var objects: [Annotation] = []
    /// In original-image pixels; nil means no crop.
    public var crop: CGRect?
    public var background: BackdropStyle?
    public var border: ImageBorder?
    /// Pasted/dropped pictures and backdrop images. Entries are never removed on undo; saving writes only referenced ones.
    public var images: [UUID: CGImage] = [:]

    public init(original: CGImage) { self.original = original }

    public var imageSize: CGSize { CGSize(width: original.width, height: original.height) }
    public var nextCounterNumber: Int { (objects.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1 }

    public var base: BaseSnapshot {
        get { BaseSnapshot(original: original, objects: objects, crop: crop, images: images) }
        set { (original, objects, crop, images) = (newValue.original, newValue.objects, newValue.crop, newValue.images) }
    }

    /// Image keys still in use, so saving doesn't write orphans.
    public var referencedImageIDs: Set<UUID> {
        Set(objects.compactMap(\.imageID) + [background?.imageID].compactMap { $0 })
    }
}

// MARK: Commands

public enum EditorCommand: Sendable {
    case insert(Annotation, at: Int)
    case remove(Annotation, at: Int)
    case replace(old: Annotation, new: Annotation)
    case reorder(id: UUID, from: Int, to: Int)
    case setCrop(old: CGRect?, new: CGRect?)
    case setBackground(old: BackdropStyle?, new: BackdropStyle?)
    case setBorder(old: ImageBorder?, new: ImageBorder?)
    case setBase(old: BaseSnapshot, new: BaseSnapshot)
    case batch([EditorCommand])

    var inverse: EditorCommand {
        switch self {
        case .insert(let a, let i): .remove(a, at: i)
        case .remove(let a, let i): .insert(a, at: i)
        case .replace(let o, let n): .replace(old: n, new: o)
        case .reorder(let id, let f, let t): .reorder(id: id, from: t, to: f)
        case .setCrop(let o, let n): .setCrop(old: n, new: o)
        case .setBackground(let o, let n): .setBackground(old: n, new: o)
        case .setBorder(let o, let n): .setBorder(old: n, new: o)
        case .setBase(let o, let n): .setBase(old: n, new: o)
        case .batch(let cs): .batch(cs.reversed().map(\.inverse))
        }
    }

    func apply(to doc: inout EditorDocument) {
        switch self {
        case .insert(let a, let i): doc.objects.insert(a, at: min(max(i, 0), doc.objects.count))
        case .remove(let a, _): doc.objects.removeAll { $0.id == a.id }
        case .replace(_, let n): if let i = doc.objects.firstIndex(where: { $0.id == n.id }) { doc.objects[i] = n }
        case .reorder(let id, let f, let t):
            guard doc.objects.indices.contains(f), doc.objects[f].id == id else { return }
            let a = doc.objects.remove(at: f)
            doc.objects.insert(a, at: min(max(t, 0), doc.objects.count))
        case .setCrop(_, let n): doc.crop = n
        case .setBackground(_, let n): doc.background = n
        case .setBorder(_, let n): doc.border = n
        case .setBase(_, let n): doc.base = n
        case .batch(let cs): cs.forEach { $0.apply(to: &doc) }
        }
    }
}

/// Document plus a bounded command history.
public struct EditorSession: Sendable {
    public private(set) var document: EditorDocument
    private var undoStack: [EditorCommand] = []
    private var redoStack: [EditorCommand] = []
    public var historyLimit = 500

    public init(document: EditorDocument) { self.document = document }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// `coalescing` merges consecutive edits of the same object (colour-picker drags, sliders) into one undo step.
    public mutating func perform(_ c: EditorCommand, coalescing: Bool = false) {
        c.apply(to: &document)
        redoStack.removeAll()
        if coalescing, let last = undoStack.last {
            switch (last, c) {
            case (.replace(let o, let n), .replace(_, let n2)) where n.id == n2.id:
                undoStack[undoStack.count - 1] = .replace(old: o, new: n2); return
            case (.setBackground(let o, _), .setBackground(_, let n2)):
                undoStack[undoStack.count - 1] = .setBackground(old: o, new: n2); return
            case (.setBorder(let o, _), .setBorder(_, let n2)):
                undoStack[undoStack.count - 1] = .setBorder(old: o, new: n2); return
            default: break
            }
        }
        undoStack.append(c)
        if undoStack.count > historyLimit { undoStack.removeFirst() }
    }

    public mutating func undo() {
        guard let c = undoStack.popLast() else { return }
        c.inverse.apply(to: &document)
        redoStack.append(c)
    }

    public mutating func redo() {
        guard let c = redoStack.popLast() else { return }
        c.apply(to: &document)
        undoStack.append(c)
    }

    public mutating func add(_ a: Annotation) { perform(.insert(a, at: document.objects.count)) }

    public mutating func delete(ids: Set<UUID>) {
        let cmds = document.objects.enumerated().filter { ids.contains($0.element.id) && !$0.element.locked }
            .reversed().map { EditorCommand.remove($0.element, at: $0.offset) }
        if !cmds.isEmpty { perform(.batch(cmds)) }
    }

    /// Registers a picture (pasted, dropped, backdrop) and returns its key. Not part of undo history on purpose.
    public mutating func register(_ image: CGImage) -> UUID {
        let id = UUID()
        document.images[id] = image
        return id
    }

    /// Inserts a picture as an object, scaled down to fit `maxFraction` of the canvas and centred at `center`.
    @discardableResult
    public mutating func addImage(_ image: CGImage, center: CGPoint? = nil, maxFraction: Double = 0.6) -> Annotation {
        let id = register(image)
        let canvas = document.imageSize
        let scale = min(1, maxFraction * canvas.width / Double(image.width), maxFraction * canvas.height / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        let c = center ?? CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        var a = Annotation(kind: .image, start: CGPoint(x: c.x - w / 2, y: c.y - h / 2), end: CGPoint(x: c.x + w / 2, y: c.y + h / 2))
        a.imageID = id
        add(a)
        return a
    }

    /// Copy offset by `offset` pixels, placed right above the original.
    @discardableResult
    public mutating func duplicate(id: UUID, offset: Double = 16) -> Annotation? {
        guard let i = document.objects.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = document.objects[i].translated(by: CGSize(width: offset, height: offset))
        copy.id = UUID()
        copy.locked = false
        perform(.insert(copy, at: i + 1))
        return copy
    }

    public mutating func setLocked(_ locked: Bool, ids: Set<UUID>) {
        let cmds = document.objects.filter { ids.contains($0.id) && $0.locked != locked }.map { o -> EditorCommand in
            var n = o; n.locked = locked
            return .replace(old: o, new: n)
        }
        if !cmds.isEmpty { perform(.batch(cmds)) }
    }

    public mutating func align(ids: Set<UUID>, _ edge: AlignEdge, within rect: CGRect? = nil) {
        let objs = document.objects.filter { ids.contains($0.id) && !$0.locked }
        // One object aligns to the canvas; several align to each other.
        let frame = rect ?? (objs.count >= 2 ? objs.dropFirst().reduce(objs[0].bounds) { $0.union($1.bounds) } : nil) ?? CGRect(origin: .zero, size: document.imageSize)
        replaceAll(EditorLayout.align(objs, edge, within: frame))
    }

    public mutating func distribute(ids: Set<UUID>, _ axis: DistributeAxis) {
        replaceAll(EditorLayout.distribute(document.objects.filter { ids.contains($0.id) && !$0.locked }, axis))
    }

    private mutating func replaceAll(_ new: [Annotation]) {
        let cmds = new.compactMap { n -> EditorCommand? in
            guard let o = document.objects.first(where: { $0.id == n.id }), o != n else { return nil }
            return .replace(old: o, new: n)
        }
        if !cmds.isEmpty { perform(.batch(cmds)) }
    }

    /// Positive `by` moves the layer towards the front.
    public mutating func moveLayer(id: UUID, by: Int) {
        guard let i = document.objects.firstIndex(where: { $0.id == id }) else { return }
        let t = min(max(i + by, 0), document.objects.count - 1)
        if t != i { perform(.reorder(id: id, from: i, to: t)) }
    }
}

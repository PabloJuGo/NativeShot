import CoreGraphics
import Foundation

public enum AlignEdge: Sendable, CaseIterable { case left, centerX, right, top, centerY, bottom }
public enum DistributeAxis: Sendable { case horizontal, vertical }

/// Pure geometry for align / distribute / snapping.
public enum EditorLayout {
    public static func align(_ objects: [Annotation], _ edge: AlignEdge, within r: CGRect) -> [Annotation] {
        objects.map { a in
            let b = a.bounds
            let d: CGSize
            switch edge {
            case .left: d = CGSize(width: r.minX - b.minX, height: 0)
            case .centerX: d = CGSize(width: r.midX - b.midX, height: 0)
            case .right: d = CGSize(width: r.maxX - b.maxX, height: 0)
            case .top: d = CGSize(width: 0, height: r.minY - b.minY)
            case .centerY: d = CGSize(width: 0, height: r.midY - b.midY)
            case .bottom: d = CGSize(width: 0, height: r.maxY - b.maxY)
            }
            return a.translated(by: d)
        }
    }

    /// Equal gaps between the objects; the two outermost stay where they are. Needs three or more.
    public static func distribute(_ objects: [Annotation], _ axis: DistributeAxis) -> [Annotation] {
        guard objects.count >= 3 else { return objects }
        let horizontal = axis == .horizontal
        let sorted = objects.sorted { horizontal ? $0.bounds.minX < $1.bounds.minX : $0.bounds.minY < $1.bounds.minY }
        func lo(_ r: CGRect) -> Double { horizontal ? r.minX : r.minY }
        func hi(_ r: CGRect) -> Double { horizontal ? r.maxX : r.maxY }
        func len(_ r: CGRect) -> Double { horizontal ? r.width : r.height }
        let span = hi(sorted.last!.bounds) - lo(sorted.first!.bounds)
        let gap = (span - sorted.reduce(0) { $0 + len($1.bounds) }) / Double(sorted.count - 1)
        var cursor = lo(sorted.first!.bounds)
        return sorted.map { a in
            let b = a.bounds
            let delta = cursor - lo(b)
            cursor += len(b) + gap
            return a.translated(by: horizontal ? CGSize(width: delta, height: 0) : CGSize(width: 0, height: delta))
        }
    }

    public static func snap(_ p: CGPoint, grid: Double) -> CGPoint {
        guard grid > 0 else { return p }
        return CGPoint(x: (p.x / grid).rounded() * grid, y: (p.y / grid).rounded() * grid)
    }
}

/// Rotate, flip and resize rewrite the bitmap and every object's coordinates in one undoable step.
public enum GeometryOp: Sendable, Equatable {
    case rotateRight, rotateLeft, flipHorizontal, flipVertical
    /// Scales the image and everything on it.
    case resize(width: Int, height: Int)
    /// New canvas size; `anchor` (0...1 per axis) says where the old image sits, `fill` paints the new area.
    case canvas(width: Int, height: Int, anchor: CGPoint, fill: EditorColor)

    static let maxSide = 32_768
    static let maxPixels = 100_000_000

    func outSize(_ s: CGSize) -> CGSize? {
        let o: CGSize
        switch self {
        case .rotateRight, .rotateLeft: o = CGSize(width: s.height, height: s.width)
        case .flipHorizontal, .flipVertical: o = s
        case .resize(let w, let h), .canvas(let w, let h, _, _): o = CGSize(width: w, height: h)
        }
        guard o.width >= 1, o.height >= 1, o.width <= Double(Self.maxSide), o.height <= Double(Self.maxSide),
              o.width * o.height <= Double(Self.maxPixels) else { return nil }
        return o
    }

    /// Old → new coordinates (both top-left origin, y down).
    func affine(_ s: CGSize) -> CGAffineTransform {
        switch self {
        case .rotateRight: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: s.height, ty: 0)
        case .rotateLeft: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: s.width)
        case .flipHorizontal: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: s.width, ty: 0)
        case .flipVertical: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: s.height)
        case .resize(let w, let h): CGAffineTransform(scaleX: Double(w) / s.width, y: Double(h) / s.height)
        case .canvas(let w, let h, let anchor, _):
            CGAffineTransform(translationX: ((Double(w) - s.width) * anchor.x).rounded(), y: ((Double(h) - s.height) * anchor.y).rounded())
        }
    }

    var rotatesOrFlips: Bool {
        switch self { case .rotateRight, .rotateLeft, .flipHorizontal, .flipVertical: true; default: false }
    }
}

public enum EditorTransform {
    /// nil when the requested size is out of range or drawing fails.
    public static func apply(_ op: GeometryOp, to doc: EditorDocument) -> BaseSnapshot? {
        let old = doc.imageSize
        guard let out = op.outSize(old) else { return nil }
        let t = op.affine(old)
        var fill: EditorColor?
        if case .canvas(_, _, _, let f) = op { fill = f }
        guard let image = redraw(doc.original, size: out, transform: t, fill: fill, like: doc.original) else { return nil }

        var images = doc.images
        if op.rotatesOrFlips {
            for (id, img) in doc.images {
                let s = CGSize(width: img.width, height: img.height)
                guard let o = op.outSize(s), let r = redraw(img, size: o, transform: op.affine(s), fill: nil, like: img) else { return nil }
                images[id] = r
            }
        }
        var crop = doc.crop?.applying(t).intersection(CGRect(origin: .zero, size: out))
        if let c = crop, c.isNull || c.width < 1 || c.height < 1 { crop = nil }
        return BaseSnapshot(original: image, objects: doc.objects.map { mapped($0, t) }, crop: crop, images: images)
    }

    static func mapped(_ a: Annotation, _ t: CGAffineTransform) -> Annotation {
        var n = a
        n.start = a.start.applying(t); n.end = a.end.applying(t)
        n.points = a.points.map { $0.applying(t) }
        if a.kind == .text {
            let size = a.bounds.size
            let c = CGPoint(x: a.bounds.midX, y: a.bounds.midY).applying(t)
            n.start = CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        }
        return n
    }

    private static func redraw(_ image: CGImage, size: CGSize, transform t: CGAffineTransform, fill: EditorColor?, like: CGImage) -> CGImage? {
        guard let ctx = EditorRenderer.makeContext(width: Int(size.width), height: Int(size.height), like: like) else { return nil }
        ctx.interpolationQuality = .high
        if let fill { ctx.setFillColor(fill.cg); ctx.fill(CGRect(origin: .zero, size: size)) }
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) // y-down
        ctx.concatenate(t)
        ctx.translateBy(x: 0, y: CGFloat(image.height)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

extension EditorSession {
    /// Rotate / flip / resize / canvas resize as one undo step. Returns false when the size is invalid.
    @discardableResult
    public mutating func apply(_ op: GeometryOp) -> Bool {
        guard let new = EditorTransform.apply(op, to: document) else { return false }
        perform(.setBase(old: document.base, new: new))
        return true
    }
}

public enum ImageSampler {
    /// Colour of the pixel at `p` (top-left origin); nil outside the image.
    public static func color(in image: CGImage, at p: CGPoint) -> EditorColor? {
        let x = Int(p.x.rounded(.down)), y = Int(p.y.rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ok: Bool = px.withUnsafeMutableBytes {
            guard let ctx = CGContext(data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return true
        }
        guard ok else { return nil }
        let a = Double(px[3]) / 255
        guard a > 0 else { return EditorColor(0, 0, 0, 0) }
        return EditorColor(Double(px[0]) / 255 / a, Double(px[1]) / 255 / a, Double(px[2]) / 255 / a, a)
    }
}

public struct NamedPreset<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var value: Value
    public var id: String { name }
}

/// Named presets kept locally in UserDefaults (style presets, background presets).
public struct PresetStore<Value: Codable & Sendable & Equatable> {
    let defaults: UserDefaults
    let key: String
    static var limit: Int { 50 }

    public init(key: String, defaults: UserDefaults = .standard) { (self.key, self.defaults) = (key, defaults) }

    public func all() -> [NamedPreset<Value>] {
        guard let d = defaults.data(forKey: key), let list = try? JSONDecoder().decode([NamedPreset<Value>].self, from: d) else { return [] }
        return list
    }

    /// Saving an existing name replaces it. Blank names are ignored.
    public func save(_ name: String, _ value: Value) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        var list = all().filter { $0.name != n }
        list.append(NamedPreset(name: String(n.prefix(60)), value: value))
        write(Array(list.suffix(Self.limit)))
    }

    public func delete(_ name: String) { write(all().filter { $0.name != name }) }

    private func write(_ list: [NamedPreset<Value>]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
    }
}

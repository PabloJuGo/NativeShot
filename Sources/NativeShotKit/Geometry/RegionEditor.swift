import CoreGraphics

public enum RegionHandle: CaseIterable, Sendable {
    // "top" is the smaller y: the editor works in any y-down space (Quartz, flipped views).
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }
}

/// CAP-001/006: pure state machine behind region selection. A press creates, moves or resizes depending on
/// where it lands; `ratio` (width / height) fixes the aspect while dragging. Shared by the capture overlay
/// and the scroll-capture crop.
public struct RegionEditor: Sendable {
    public private(set) var rect: CGRect?
    private enum Drag { case none, create(CGPoint), resize(RegionHandle), move(CGSize) }
    private var drag = Drag.none

    public init(rect: CGRect? = nil) { self.rect = rect }

    public var isDragging: Bool { if case .none = drag { false } else { true } }

    public mutating func set(_ r: CGRect?) { rect = r; drag = .none }

    public static func handle(at p: CGPoint, in r: CGRect, tolerance: CGFloat) -> RegionHandle? {
        RegionHandle.allCases
            .map { ($0, hypot($0.point(in: r).x - p.x, $0.point(in: r).y - p.y)) }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?.0
    }

    /// `forceCreate` starts a new selection even over the current one (multi-region).
    public mutating func begin(at p: CGPoint, tolerance: CGFloat, bounds: CGRect, forceCreate: Bool = false) {
        if !forceCreate, let r = rect {
            if let h = Self.handle(at: p, in: r, tolerance: tolerance) { drag = .resize(h); return }
            if r.contains(p) { drag = .move(CGSize(width: p.x - r.minX, height: p.y - r.minY)); return }
        }
        let c = Self.clamp(p, to: bounds)
        drag = .create(c)
        rect = CGRect(origin: c, size: .zero)
    }

    public mutating func update(to p: CGPoint, ratio: CGFloat?, bounds: CGRect) {
        guard let r = rect else { return }
        switch drag {
        case .none: break
        case .create(let a): rect = Self.spanned(from: a, to: p, ratio: ratio, bounds: bounds)
        case .move(let grab):
            let o = CGPoint(x: p.x - grab.width, y: p.y - grab.height)
            rect = CGRect(x: min(max(o.x, bounds.minX), bounds.maxX - r.width),
                          y: min(max(o.y, bounds.minY), bounds.maxY - r.height), width: r.width, height: r.height)
        case .resize(let h): rect = Self.resized(r, handle: h, to: p, ratio: ratio, bounds: bounds)
        }
    }

    /// Ends the gesture; a click without drag (under 2 pt) discards a freshly created selection.
    public mutating func end() {
        if case .create = drag, let r = rect, r.width < 2 || r.height < 2 { rect = nil }
        drag = .none
    }

    static func clamp(_ p: CGPoint, to b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    /// Rect from anchor `a` to pointer `p`, optionally with a fixed width/height ratio, kept inside `bounds`.
    public static func spanned(from a: CGPoint, to p: CGPoint, ratio: CGFloat?, bounds: CGRect) -> CGRect {
        let c = clamp(p, to: bounds)
        guard let ratio, ratio > 0 else { return DisplayGeometry.rect(from: a, to: c) }
        let sx: CGFloat = c.x >= a.x ? 1 : -1, sy: CGFloat = c.y >= a.y ? 1 : -1
        var w = abs(c.x - a.x), h = abs(c.y - a.y)
        if w / ratio > h { h = w / ratio } else { w = h * ratio }
        let availW = sx > 0 ? bounds.maxX - a.x : a.x - bounds.minX
        let availH = sy > 0 ? bounds.maxY - a.y : a.y - bounds.minY
        if w > availW { w = availW; h = w / ratio }
        if h > availH { h = availH; w = h * ratio }
        return DisplayGeometry.rect(from: a, to: CGPoint(x: a.x + sx * w, y: a.y + sy * h))
    }

    public static func resized(_ r: CGRect, handle: RegionHandle, to p: CGPoint, ratio: CGFloat?, bounds: CGRect) -> CGRect {
        let c = clamp(p, to: bounds)
        switch handle {
        case .topLeft: return spanned(from: CGPoint(x: r.maxX, y: r.maxY), to: c, ratio: ratio, bounds: bounds)
        case .topRight: return spanned(from: CGPoint(x: r.minX, y: r.maxY), to: c, ratio: ratio, bounds: bounds)
        case .bottomLeft: return spanned(from: CGPoint(x: r.maxX, y: r.minY), to: c, ratio: ratio, bounds: bounds)
        case .bottomRight: return spanned(from: CGPoint(x: r.minX, y: r.minY), to: c, ratio: ratio, bounds: bounds)
        case .left, .right, .top, .bottom:
            let horizontal = handle == .left || handle == .right
            // Free edge drag moves one side; with a ratio the other axis follows around the rect's centre.
            let fixed = horizontal ? (handle == .left ? r.maxX : r.minX) : (handle == .top ? r.maxY : r.minY)
            let edge = horizontal ? c.x : c.y
            let lo = min(fixed, edge), hi = max(fixed, edge)
            guard let ratio, ratio > 0 else {
                return horizontal ? CGRect(x: lo, y: r.minY, width: hi - lo, height: r.height)
                                  : CGRect(x: r.minX, y: lo, width: r.width, height: hi - lo)
            }
            var len = hi - lo
            var cross = horizontal ? len / ratio : len * ratio
            let crossMid = horizontal ? r.midY : r.midX
            let crossMax = horizontal ? min(crossMid - bounds.minY, bounds.maxY - crossMid) * 2
                                      : min(crossMid - bounds.minX, bounds.maxX - crossMid) * 2
            if cross > crossMax { cross = crossMax; len = horizontal ? cross * ratio : cross / ratio }
            let start = edge < fixed ? fixed - len : fixed
            return horizontal ? CGRect(x: start, y: crossMid - cross / 2, width: len, height: cross)
                              : CGRect(x: crossMid - cross / 2, y: start, width: cross, height: len)
        }
    }

    /// CAP-006: exact size keeping the top-left corner, shrunk to fit `bounds`. Nil for non-positive sizes.
    public static func resized(_ r: CGRect, toSize s: CGSize, bounds: CGRect) -> CGRect? {
        guard s.width >= 1, s.height >= 1 else { return nil }
        let w = min(s.width, bounds.width), h = min(s.height, bounds.height)
        return CGRect(x: min(max(r.minX, bounds.minX), bounds.maxX - w), y: min(max(r.minY, bounds.minY), bounds.maxY - h), width: w, height: h)
    }

    /// "1280x720", "1280 × 720" or "1280,720" → (1280, 720).
    public static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(whereSeparator: { "x×*, ".contains($0) }).compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 1, parts[1] >= 1 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}

/// CAP-006: aspect presets of the mode bar.
public enum AspectPreset: String, CaseIterable, Sendable {
    case free, square, fourThree, sixteenNine, threeTwo

    /// width / height, nil when free.
    public var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .fourThree: 4.0 / 3
        case .sixteenNine: 16.0 / 9
        case .threeTwo: 3.0 / 2
        }
    }
}

public extension DisplayGeometry {
    /// CAP-019: the rect without its top `inset` points (the notch band of a built-in display, in a y-down space).
    static func excludingTop(_ rect: CGRect, inset: CGFloat) -> CGRect {
        let i = min(max(inset, 0), rect.height - 1)
        return CGRect(x: rect.minX, y: rect.minY + i, width: rect.width, height: rect.height - i)
    }
}

import Foundation

/// Raw pixel rows (row-major, no padding). 1 byte/pixel = gray; 3 or 4 = interleaved colour (alpha ignored for matching).
public struct ScrollFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bytesPerPixel: Int
    public let data: [UInt8]

    public init(width: Int, height: Int, bytesPerPixel: Int, data: [UInt8]) {
        precondition(width > 0 && height > 0 && bytesPerPixel > 0 && data.count == width * height * bytesPerPixel)
        self.width = width; self.height = height; self.bytesPerPixel = bytesPerPixel; self.data = data
    }

    public var rowBytes: Int { width * bytesPerPixel }

    /// Rows become columns (SCR-002): the vertical aligner then works on horizontal scrolling unchanged.
    public func transposed() -> ScrollFrame {
        let bpp = bytesPerPixel
        let out = [UInt8](unsafeUninitializedCapacity: data.count) { buf, n in
            data.withUnsafeBufferPointer { src in
                for y in 0..<height { for x in 0..<width {
                    let s = (y * width + x) * bpp, d = (x * height + y) * bpp
                    for c in 0..<bpp { buf[d + c] = src[s + c] }
                } }
            }
            n = data.count
        }
        return ScrollFrame(width: height, height: width, bytesPerPixel: bpp, data: out)
    }
}

/// Direction the user scrolls in (SCR-002).
public enum ScrollAxis: String, Sendable, CaseIterable { case vertical, horizontal }

public struct ScrollConfig: Sendable {
    /// Largest accepted per-row difference (mean over the signature bins, 0...255) to call two rows equal.
    public var rowTolerance = 2
    /// Fraction of informative overlap rows that must match for a shift to be accepted.
    public var minMatchFraction = 0.9
    /// Required gap between the best shift and the runner-up; below it the join is ambiguous (repetitive content).
    public var minGap = 0.3
    public var minInformativeRows = 8
    public var minOverlapRows = 24
    public var minOverlapFraction = 0.15
    /// Fixed bands may not eat more than this share of the frame, or there is nothing left to align.
    public var maxFixedFraction = 0.7
    /// SCR-006: hard memory ceiling for accumulated rows, and rows per tile.
    public var maxTotalBytes = 768 << 20
    public var maxSegmentHeight = 8192
    /// Bottom rows of each frame re-taken from the next frame (rounded window corners are ~10 pt, 2× on Retina).
    public var edgeRows = 48
    public init() {}
}

public enum ScrollRejection: Error, Equatable, Sendable {
    /// No shift explains the change: scrolled too far, animated content, or a virtualised list re-rendering.
    case noOverlap
    /// Several shifts fit equally well (repetitive or flat content).
    case ambiguous
    case fixedBandsTooLarge
    case sizeMismatch
}

enum ScrollMatch: Equatable {
    case identical
    /// Content moved up by `shift` rows (user scrolled down).
    case shifted(shift: Int, confidence: Double, top: Int, bottom: Int)
    /// Content moved down: the user scrolled back up.
    case scrolledBack(shift: Int, confidence: Double, top: Int, bottom: Int)
    case rejected(ScrollRejection)
}

/// Compact per-row signature: mean luminance over column bins, so comparing two rows costs ~64 bytes.
struct RowSignatures {
    static let maxBins = 64
    let rows: Int
    let bins: Int
    private(set) var sig: [UInt8]
    private(set) var informative: [Bool]

    init(_ f: ScrollFrame) {
        rows = f.height
        let bins = min(Self.maxBins, f.width)
        self.bins = bins
        var sig = [UInt8](repeating: 0, count: rows * bins)
        var info = [Bool](repeating: false, count: rows)
        let bpp = f.bytesPerPixel, w = f.width, rows = rows
        f.data.withUnsafeBufferPointer { px in
            for y in 0..<rows {
                var lo = 255, hi = 0
                for b in 0..<bins {
                    let x0 = b * w / bins, x1 = (b + 1) * w / bins
                    var sum = 0
                    var p = (y * w + x0) * bpp
                    for _ in x0..<x1 {
                        sum += bpp >= 3 ? (Int(px[p]) + Int(px[p + 1]) + Int(px[p + 2])) / 3 : Int(px[p])
                        p += bpp
                    }
                    let m = sum / (x1 - x0)
                    sig[y * bins + b] = UInt8(m)
                    lo = min(lo, m); hi = max(hi, m)
                }
                // Flat rows (margins, backgrounds) match anything flat, so they carry no alignment information.
                info[y] = hi - lo >= 6
            }
        }
        self.sig = sig; informative = info
    }

    /// True when row `i` of self and row `j` of `o` differ by at most `tol` on average.
    @inline(__always)
    func rowsMatch(_ i: Int, _ o: RowSignatures, _ j: Int, tol: Int) -> Bool {
        let limit = tol * bins
        var d = 0
        return sig.withUnsafeBufferPointer { a in
            o.sig.withUnsafeBufferPointer { b in
                let pa = i * bins, pb = j * bins
                for k in 0..<bins {
                    d += abs(Int(a[pa + k]) - Int(b[pb + k]))
                    if d > limit { return false }
                }
                return true
            }
        }
    }
}

enum ScrollAligner {
    static func align(_ prev: RowSignatures, _ next: RowSignatures, _ cfg: ScrollConfig) -> ScrollMatch {
        let h = prev.rows
        guard h == next.rows, prev.bins == next.bins else { return .rejected(.sizeMismatch) }

        var same = 0
        for i in 0..<h where prev.rowsMatch(i, next, i, tol: cfg.rowTolerance) { same += 1 }
        if Double(same) >= 0.98 * Double(h) { return .identical }

        // Sticky header/footer: rows equal at the same position in both frames.
        var top = 0
        while top < h, prev.rowsMatch(top, next, top, tol: cfg.rowTolerance) { top += 1 }
        var bottom = 0
        while bottom < h - top, prev.rowsMatch(h - 1 - bottom, next, h - 1 - bottom, tol: cfg.rowTolerance) { bottom += 1 }
        guard Double(top + bottom) <= cfg.maxFixedFraction * Double(h) else { return .rejected(.fixedBandsTooLarge) }

        switch search(prev, next, top: top, bottom: bottom, cfg) {
        case .success(let r): return .shifted(shift: r.shift, confidence: r.confidence, top: top, bottom: bottom)
        case .failure(.noOverlap):
            if case .success(let r) = search(next, prev, top: top, bottom: bottom, cfg) {
                return .scrolledBack(shift: r.shift, confidence: r.confidence, top: top, bottom: bottom)
            }
            return .rejected(.noOverlap)
        case .failure(let r): return .rejected(r)
        }
    }

    /// Finds s such that `b` row r equals `a` row r+s inside the non-fixed body.
    private static func search(_ a: RowSignatures, _ b: RowSignatures, top: Int, bottom: Int,
                               _ cfg: ScrollConfig) -> Result<(shift: Int, confidence: Double), ScrollRejection> {
        let end = a.rows - bottom
        let body = end - top
        let minOverlap = max(cfg.minOverlapRows, Int(Double(body) * cfg.minOverlapFraction))
        let maxShift = body - minOverlap
        guard maxShift >= 1 else { return .failure(.fixedBandsTooLarge) }

        // Prefix count of informative rows in `a`, to know each candidate's denominator in O(1).
        var prefix = [Int](repeating: 0, count: a.rows + 1)
        for i in 0..<a.rows { prefix[i + 1] = prefix[i] + (a.informative[i] ? 1 : 0) }

        // Match fraction per shift (0 = early-rejected). Index = shift.
        var score = [Double](repeating: 0, count: maxShift + 1)
        for s in 1...maxShift {
            let info = prefix[end] - prefix[top + s]
            guard info >= cfg.minInformativeRows else { continue }
            let allowed = Int(Double(info) * 0.4) // below 60% it can neither win nor be a credible runner-up
            var miss = 0
            var ok = true
            for i in (top + s)..<end where a.informative[i] {
                if !a.rowsMatch(i, b, i - s, tol: cfg.rowTolerance) {
                    miss += 1
                    if miss > allowed { ok = false; break }
                }
            }
            if ok { score[s] = Double(info - miss) / Double(info) }
        }
        guard let bestS = score.indices.max(by: { score[$0] < score[$1] }), score[bestS] >= cfg.minMatchFraction else {
            return .failure(.noOverlap)
        }
        let best = (s: bestS, f: score[bestS])
        // Shifts a pixel or two off the best one also match most rows of vertically uniform content (blocks, thick
        // bars); they are the same alignment, not a rival. Skip the peak's slopes while the score keeps falling.
        var lo = bestS, hi = bestS
        while lo > 1, score[lo - 1] > 0, score[lo - 1] <= score[lo] { lo -= 1 }
        while hi < maxShift, score[hi + 1] > 0, score[hi + 1] <= score[hi] { hi += 1 }
        let rivals = score.indices.filter { ($0 < lo || $0 > hi) && score[$0] > 0 }
        guard let second = rivals.map({ score[$0] }).max() else { return .success((best.s, best.f)) }
        guard best.f - second >= cfg.minGap else { return .failure(.ambiguous) }
        return .success((best.s, best.f - second))
    }
}

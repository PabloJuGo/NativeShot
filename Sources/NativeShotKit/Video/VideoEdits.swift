import CoreGraphics
import Foundation

/// A stretch of the source whose audio is silenced (source seconds). Independent of segment splits.
public struct MuteRange: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public init(id: UUID = UUID(), start: Double, end: Double) { self.id = id; self.start = start; self.end = end }
    var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end - start >= 0.05 }
}

/// Text label burned into the output between `start` and `end` (source seconds). `x`,`y` = centre in the output
/// frame (0...1, origin top left); `size` = text height as a fraction of the output height.
public struct VideoCaption: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public var x: Double
    public var y: Double
    public var size: Double
    public init(id: UUID = UUID(), start: Double, end: Double, text: String, x: Double = 0.5, y: Double = 0.88, size: Double = 0.06) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.x = x; self.y = y; self.size = size
    }
    public static let sizeRange = 0.02...0.3
    var isValid: Bool {
        [start, end, x, y, size].allSatisfy(\.isFinite) && start >= 0 && end - start >= 0.1 && (0...1).contains(x) && (0...1).contains(y)
            && Self.sizeRange.contains(size) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 200
    }
}

/// Which recorded audio tracks reach the output. Only meaningful with two tracks (system, then microphone).
public enum AudioSelection: String, Codable, Sendable, CaseIterable {
    case both, system, microphone

    func includes(track i: Int, of count: Int) -> Bool {
        guard count >= 2 else { return true }
        switch self {
        case .both: return true
        case .system: return i == 0
        case .microphone: return i == 1
        }
    }
}

/// Recorded pointer positions (0...1, origin top left), smoothed so the camera glides instead of jittering.
public struct CursorTrack: Sendable, Equatable {
    let samples: [VideoClickEvent]
    public init(_ raw: [VideoClickEvent]) {
        samples = raw.filter { $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }.sorted { $0.t < $1.t }
    }
    public var isEmpty: Bool { samples.isEmpty }

    func position(at t: Double) -> (x: Double, y: Double)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return (first.x, first.y) }
        if t >= last.t { return (last.x, last.y) }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if samples[m].t <= t { lo = m } else { hi = m } }
        let a = samples[lo], b = samples[hi]
        let p = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return (a.x + (b.x - a.x) * p, a.y + (b.y - a.y) * p)
    }

    /// Mean of 9 taps over ±0.5 s (offline, so it may look ahead).
    public func smoothed(at t: Double) -> (x: Double, y: Double)? {
        var sx = 0.0, sy = 0.0, n = 0.0
        for k in -4...4 {
            guard let p = position(at: t + Double(k) * 0.125) else { return nil }
            sx += p.x; sy += p.y; n += 1
        }
        return (sx / n, sy / n)
    }
}

/// Everything that decides which part of the source frame is shown at a given time: crop, zoom keyframes and
/// cursor follow. One value feeds both preview and export.
public struct CameraPath: Sendable {
    public var zoom: ZoomTimeline
    public var crop: NormalizedRect
    /// 0 = off ... 1 = tightest follow window (40 % of the zoom rectangle).
    public var follow: Double
    public var track: CursorTrack?

    public init(zoom: ZoomTimeline, crop: NormalizedRect = .full, follow: Double = 0, track: CursorTrack? = nil) {
        self.zoom = zoom; self.crop = crop; self.follow = follow; self.track = track
    }

    /// Visible rectangle in source-frame coordinates at source time `t`.
    public func rect(at t: Double) -> NormalizedRect {
        var z = zoom.rect(at: t)
        if follow > 0, let track, let p = track.smoothed(at: t) {
            let s = 1 - 0.6 * min(follow, 1)
            let w = z.width * s, h = z.height * s
            // Cursor in the coordinates of the cropped frame, which is what `z` is relative to.
            let cx = min(max((p.x - crop.x) / crop.width, 0), 1), cy = min(max((p.y - crop.y) / crop.height, 0), 1)
            z = NormalizedRect(x: min(max(cx - w / 2, z.x), z.x + z.width - w), y: min(max(cy - h / 2, z.y), z.y + z.height - h), width: w, height: h)
        }
        return NormalizedRect(x: crop.x + z.x * crop.width, y: crop.y + z.y * crop.height, width: z.width * crop.width, height: z.height * crop.height)
    }
}

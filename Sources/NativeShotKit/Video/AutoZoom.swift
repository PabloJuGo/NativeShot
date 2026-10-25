import Foundation

/// One click from the `events.json` sidecar written by the recorder (single shared contract).
public typealias VideoClickEvent = RecordingEvents.Click

public enum VideoClickEvents {
    /// nil when the sidecar is missing, unreadable or from an unknown version: auto zoom stays disabled.
    public static func load(from url: URL) -> [VideoClickEvent]? {
        guard let data = try? Data(contentsOf: url), data.count < 32 << 20,
              let file = try? JSONDecoder().decode(RecordingEvents.self, from: data), file.version == 1 else { return nil }
        return file.clicks
    }

    /// Pointer track for cursor-follow: the recorded samples, or the clicks of older recordings. nil when neither exists.
    public static func loadCursor(from url: URL) -> [VideoClickEvent]? {
        guard let data = try? Data(contentsOf: url), data.count < 32 << 20,
              let file = try? JSONDecoder().decode(RecordingEvents.self, from: data), file.version == 1 else { return nil }
        let samples = file.cursor?.isEmpty == false ? file.cursor! : file.clicks
        return samples.isEmpty ? nil : samples
    }

    /// `originals/<id>/events.json` next to the source video.
    public static func sidecarURL(forSource source: URL) -> URL { source.deletingLastPathComponent().appendingPathComponent(RecordingEvents.fileName) }
}

public struct AutoZoomOptions: Sendable {
    /// Clicks closer than this in time to the previous one (and within `radius`) belong to the same zoom.
    public var maxGap = 1.5
    public var radius = 0.2
    /// Fraction of the frame shown while zoomed, before widening to fit spread-out clicks.
    public var scale = 0.5
    public var margin = 0.15
    public var lead = 0.4
    public var zoomInDuration = 0.6
    public var zoomOutDuration = 0.7
    public var minHold = 2.0
    public var tail = 1.0
    /// Zoom-out is skipped (the next zoom-in chains straight from this one) when the next zoom starts this soon after.
    public var chainGap = 1.0
    public init() {}
}

/// Local, deterministic heuristic (no remote AI): groups nearby clicks and proposes zoom-in/zoom-out keyframes
/// the user can then move, retime or delete. Same input, same output (ids included).
public enum AutoZoom {
    public static func suggest(clicks raw: [VideoClickEvent], duration: Double, options o: AutoZoomOptions = .init()) -> [ZoomKeyframe] {
        let clicks = raw.filter { $0.t.isFinite && $0.x.isFinite && $0.y.isFinite && (0...duration).contains($0.t) && (0...1).contains($0.x) && (0...1).contains($0.y) }
            .sorted { ($0.t, $0.x, $0.y) < ($1.t, $1.x, $1.y) }
        var clusters: [[VideoClickEvent]] = []
        for c in clicks {
            if var cur = clusters.last, let last = cur.last, c.t - last.t <= o.maxGap {
                let cx = cur.map(\.x).reduce(0, +) / Double(cur.count), cy = cur.map(\.y).reduce(0, +) / Double(cur.count)
                if hypot(c.x - cx, c.y - cy) <= o.radius { cur.append(c); clusters[clusters.count - 1] = cur; continue }
            }
            clusters.append([c])
        }

        var out: [ZoomKeyframe] = []
        var n = 0
        func id() -> UUID { n += 1; return UUID(uuid: (0x4E, 0x53, 0x5A, 0x4D, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(n >> 8 & 255), UInt8(n & 255))) }

        for (i, c) in clusters.enumerated() {
            let xs = c.map(\.x), ys = c.map(\.y)
            let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
            let side = max(o.scale, span + 2 * o.margin)
            guard side < 0.9 else { continue } // clicks all over the screen: zooming would not help
            let cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2
            let rect = NormalizedRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side).clamped()

            var tIn = max(0, c[0].t - o.lead)
            if let prev = out.last { tIn = max(tIn, prev.time + 0.1) }
            out.append(ZoomKeyframe(id: id(), time: tIn, rect: rect, duration: o.zoomInDuration, auto: true))

            let tOut = max(c[c.count - 1].t + o.tail, tIn + o.zoomInDuration + o.minHold)
            let nextIn = i + 1 < clusters.count ? clusters[i + 1][0].t - o.lead : .infinity
            if nextIn - tOut >= o.chainGap, tOut < duration - 0.2 {
                out.append(ZoomKeyframe(id: id(), time: tOut, rect: .full, duration: o.zoomOutDuration, auto: true))
            }
        }
        return out
    }
}

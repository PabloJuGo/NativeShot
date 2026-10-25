import CoreGraphics
import Foundation

/// Rectangle in 0...1 coordinates with the origin at the top left (same convention as `events.json`).
public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    /// Keeps the rect inside the frame and no smaller than `minSide`.
    public func clamped(minSide: Double = 0.1) -> NormalizedRect {
        let w = min(max(width, minSide), 1), h = min(max(height, minSide), 1)
        return NormalizedRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width >= 0.05 && height >= 0.05
            && x + width <= 1.0001 && y + height <= 1.0001
    }

    static func lerp(_ a: NormalizedRect, _ b: NormalizedRect, _ p: Double) -> NormalizedRect {
        NormalizedRect(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p,
                       width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
    }
}

/// A kept stretch of the source video, in source seconds.
public struct VideoSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public init(id: UUID = UUID(), start: Double, end: Double) { self.id = id; self.start = start; self.end = end }
    public var duration: Double { end - start }
}

public enum ZoomCurve: String, Codable, Sendable, CaseIterable {
    case easeInOut, linear

    func apply(_ p: Double) -> Double {
        switch self {
        case .linear: p
        case .easeInOut: p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
        }
    }
}

/// "From `time`, move to `rect` over `duration`, then hold until the next keyframe". Time is in source seconds.
/// `NormalizedRect.full` zooms out. `auto` marks keyframes produced by the click heuristic.
public struct ZoomKeyframe: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var time: Double
    public var rect: NormalizedRect
    public var duration: Double
    public var curve: ZoomCurve
    public var auto: Bool
    public init(id: UUID = UUID(), time: Double, rect: NormalizedRect, duration: Double = 0.6, curve: ZoomCurve = .easeInOut, auto: Bool = false) {
        self.id = id; self.time = time; self.rect = rect; self.duration = duration; self.curve = curve; self.auto = auto
    }
}

/// Evaluates the zoom rectangle at any time. A keyframe that starts while the previous transition is still
/// running departs from the rectangle that transition had reached, so zooms interrupt and chain without jumps.
public struct ZoomTimeline: Sendable, Equatable {
    public let keyframes: [ZoomKeyframe]
    public init(_ keyframes: [ZoomKeyframe]) { self.keyframes = keyframes.sorted { $0.time < $1.time } }

    public func rect(at t: Double) -> NormalizedRect {
        var active: (k: ZoomKeyframe, from: NormalizedRect)?
        func value(_ a: (k: ZoomKeyframe, from: NormalizedRect)?, _ t: Double) -> NormalizedRect {
            guard let a else { return .full }
            let p = a.k.duration <= 0 ? 1 : min(max((t - a.k.time) / a.k.duration, 0), 1)
            return p >= 1 ? a.k.rect : .lerp(a.from, a.k.rect, a.k.curve.apply(p))
        }
        for k in keyframes {
            if k.time > t { break }
            active = (k, value(active, k.time))
        }
        return value(active, t)
    }
}

public struct AudioTrackSettings: Codable, Equatable, Sendable {
    public var muted = false
    public var gain = 1.0
    public var fadeIn = 0.0
    public var fadeOut = 0.0
    public init(muted: Bool = false, gain: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0) {
        self.muted = muted; self.gain = gain; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }
}

/// Source time ↔ output time, honouring removed stretches and playback speed.
public struct TimeMap: Sendable, Equatable {
    public let segments: [VideoSegment]
    public let speed: Double
    public init(segments: [VideoSegment], speed: Double) { self.segments = segments; self.speed = max(speed, 0.01) }

    public var outputDuration: Double { segments.reduce(0) { $0 + $1.duration } / speed }

    /// nil when `s` falls in a removed stretch.
    public func outputTime(forSource s: Double) -> Double? {
        var acc = 0.0
        for seg in segments {
            if s >= seg.start, s <= seg.end { return (acc + s - seg.start) / speed }
            acc += seg.duration
        }
        return nil
    }

    public func sourceTime(forOutput o: Double) -> Double {
        var u = max(o, 0) * speed
        for seg in segments {
            if u <= seg.duration { return seg.start + u }
            u -= seg.duration
        }
        return segments.last?.end ?? 0
    }

    /// First kept source time at or after `s` (the last kept instant when `s` is past everything).
    public func snapToKept(_ s: Double) -> Double {
        for seg in segments {
            if s < seg.start { return seg.start }
            if s <= seg.end { return s }
        }
        return segments.last?.end ?? 0
    }
}

/// Editable state of a video edit; the source itself is referenced from outside (see `VideoProjectPackage`).
public struct VideoProject: Codable, Equatable, Sendable {
    public static let minSegment = 0.1
    public static let speedRange = 0.25...8.0
    public var segments: [VideoSegment]
    public var zooms: [ZoomKeyframe]
    /// Index = audio track order in the source (system audio first, then microphone).
    public var audio: [AudioTrackSettings]
    public var speed: Double
    // Added after the first release of the format: absent in older files, decoded with defaults.
    public var mutes: [MuteRange] = []
    public var captions: [VideoCaption] = []
    /// Output mask: the part of the source frame that is kept.
    public var crop: NormalizedRect = .full
    public var audioSelection: AudioSelection = .both
    /// Cursor-follow intensity, 0 = off.
    public var followIntensity = 0.0

    public init(duration: Double) {
        segments = [VideoSegment(start: 0, end: duration)]
        zooms = []
        audio = [AudioTrackSettings(), AudioTrackSettings()]
        speed = 1
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = try c.decode([VideoSegment].self, forKey: .segments)
        zooms = try c.decode([ZoomKeyframe].self, forKey: .zooms)
        audio = try c.decode([AudioTrackSettings].self, forKey: .audio)
        speed = try c.decode(Double.self, forKey: .speed)
        mutes = try c.decodeIfPresent([MuteRange].self, forKey: .mutes) ?? []
        captions = try c.decodeIfPresent([VideoCaption].self, forKey: .captions) ?? []
        crop = try c.decodeIfPresent(NormalizedRect.self, forKey: .crop) ?? .full
        audioSelection = try c.decodeIfPresent(AudioSelection.self, forKey: .audioSelection) ?? .both
        followIntensity = try c.decodeIfPresent(Double.self, forKey: .followIntensity) ?? 0
    }

    /// Output frame size after the crop mask, even dimensions.
    public func croppedSize(of natural: CGSize) -> CGSize {
        CGSize(width: max(2, Int(natural.width * crop.width) & ~1), height: max(2, Int(natural.height * crop.height) & ~1))
    }

    /// `start..<end` minus the muted stretches: what stays audible, in source seconds.
    func audibleRanges(from start: Double, to end: Double) -> [(Double, Double)] {
        var out = [(start, end)]
        for m in mutes {
            out = out.flatMap { r -> [(Double, Double)] in
                guard m.end > r.0, m.start < r.1 else { return [r] }
                return [(r.0, min(m.start, r.1)), (max(m.end, r.0), r.1)].filter { $0.1 - $0.0 > 0.001 }
            }
        }
        return out
    }

    public var timeMap: TimeMap { TimeMap(segments: segments, speed: speed) }
    public var zoomTimeline: ZoomTimeline { ZoomTimeline(zooms) }

    // MARK: Editing primitives (return false when the edit would be a no-op or break an invariant)

    @discardableResult
    mutating func split(at t: Double) -> Bool {
        guard let i = segments.firstIndex(where: { t - $0.start >= Self.minSegment && $0.end - t >= Self.minSegment }) else { return false }
        let s = segments[i]
        segments[i] = VideoSegment(id: s.id, start: s.start, end: t)
        segments.insert(VideoSegment(start: t, end: s.end), at: i + 1)
        return true
    }

    /// Removes `from..<to` from every segment. Refuses to leave the project empty.
    @discardableResult
    mutating func deleteRange(from a: Double, to b: Double) -> Bool {
        guard a < b else { return false }
        var out: [VideoSegment] = []
        for s in segments {
            if b <= s.start || a >= s.end { out.append(s); continue }
            if a - s.start >= Self.minSegment { out.append(VideoSegment(id: s.id, start: s.start, end: a)) }
            if s.end - b >= Self.minSegment { out.append(VideoSegment(start: b, end: s.end)) }
        }
        guard !out.isEmpty, out != segments else { return false }
        segments = out
        return true
    }

    // MARK: Validation (untrusted input from disk)

    public func validate(sourceDuration: Double) throws {
        func bad(_ m: String) -> VideoProjectError { .invalid(m) }
        guard sourceDuration.isFinite, sourceDuration > 0 else { throw bad("duración de la fuente") }
        guard (1...256).contains(segments.count) else { throw bad("segmentos") }
        var last = 0.0
        for s in segments {
            guard s.start.isFinite, s.end.isFinite, s.start >= last - 1e-6, s.end - s.start >= Self.minSegment - 1e-6,
                  s.end <= sourceDuration + 0.05 else { throw bad("segmento \(s.start)–\(s.end)") }
            last = s.end
        }
        guard Self.speedRange.contains(speed) else { throw bad("velocidad") }
        guard audio.count <= 8, audio.allSatisfy({ (0...4).contains($0.gain) && (0...60).contains($0.fadeIn) && (0...60).contains($0.fadeOut) })
        else { throw bad("audio") }
        guard mutes.count <= 512, mutes.allSatisfy({ $0.isValid && $0.end <= sourceDuration + 0.05 }) else { throw bad("silencios") }
        guard captions.count <= 200, captions.allSatisfy(\.isValid) else { throw bad("rótulos") }
        guard crop.isValid, followIntensity.isFinite, (0...1).contains(followIntensity) else { throw bad("recorte o seguimiento") }
        guard zooms.count <= 2_000 else { throw bad("demasiados zooms") }
        for z in zooms {
            guard z.time.isFinite, z.time >= 0, z.time <= sourceDuration + 1, z.duration.isFinite, (0...30).contains(z.duration),
                  z.rect.isValid else { throw bad("zoom en \(z.time)") }
        }
    }
}

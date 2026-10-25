import CoreGraphics
import Foundation

/// Contract with the video editor: `originals/<id>/events.json` next to `source.mp4`.
/// Clicks and, optionally, throttled pointer positions (`cursor`, same shape as a click; absent in older files). Never keys. `t` is seconds in the movie (pauses already removed); x,y are 0...1 in the
/// video frame with the origin at the top left.
public struct RecordingEvents: Codable, Sendable, Equatable {
    public struct Click: Codable, Sendable, Equatable {
        public var t: Double, x: Double, y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
    }

    public static let fileName = "events.json"
    public var version = 1
    public var clicks: [Click]
    /// Pointer samples (~15 Hz) for the editor's cursor-follow. Additive field: version stays 1, old readers ignore it.
    public var cursor: [Click]?
    public static let maxCursorSamples = 120_000

    public init(clicks: [Click] = [], cursor: [Click]? = nil) { self.clicks = clicks; self.cursor = cursor }

    /// `point` and `rect` share one top-left coordinate space (Quartz global). Nil when the point is outside the recorded area.
    public static func normalize(_ point: CGPoint, in rect: CGRect) -> (x: Double, y: Double)? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return ((point.x - rect.minX) / rect.width, (point.y - rect.minY) / rect.height)
    }

    public func write(toFolder folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Video -> animated GIF with ImageIO. Runs wherever the caller awaits it (never needs the MainActor);
/// cancelling the task stops sampling and removes the partial file.
public enum GIFExporter {
    public struct Options: Sendable {
        public var fps: Int
        /// Frames wider than this are scaled down keeping the aspect ratio; nil keeps the video size.
        public var maxWidth: Int?
        public init(fps: Int = 15, maxWidth: Int? = 640) { self.fps = fps; self.maxWidth = maxWidth }
    }

    public struct Result: Sendable, Equatable {
        public var frames: Int
        public var byteSize: Int64
        public var isLarge: Bool { byteSize > GIFExporter.largeThreshold }
    }

    public static let largeThreshold: Int64 = 20_000_000

    /// Sample instants for the whole clip: one per 1/fps, at least one.
    public static func frameTimes(duration: Double, fps: Int) -> [Double] {
        guard duration > 0, fps > 0 else { return [] }
        return (0..<max(1, Int(duration * Double(fps)))).map { Double($0) / Double(fps) }
    }

    public static func export(video: URL, to destination: URL, options: Options,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let asset = AVURLAsset(url: video)
        let times = frameTimes(duration: try await asset.load(.duration).seconds, fps: options.fps)
        guard !times.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.5 / Double(options.fps), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        if let w = options.maxWidth { generator.maximumSize = CGSize(width: w, height: 16_384) }
        defer { generator.cancelAllCGImageGeneration() }

        // Own folder: ImageIO leaves a hidden sibling temp file behind if the destination is never finalized.
        let scratch = destination.deletingLastPathComponent().appendingPathComponent(".gif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tmp = scratch.appendingPathComponent("out.gif")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        // GIF delays are centiseconds: 15 fps lands on 7 cs, a ~5% error nobody sees.
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(options.fps)]] as CFDictionary
        var done = 0
        for await r in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            try Task.checkCancellation()
            CGImageDestinationAddImage(dest, try r.image, frameProps)
            done += 1
            progress(Double(done) / Double(times.count))
        }
        try Task.checkCancellation()
        guard done > 0, CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return Result(frames: done, byteSize: size)
    }
}

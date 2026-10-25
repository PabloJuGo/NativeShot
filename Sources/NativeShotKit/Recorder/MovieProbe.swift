import AVFoundation

/// Reads duration and size of a (possibly fragmented, interrupted) MP4 for crash recovery.
public enum MovieProbe {
    public static func info(of url: URL) async -> MovieInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return nil }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return MovieInfo(duration: duration, width: Int(size.width), height: Int(size.height), droppedFrames: 0, byteSize: bytes)
    }
}

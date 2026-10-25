import AVFoundation
import Foundation

/// Video codec for recording and export. HEVC is only used when `AVAssetWriter` accepts it on this machine;
/// otherwise `resolved` falls back to H.264 (never promise HEVC).
public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264, hevc

    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }

    public func isSupported(width: Int, height: Int) -> Bool {
        guard self == .hevc else { return true }
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("nativeshot-codec-probe.mov")
        guard let w = try? AVAssetWriter(outputURL: probe, fileType: .mov) else { return false }
        return w.canApply(outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height], forMediaType: .video)
    }

    public func resolved(width: Int, height: Int) -> VideoCodec { isSupported(width: width, height: height) ? self : .h264 }
}

/// Recording quality = video bitrate tier.
public enum RecordingQuality: String, Codable, Sendable, CaseIterable {
    case low, standard, high

    public func bitrate(width: Int, height: Int, fps: Int, codec: VideoCodec) -> Int {
        let base = Double(min(max(width * height * fps / 8, 2_000_000), 40_000_000))
        let tier: Double = switch self { case .low: 0.5; case .standard: 1; case .high: 1.75 }
        return Int(min(max(base * tier * (codec == .hevc ? 0.65 : 1), 1_000_000), 80_000_000))
    }
}

public enum StorageLevel: Equatable, Sendable { case normal, low, critical }

/// Free space on the recording volume (UI-10: normal / almacenamiento bajo).
public enum DiskSpace {
    public static let lowBytes: Int64 = 2 << 30
    public static let criticalBytes: Int64 = 300 << 20

    /// Low also when less than 5 minutes fit at `bitrate` (bits per second).
    public static func level(freeBytes: Int64, bitrate: Int = 0) -> StorageLevel {
        if freeBytes < criticalBytes { return .critical }
        if freeBytes < lowBytes || (bitrate > 0 && minutesRemaining(freeBytes: freeBytes, bitrate: bitrate) < 5) { return .low }
        return .normal
    }

    public static func minutesRemaining(freeBytes: Int64, bitrate: Int) -> Int {
        bitrate > 0 ? Int(Double(freeBytes) * 8 / Double(bitrate) / 60) : .max
    }

    public static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

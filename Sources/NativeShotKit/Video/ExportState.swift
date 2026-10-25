import AVFoundation
import Foundation

/// Export lifecycle: queued → preparing → encoding → writing → validating → completed,
/// or cancelled / failed from any in-flight phase.
public enum ExportPhase: Equatable, Sendable {
    case queued, preparing, encoding, writing, validating, completed
    case cancelled
    case failed(String)

    public var isFinished: Bool {
        switch self {
        case .completed, .cancelled, .failed: true
        default: false
        }
    }
}

public enum ExportEvent: Sendable {
    case begin, prepared, encoded, written, validated
    case cancel, fail(String)
}

public struct ExportStateMachine: Sendable {
    public private(set) var phase: ExportPhase = .queued
    public init() {}

    /// False (state untouched) for transitions the spec does not allow; terminal states accept nothing.
    @discardableResult
    public mutating func handle(_ event: ExportEvent) -> Bool {
        let next: ExportPhase?
        switch (phase, event) {
        case (.queued, .begin): next = .preparing
        case (.preparing, .prepared): next = .encoding
        case (.encoding, .encoded): next = .writing
        case (.writing, .written): next = .validating
        case (.validating, .validated): next = .completed
        case (.queued, .cancel), (.preparing, .cancel), (.encoding, .cancel), (.writing, .cancel): next = .cancelled
        case (.preparing, .fail(let r)), (.encoding, .fail(let r)), (.writing, .fail(let r)), (.validating, .fail(let r)): next = .failed(r)
        default: next = nil
        }
        guard let next else { return false }
        phase = next
        return true
    }
}

public enum ExportPreset: Sendable, Equatable, Codable {
    case tutorial, messaging, highQuality, reducedSize
    case custom(maxHeight: Int, videoBitrate: Int)

    public static let named: [ExportPreset] = [.tutorial, .messaging, .highQuality, .reducedSize]

    /// nil = keep the source resolution.
    public var maxHeight: Int? {
        switch self {
        case .tutorial: 1080
        case .messaging: 720
        case .highQuality: nil
        case .reducedSize: 480
        case .custom(let h, _): h
        }
    }

    public var videoBitrate: Int {
        switch self {
        case .tutorial: 8_000_000
        case .messaging: 3_000_000
        case .highQuality: 20_000_000
        case .reducedSize: 1_000_000
        case .custom(_, let b): b
        }
    }

    public var audioBitrate: Int {
        switch self {
        case .reducedSize: 96_000
        case .highQuality: 192_000
        default: 128_000
        }
    }

    /// Rough size for the preset sheet; the real file depends on the content.
    public func estimatedBytes(duration: Double) -> Int64 { Int64(Double(videoBitrate + audioBitrate) * duration / 8) }

    /// Output size: fits within `maxHeight` without upscaling, even dimensions (H.264 requirement).
    public func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        var w = Double(width), h = Double(height)
        if let m = maxHeight, h > Double(m) { w = w * Double(m) / h; h = Double(m) }
        return (max(2, Int(w) & ~1), max(2, Int(h) & ~1))
    }

    public var isValid: Bool {
        if case .custom(let h, let b) = self { return (120...4320).contains(h) && (100_000...100_000_000).contains(b) }
        return true
    }
}

public enum VideoContainer: String, Codable, Sendable, CaseIterable {
    case mp4, mov

    var fileType: AVFileType { self == .mov ? .mov : .mp4 }
    public var fileExtension: String { rawValue }
}

/// Encoding choices beyond the preset (only the Personalizado preset exposes them in the UI).
public struct ExportOptions: Equatable, Sendable {
    public var codec = VideoCodec.h264
    public var container = VideoContainer.mp4
    /// nil = keep the source frame rate.
    public var fps: Int?
    public init(codec: VideoCodec = .h264, container: VideoContainer = .mp4, fps: Int? = nil) { self.codec = codec; self.container = container; self.fps = fps }
    public var isValid: Bool { fps.map { (1...120).contains($0) } ?? true }
}

import AVFoundation
import CoreMedia
import Foundation

public struct MovieWriterError: Error, LocalizedError, Sendable {
    public let errorDescription: String?
}

public struct MovieInfo: Sendable, Equatable {
    public var duration: TimeInterval
    public var width: Int
    public var height: Int
    public var droppedFrames: Int
    public var byteSize: Int64
}

/// H.264 (or HEVC when available) + AAC MP4 writer. Samples arrive on the capture queue; nothing here ever blocks it:
/// when an input is not ready the sample is dropped and counted.
/// System audio and microphone go to separate AAC tracks (no realtime mixing, editable later).
public final class MovieWriter: @unchecked Sendable {
    public let url: URL
    public let width: Int, height: Int, fps: Int
    /// Codec actually in use (HEVC requested but unsupported falls back to H.264).
    public let codec: VideoCodec
    public let videoBitrate: Int
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let frameDuration: CMTime
    private let lock = NSLock()
    private var timeline = PauseTimeline()
    private var sessionStarted = false
    private var finished = false
    private var lastVideoEnd: CMTime = .zero
    private var dropped = 0
    private var failure: String?

    /// `url` must not exist. Fragments every 10 s so a crash leaves a playable partial file.
    public init(url: URL, width: Int, height: Int, fps: Int, systemAudio: Bool, microphone: Bool,
                codec requested: VideoCodec = .h264, quality: RecordingQuality = .standard, microphoneChannels: Int = 1) throws {
        self.url = url; self.width = width; self.height = height; self.fps = fps
        codec = requested.resolved(width: width, height: height)
        videoBitrate = quality.bitrate(width: width, height: height, fps: fps, codec: codec)
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        var props: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ]
        if codec == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec.avCodec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: props,
        ])
        video.expectsMediaDataInRealTime = true
        func audioInput(channels: Int, bitrate: Int) -> AVAssetWriterInput {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: bitrate,
            ])
            i.expectsMediaDataInRealTime = true
            return i
        }
        self.systemAudio = systemAudio ? audioInput(channels: 2, bitrate: 128_000) : nil
        self.microphone = microphone ? audioInput(channels: microphoneChannels == 2 ? 2 : 1, bitrate: microphoneChannels == 2 ? 128_000 : 96_000) : nil
        for i in [video, self.systemAudio, self.microphone].compactMap({ $0 }) { writer.add(i) }
        guard writer.startWriting() else {
            throw MovieWriterError(errorDescription: writer.error?.localizedDescription ?? "No se pudo iniciar el escritor")
        }
    }

    public var hasWrittenFrames: Bool { lock.withLock { sessionStarted } }
    public var failureReason: String? { lock.withLock { failure ?? (writer.status == .failed ? writer.error?.localizedDescription : nil) } }

    public func pause() { lock.withLock { timeline.pause() } }
    public func resume() { lock.withLock { timeline.resume() } }

    /// Movie time (pauses removed) of a capture-clock instant, for the events contract.
    public func movieTime(forHostTime t: CMTime) -> CMTime? { lock.withLock { timeline.event(t) } }

    public func appendVideo(_ sb: CMSampleBuffer) {
        lock.withLock {
            guard !finished, writer.status == .writing else { return }
            let pts = sb.presentationTimeStamp
            guard let t = timeline.video(pts, frameDuration: frameDuration) else { return }
            if !sessionStarted { writer.startSession(atSourceTime: .zero); sessionStarted = true }
            guard video.isReadyForMoreMediaData else { dropped += 1; return }
            guard let retimed = Self.retimed(sb, delta: t - pts) else { return }
            if video.append(retimed) { lastVideoEnd = t + frameDuration } else { failure = writer.error?.localizedDescription }
        }
    }

    public func appendSystemAudio(_ sb: CMSampleBuffer) { appendAudio(sb, to: systemAudio) }
    public func appendMicrophone(_ sb: CMSampleBuffer) { appendAudio(sb, to: microphone) }

    private func appendAudio(_ sb: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input else { return }
        lock.withLock {
            guard !finished, sessionStarted, writer.status == .writing else { return }
            let pts = sb.presentationTimeStamp
            guard let t = timeline.audio(pts), input.isReadyForMoreMediaData,
                  let retimed = Self.retimed(sb, delta: t - pts) else { return }
            if !input.append(retimed) { failure = writer.error?.localizedDescription }
        }
    }

    /// Idempotent: a second call (double click on stop) waits for nothing and returns the same error.
    public func finish() async throws -> MovieInfo {
        let ok: Bool = lock.withLock {
            guard !finished else { return false }
            finished = true
            return sessionStarted && writer.status == .writing
        }
        guard ok else {
            writer.cancelWriting()
            throw MovieWriterError(errorDescription: failureReason ?? "La grabación no contiene ningún fotograma.")
        }
        for i in [video, systemAudio, microphone].compactMap({ $0 }) { i.markAsFinished() }
        writer.endSession(atSourceTime: lastVideoEnd)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MovieWriterError(errorDescription: writer.error?.localizedDescription ?? "No se pudo finalizar el vídeo")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return MovieInfo(duration: lastVideoEnd.seconds, width: width, height: height, droppedFrames: lock.withLock { dropped }, byteSize: size)
    }

    /// Stops without producing output and removes the partial file.
    public func cancel() {
        lock.withLock { finished = true }
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    private static func retimed(_ sb: CMSampleBuffer, delta: CMTime) -> CMSampleBuffer? {
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in infos.indices {
            infos[i].presentationTimeStamp = infos[i].presentationTimeStamp + delta
            infos[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: infos, sampleBufferOut: &out)
        return out
    }
}

import AVFoundation
import Foundation

public enum VideoExportError: Error, Sendable, LocalizedError {
    case cancelled
    case invalidPreset
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: String(localized: "Exportación cancelada.")
        case .invalidPreset: String(localized: "El preset personalizado no es válido.")
        case .failed(let why): String(localized: "No se pudo exportar el vídeo: \(why)")
        }
    }
}

/// Reader/writer instead of `AVAssetExportSession`: the session only offers fixed presets, while the
/// Personalizado preset needs an explicit resolution and bitrate. Output goes to a hidden temp file next
/// to the destination and is moved into place only after it validates.
public enum VideoExporter {
    public typealias Progress = @Sendable (ExportPhase, Double) -> Void

    /// Returns the codec actually used (HEVC falls back to H.264 when the writer can't do it).
    @discardableResult
    public static func export(project: VideoProject, source: URL, preset: ExportPreset, options: ExportOptions = .init(), to destination: URL, progress: @escaping Progress) async throws -> VideoCodec {
        guard preset.isValid, options.isValid else { throw VideoExportError.invalidPreset }
        var used = VideoCodec.h264
        var machine = ExportStateMachine()
        func go(_ e: ExportEvent, _ fraction: Double) { machine.handle(e); progress(machine.phase, fraction) }
        let tmp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).export.\(options.container.fileExtension)")
        let job = Job()
        do {
            try await withTaskCancellationHandler {
                go(.begin, 0)
                let asset = AVURLAsset(url: source)
                let natural = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
                let cropped = project.croppedSize(of: natural)
                let out = preset.outputSize(width: Int(cropped.width), height: Int(cropped.height))
                used = options.codec.resolved(width: out.width, height: out.height)
                let composed = try await VideoComposer.build(project: project, asset: asset, renderSize: CGSize(width: out.width, height: out.height), fps: options.fps)
                try Task.checkCancellation()

                let reader = try AVAssetReader(asset: composed.composition)
                let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: composed.composition.tracks(withMediaType: .video),
                                                               videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                vOut.videoComposition = composed.videoComposition
                reader.add(vOut)
                let aTracks = composed.composition.tracks(withMediaType: .audio)
                var aOut: AVAssetReaderAudioMixOutput?
                if !aTracks.isEmpty {
                    let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                        AVLinearPCMIsBigEndianKey: false])
                    o.audioMix = composed.audioMix
                    o.audioTimePitchAlgorithm = .spectral
                    reader.add(o)
                    aOut = o
                }

                let writer = try AVAssetWriter(outputURL: tmp, fileType: options.container.fileType)
                let fps = max(1, Int((1 / composed.videoComposition.frameDuration.seconds).rounded()))
                var props: [String: Any] = [AVVideoAverageBitRateKey: preset.videoBitrate, AVVideoMaxKeyFrameIntervalKey: fps * 2]
                if used == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
                let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: used.avCodec, AVVideoWidthKey: out.width, AVVideoHeightKey: out.height,
                    AVVideoCompressionPropertiesKey: props])
                vIn.expectsMediaDataInRealTime = false
                writer.add(vIn)
                var aIn: AVAssetWriterInput?
                if aOut != nil {
                    let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: preset.audioBitrate])
                    i.expectsMediaDataInRealTime = false
                    writer.add(i)
                    aIn = i
                }
                job.set(reader: reader, writer: writer)
                guard reader.startReading(), writer.startWriting() else {
                    throw VideoExportError.failed((reader.error ?? writer.error)?.localizedDescription ?? "")
                }
                writer.startSession(atSourceTime: .zero)
                go(.prepared, 0)

                let total = max(composed.outputDuration, 0.001)
                let vPair = (Unchecked<AVAssetReaderOutput>(vOut), Unchecked(vIn))
                let aPair = aOut.flatMap { o in aIn.map { (Unchecked<AVAssetReaderOutput>(o), Unchecked($0)) } }
                async let v: Void = pump(vPair.0, vPair.1, job) { progress(.encoding, min($0 / total, 1)) }
                async let a: Void = {
                    if let aPair { await pump(aPair.0, aPair.1, job, nil) }
                }()
                _ = await (v, a)
                try Task.checkCancellation()
                if reader.status == .failed { throw VideoExportError.failed(reader.error?.localizedDescription ?? "") }
                go(.encoded, 1)
                await writer.finishWriting()
                if writer.status != .completed { throw VideoExportError.failed(writer.error?.localizedDescription ?? "") }
                go(.written, 1)

                try await validate(tmp, expected: composed.outputDuration)
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: destination) }
                go(.validated, 1)
            } onCancel: {
                job.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            if error is CancellationError || job.cancelled || (error as? VideoExportError).map({ if case .cancelled = $0 { true } else { false } }) == true {
                go(.cancel, 0)
                throw VideoExportError.cancelled
            }
            go(.fail(error.localizedDescription), 0)
            throw error is VideoExportError ? error : VideoExportError.failed(error.localizedDescription)
        }
        return used
    }

    static func validate(_ url: URL, expected: Double) async throws {
        let asset = AVURLAsset(url: url)
        let d = try await asset.load(.duration).seconds
        let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        guard hasVideo, abs(d - expected) <= max(0.5, expected * 0.05) else {
            throw VideoExportError.failed(String(localized: "El archivo resultante no supera la validación."))
        }
    }

    /// Feeds one reader output into one writer input on its own queue; resumes when the output is drained or cancelled.
    private static func pump(_ o: Unchecked<AVAssetReaderOutput>, _ i: Unchecked<AVAssetWriterInput>, _ job: Job, _ onTime: (@Sendable (Double) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            i.v.requestMediaDataWhenReady(on: DispatchQueue(label: "nativeshot.export.pump")) {
                while i.v.isReadyForMoreMediaData {
                    guard !job.cancelled, let sb = o.v.copyNextSampleBuffer() else { i.v.markAsFinished(); cont.resume(); return }
                    onTime?(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
                    if !i.v.append(sb) { i.v.markAsFinished(); cont.resume(); return }
                }
            }
        }
    }
}

private struct Unchecked<T>: @unchecked Sendable { let v: T; init(_ v: T) { self.v = v } }

private final class Job: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var _cancelled = false

    var cancelled: Bool { lock.withLock { _cancelled } }

    func set(reader: AVAssetReader, writer: AVAssetWriter) {
        lock.withLock { self.reader = reader; self.writer = writer }
        if cancelled { cancel() }
    }

    func cancel() {
        let (r, w) = lock.withLock { _cancelled = true; return (reader, writer) }
        r?.cancelReading()
        w?.cancelWriting()
    }
}

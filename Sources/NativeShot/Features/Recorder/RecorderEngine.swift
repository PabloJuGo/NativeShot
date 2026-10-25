import AVFoundation
import ScreenCaptureKit
import NativeShotKit

struct RecorderOptions: Sendable {
    var fps = 30
    var systemAudio = true
    var microphone = false
    var showsCursor = true
    var codec = VideoCodec.h264
    var quality = RecordingQuality.standard
    var microphoneChannels = 1
    /// `AVCaptureDevice.uniqueID`; nil = system default.
    var microphoneDeviceID: String?
}

/// One SCStream feeding one MovieWriter. Sample callbacks run on `queue`, never on the MainActor.
///
/// Microphone: macOS 15 `SCStreamConfiguration.captureMicrophone` delivers mic buffers on the same host
/// clock as video and system audio, so no drift correction is needed (an AVCaptureSession would need one).
final class RecorderEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: MovieWriter
    /// Called once if the stream dies on its own (display unplugged, window closed, permission revoked).
    var onFailure: (@Sendable (String) -> Void)?
    /// Peak 0...1 of system/microphone audio, throttled to ~10 Hz.
    var onLevel: (@Sendable (Float) -> Void)?

    private var stream: SCStream!
    private let queue = DispatchQueue(label: "app.nativeshot.recorder.samples", qos: .userInitiated)
    private let lock = NSLock()
    private var stopping = false
    private var peak: Float = 0
    private var lastLevelAt: CFTimeInterval = 0

    private init(writer: MovieWriter) { self.writer = writer }

    /// Builds the stream for `source`. NativeShot's own windows are excluded from the output except `includingWindows`
    /// (webcam bubble, click rings, shortcut pill). Window sources can't carry extra windows, so those overlays are skipped there.
    static func make(source: SelectionResult, options: RecorderOptions, url: URL, includingWindows: [CGWindowID] = []) async throws -> RecorderEngine {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        let pixels: (width: Int, height: Int)
        switch source {
        case .display(let id), .region(_, let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenCaptureAdapter.CaptureError(errorDescription: String(localized: "La pantalla ya no está disponible."))
            }
            filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == me },
                                    exceptingWindows: content.windows.filter { includingWindows.contains($0.windowID) })
            let scale = CGFloat(filter.pointPixelScale)
            let bounds = CGDisplayBounds(id)
            var local = CGRect(origin: .zero, size: bounds.size)
            if case .region(let r, _) = source {
                guard let l = DisplayGeometry.local(r, in: bounds) else {
                    throw ScreenCaptureAdapter.CaptureError(errorDescription: String(localized: "La región está fuera de la pantalla."))
                }
                local = DisplayGeometry.pixelAligned(l, scale: scale)
                config.sourceRect = local
            }
            pixels = DisplayGeometry.pixelSize(of: local, scale: scale)
        case .window(let id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ScreenCaptureAdapter.CaptureError(errorDescription: String(localized: "La ventana ya no está disponible."))
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            pixels = DisplayGeometry.pixelSize(of: CGRect(origin: .zero, size: filter.contentRect.size), scale: scale)
        }
        // H.264 needs even dimensions.
        let w = max(pixels.width & ~1, 2), h = max(pixels.height & ~1, 2)
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.showsCursor = options.showsCursor
        config.queueDepth = 6
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.microphone
        if options.microphone, let id = options.microphoneDeviceID, AVCaptureDevice(uniqueID: id) != nil { config.microphoneCaptureDeviceID = id }

        let writer = try MovieWriter(url: url, width: w, height: h, fps: options.fps,
                                     systemAudio: options.systemAudio, microphone: options.microphone,
                                     codec: options.codec, quality: options.quality, microphoneChannels: options.microphoneChannels)
        let engine = RecorderEngine(writer: writer)
        let stream = SCStream(filter: filter, configuration: config, delegate: engine)
        try stream.addStreamOutput(engine, type: .screen, sampleHandlerQueue: engine.queue)
        if options.systemAudio { try stream.addStreamOutput(engine, type: .audio, sampleHandlerQueue: engine.queue) }
        if options.microphone { try stream.addStreamOutput(engine, type: .microphone, sampleHandlerQueue: engine.queue) }
        engine.stream = stream
        return engine
    }

    func start() async throws { try await stream.startCapture() }

    // shortcut: pausing only drops samples, the stream keeps running; stop/restart the stream if idle CPU matters.
    func pause() { writer.pause() }
    func resume() { writer.resume() }

    func stop() async throws -> MovieInfo {
        markStopping()
        try? await stream.stopCapture()
        return try await writer.finish()
    }

    func cancel() async {
        markStopping()
        try? await stream.stopCapture()
        writer.cancel()
    }

    private func markStopping() { lock.withLock { stopping = true } }

    // MARK: SCStreamOutput (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            // Idle/blank frames carry no image; only complete ones are encoded.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  sb.imageBuffer != nil else { return }
            writer.appendVideo(sb)
            if let reason = writer.failureReason { fail(reason) }
        case .audio:
            writer.appendSystemAudio(sb)
            meter(sb)
        case .microphone:
            writer.appendMicrophone(sb)
            meter(sb)
        @unknown default: break
        }
    }

    private func meter(_ sb: CMSampleBuffer) {
        peak = max(peak, AudioMeter.peak(sb))
        let now = CACurrentMediaTime()
        guard now - lastLevelAt > 0.1 else { return }
        lastLevelAt = now
        onLevel?(peak)
        peak = 0
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) { fail(error.localizedDescription) }

    private func fail(_ reason: String) {
        let first: Bool = lock.withLock {
            defer { stopping = true }
            return !stopping
        }
        if first { onFailure?(reason) }
    }
}

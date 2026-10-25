import AVFoundation
import CoreImage
import Foundation

public enum VideoComposerError: Error, Sendable, LocalizedError {
    case noVideoTrack
    public var errorDescription: String? { String(localized: "El archivo no contiene pista de vídeo.") }
}

/// What the preview player and the exporter both consume, so what you see is what you export.
public struct ComposedVideo: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix?
    public let outputDuration: Double
    public let renderSize: CGSize
    public let audioTrackCount: Int
}

public enum VideoComposer {
    /// Zoom is rendered by a custom compositor instead of layer-instruction transform ramps: ramps are linear
    /// only, so an ease-in-out or a zoom interrupted mid-transition would need hand-sampled steps. The compositor
    /// evaluates the very same `CameraPath` (crop, zoom, cursor follow) per frame and crops with Core Image, then
    /// draws the captions on top.
    /// shortcut: ignores the source's preferredTransform (screen recordings are never rotated), revisit if imported clips are supported.
    public static func build(project: VideoProject, asset: AVAsset, applyZoom: Bool = true, renderSize: CGSize? = nil, fps fpsOverride: Int? = nil) async throws -> ComposedVideo {
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else { throw VideoComposerError.noVideoTrack }
        let srcAudio = try await asset.loadTracks(withMediaType: .audio)
        let natural = try await srcVideo.load(.naturalSize)
        let fps = try await srcVideo.load(.nominalFrameRate)
        let assetDuration = try await asset.load(.duration).seconds

        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VideoComposerError.noVideoTrack }
        let sourceAudio = Array(srcAudio.prefix(project.audio.count))
        // `index` = position in the source, which is also the index into `project.audio`.
        var audio = sourceAudio.indices.filter { project.audioSelection.includes(track: $0, of: sourceAudio.count) }
            .map { (index: $0, track: comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!) }

        let scale: CMTimeScale = 600
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: scale) }
        var cursor = CMTime.zero
        for seg in project.segments {
            let start = min(seg.start, assetDuration), end = min(seg.end, assetDuration)
            guard end > start else { continue }
            let range = CMTimeRange(start: time(start), end: time(end))
            try video.insertTimeRange(range, of: srcVideo, at: cursor)
            // Muted stretches are simply left out of the audio tracks (silence), which survives speed changes and export.
            for (a, b) in project.audibleRanges(from: start, to: end) {
                let sub = CMTimeRange(start: time(a), end: time(b))
                for t in audio { try t.track.insertTimeRange(sub, of: sourceAudio[t.index], at: cursor + (sub.start - range.start)) }
            }
            cursor = cursor + range.duration
        }
        // A track with nothing left in it (everything muted) would make the export reader fail: drop it.
        for t in audio where !(t.track.segments?.contains { !$0.isEmpty } ?? false) { comp.removeTrack(t.track) }
        audio.removeAll { !(comp.tracks.contains($0.track)) }
        if project.speed != 1 {
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: cursor), toDuration: CMTime(seconds: cursor.seconds / project.speed, preferredTimescale: scale))
        }

        let size = renderSize ?? project.croppedSize(of: natural)
        let follow = applyZoom ? project.followIntensity : 0
        let track = follow > 0
            ? (asset as? AVURLAsset).flatMap { VideoClickEvents.loadCursor(from: VideoClickEvents.sidecarURL(forSource: $0.url)) }.map(CursorTrack.init) : nil
        let camera = CameraPath(zoom: applyZoom ? project.zoomTimeline : ZoomTimeline([]), crop: project.crop, follow: track == nil ? 0 : follow, track: track)
        let instruction = ZoomInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration), trackID: video.trackID,
                                          map: project.timeMap, camera: camera, captions: project.captions, size: size)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = ZoomCompositor.self
        vc.instructions = [instruction]
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fpsOverride ?? (fps > 1 ? Int(fps.rounded()) : 30), 1)))

        let total = comp.duration.seconds
        let params = audio.map { index, track -> AVMutableAudioMixInputParameters in
            let s = project.audio[index]
            let p = AVMutableAudioMixInputParameters(track: track)
            let g = Float(s.gain)
            if s.muted { p.setVolume(0, at: .zero); return p }
            let fi = min(s.fadeIn, total / 2), fo = min(s.fadeOut, total / 2)
            if fi > 0 {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: g, timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: fi, preferredTimescale: scale)))
            } else {
                p.setVolume(g, at: .zero)
            }
            if fo > 0 {
                p.setVolumeRamp(fromStartVolume: g, toEndVolume: 0, timeRange: CMTimeRange(start: CMTime(seconds: total - fo, preferredTimescale: scale), duration: CMTime(seconds: fo, preferredTimescale: scale)))
            }
            return p
        }
        var mix: AVMutableAudioMix?
        if !params.isEmpty { mix = AVMutableAudioMix(); mix?.inputParameters = params }
        return ComposedVideo(composition: comp, videoComposition: vc, audioMix: mix, outputDuration: total, renderSize: size, audioTrackCount: audio.count)
    }
}

final class ZoomInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let map: TimeMap
    let camera: CameraPath
    /// Pre-rendered at the output size and already positioned inside the frame (Core Image origin: bottom left).
    let captions: [(start: Double, end: Double, image: CIImage)]

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, map: TimeMap, camera: CameraPath, captions: [VideoCaption], size: CGSize) {
        self.timeRange = timeRange; self.trackID = trackID; self.map = map; self.camera = camera
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.captions = captions.compactMap { c in
            guard let cg = CaptionRenderer.image(text: c.text, fontSize: c.size * size.height, maxWidth: size.width * 0.9) else { return nil }
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let x = min(max(c.x * size.width - w / 2, 0), max(size.width - w, 0))
            let y = min(max((1 - c.y) * size.height - h / 2, 0), max(size.height - h, 0))
            return (c.start, c.end, CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: x, y: y)))
        }
    }
}

final class ZoomCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let attrs: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.attrs }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.attrs }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let inst = request.videoCompositionInstruction as? ZoomInstruction,
              let src = request.sourceFrame(byTrackID: inst.trackID),
              let out = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "NativeShot.VideoComposer", code: 1))
            return
        }
        let sourceTime = inst.map.sourceTime(forOutput: request.compositionTime.seconds)
        let r = inst.camera.rect(at: sourceTime)
        let image = CIImage(cvPixelBuffer: src)
        let w = image.extent.width, h = image.extent.height
        // Normalized rect has its origin top-left; Core Image's is bottom-left.
        let crop = CGRect(x: r.x * w, y: (1 - r.y - r.height) * h, width: r.width * w, height: r.height * h)
        let size = request.renderContext.size
        var framed = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                .concatenating(CGAffineTransform(scaleX: size.width / crop.width, y: size.height / crop.height)))
        for c in inst.captions where sourceTime >= c.start && sourceTime < c.end { framed = c.image.composited(over: framed) }
        Self.context.render(framed, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        request.finish(withComposedVideoFrame: out)
    }
}

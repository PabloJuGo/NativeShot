import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import NativeShotKit

private let dur = 10.0
private func apply(_ h: inout VideoEditHistory, _ c: VideoCommand) -> Bool { h.apply(c, sourceDuration: dur) }

@Suite struct VideoProModelTests {
    @Test func oldProjectFilesDecodeWithDefaults() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(VideoProject(duration: 5))) as? [String: Any])
        for k in ["mutes", "captions", "crop", "audioSelection", "followIntensity"] { json.removeValue(forKey: k) }
        let p = try JSONDecoder().decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(p.crop == .full && p.audioSelection == .both && p.followIntensity == 0 && p.captions.isEmpty)
        try p.validate(sourceDuration: 5)
    }

    @Test func newEditsRoundTripAndValidate() throws {
        var p = VideoProject(duration: 5)
        p.mutes = [MuteRange(start: 1, end: 2)]
        p.captions = [VideoCaption(start: 0, end: 2, text: "Hola")]
        p.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        p.audioSelection = .microphone
        p.followIntensity = 0.5
        let back = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        try back.validate(sourceDuration: 5)
        var bad = p; bad.captions[0].text = "  "
        #expect(throws: VideoProjectError.self) { try bad.validate(sourceDuration: 5) }
        bad = p; bad.crop = NormalizedRect(x: 0.9, y: 0, width: 0.5, height: 1)
        #expect(throws: VideoProjectError.self) { try bad.validate(sourceDuration: 5) }
        bad = p; bad.mutes[0].end = 99
        #expect(throws: VideoProjectError.self) { try bad.validate(sourceDuration: 5) }
        bad = p; bad.followIntensity = 3
        #expect(throws: VideoProjectError.self) { try bad.validate(sourceDuration: 5) }
    }

    @Test func everyNewCommandIsUndoable() {
        var h = VideoEditHistory(project: VideoProject(duration: dur))
        let mute = MuteRange(start: 1, end: 3), cap = VideoCaption(start: 0, end: 2, text: "Hola")
        var edited = cap; edited.text = "Adiós"
        let commands: [VideoCommand] = [.addMute(mute), .addCaption(cap), .updateCaption(edited),
            .setCrop(NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)), .setAudioSelection(.system), .setFollow(0.7),
            .removeMute(mute.id), .removeCaption(cap.id)]
        var states = [h.project]
        for c in commands { #expect(apply(&h, c)); states.append(h.project) }
        for s in states.dropLast().reversed() { let ok = h.undo(); #expect(ok); #expect(h.project == s) }
        for s in states.dropFirst() { let ok = h.redo(); #expect(ok); #expect(h.project == s) }
    }

    @Test func invalidNewCommandsAreRejected() {
        var h = VideoEditHistory(project: VideoProject(duration: dur))
        #expect(!apply(&h, .addMute(MuteRange(start: 3, end: 3))))
        #expect(!apply(&h, .addMute(MuteRange(start: 1, end: 50))))
        #expect(!apply(&h, .addCaption(VideoCaption(start: 0, end: 2, text: ""))))
        #expect(!apply(&h, .addCaption(VideoCaption(start: 0, end: 2, text: "x", size: 5))))
        #expect(!apply(&h, .updateCaption(VideoCaption(start: 0, end: 2, text: "x"))))
        #expect(!apply(&h, .setCrop(NormalizedRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5))))
        #expect(!apply(&h, .setFollow(2)))
        #expect(!apply(&h, .setAudioSelection(.both))) // already the default: no-op
        #expect(!h.canUndo)
    }

    @Test func audibleRangesSubtractMutes() {
        var p = VideoProject(duration: dur)
        p.mutes = [MuteRange(start: 2, end: 3), MuteRange(start: 2.5, end: 5), MuteRange(start: 9, end: 12)]
        let r = p.audibleRanges(from: 0, to: 10)
        #expect(r.map { [$0.0, $0.1] } == [[0, 2], [5, 9]])
    }

    @Test func croppedSizeIsEven() {
        var p = VideoProject(duration: 1)
        p.crop = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        #expect(p.croppedSize(of: CGSize(width: 321, height: 241)) == CGSize(width: 160, height: 240))
    }
}

@Suite struct CameraPathTests {
    private let track = CursorTrack([VideoClickEvent(t: 0, x: 0.9, y: 0.5), VideoClickEvent(t: 10, x: 0.9, y: 0.5)])

    @Test func withoutFollowItIsTheZoomRect() {
        let z = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cam = CameraPath(zoom: ZoomTimeline([ZoomKeyframe(time: 0, rect: z, duration: 0)]))
        #expect(cam.rect(at: 1) == z)
        #expect(CameraPath(zoom: ZoomTimeline([])).rect(at: 1) == .full)
    }

    @Test func followWindowTracksCursorAndStaysInside() {
        let loose = CameraPath(zoom: ZoomTimeline([]), follow: 0.5, track: track).rect(at: 5)
        let tight = CameraPath(zoom: ZoomTimeline([]), follow: 1, track: track).rect(at: 5)
        #expect(abs(loose.width - 0.7) < 1e-9 && abs(tight.width - 0.4) < 1e-9) // intensity = tighter window
        #expect(abs(tight.x + tight.width - 1) < 1e-9) // cursor at the right edge: window clamped to the frame
        let inner = CameraPath(zoom: ZoomTimeline([ZoomKeyframe(time: 0, rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5), duration: 0)]), follow: 1, track: track).rect(at: 5)
        #expect(inner.x >= 0 && inner.x + inner.width <= 0.5 + 1e-9) // follows inside the manual zoom
    }

    @Test func cropShiftsEverythingIntoItsFrame() {
        let crop = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        #expect(CameraPath(zoom: ZoomTimeline([]), crop: crop).rect(at: 0) == crop)
        let r = CameraPath(zoom: ZoomTimeline([]), crop: crop, follow: 1, track: track).rect(at: 5)
        #expect(r.x >= 0.5 && r.x + r.width <= 1 + 1e-9)
    }

    @Test func smoothingGlidesBetweenSamples() {
        let t = CursorTrack([VideoClickEvent(t: 0, x: 0, y: 0), VideoClickEvent(t: 1, x: 1, y: 1)])
        #expect(abs(t.position(at: 0.5)!.x - 0.5) < 1e-9)
        #expect(abs(t.smoothed(at: 0.5)!.x - 0.5) < 1e-9)
        #expect(CursorTrack([]).smoothed(at: 1) == nil)
    }
}

@Suite struct EventsContractTests {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ns-ev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func cursorFieldIsAdditiveAndOldFilesStillLoad() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let url = d.appendingPathComponent("events.json")
        try Data(#"{"version":1,"clicks":[{"t":1,"x":0.2,"y":0.3}]}"#.utf8).write(to: url)
        #expect(VideoClickEvents.load(from: url)?.count == 1)
        #expect(VideoClickEvents.loadCursor(from: url)?.first?.x == 0.2) // falls back to the clicks
        try RecordingEvents(clicks: [.init(t: 1, x: 0.2, y: 0.3)], cursor: [.init(t: 0, x: 0.5, y: 0.5), .init(t: 0.1, x: 0.6, y: 0.5)]).write(toFolder: d)
        #expect(VideoClickEvents.load(from: url)?.count == 1)
        #expect(VideoClickEvents.loadCursor(from: url)?.count == 2)
        try Data(#"{"version":1,"clicks":[]}"#.utf8).write(to: url)
        #expect(VideoClickEvents.loadCursor(from: url) == nil)
    }

    @Test func autosaveRoundTripsInsideTheLibrary() throws {
        let root = try tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("originals/abc")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let src = srcDir.appendingPathComponent("source.mp4")
        try Data("x".utf8).write(to: src)
        let url = VideoProjectPackage.autosaveURL(libraryRoot: root, source: src)
        #expect(url.lastPathComponent == "abc.nshotvideo")
        var p = VideoProject(duration: 5)
        p.captions = [VideoCaption(start: 0, end: 1, text: "Hola")]
        try VideoProjectPackage.write(p, source: src, sourceDuration: 5, libraryRoot: root, to: url) // creates autosave/ itself
        try VideoProjectPackage.write(p, source: src, sourceDuration: 5, libraryRoot: root, to: url) // and overwrites atomically
        #expect(try VideoProjectPackage.read(from: url, libraryRoot: root).project == p)
    }
}

@Suite struct RecordingOptionTests {
    @Test func qualityTiersAndCodec() {
        let q = { (x: RecordingQuality, c: VideoCodec) in x.bitrate(width: 1920, height: 1080, fps: 30, codec: c) }
        #expect(q(.low, .h264) < q(.standard, .h264) && q(.standard, .h264) < q(.high, .h264))
        #expect(q(.standard, .hevc) < q(.standard, .h264))
        #expect(VideoCodec.h264.isSupported(width: 320, height: 240))
        #expect(VideoCodec.hevc.resolved(width: 320, height: 240) == (VideoCodec.hevc.isSupported(width: 320, height: 240) ? .hevc : .h264))
    }

    @Test func storageLevels() {
        #expect(DiskSpace.level(freeBytes: 50 << 30) == .normal)
        #expect(DiskSpace.level(freeBytes: 1 << 30) == .low)
        #expect(DiskSpace.level(freeBytes: 100 << 20) == .critical)
        #expect(DiskSpace.level(freeBytes: 5 << 30, bitrate: 200_000_000) == .low) // under 5 minutes left at this bitrate
        #expect(DiskSpace.minutesRemaining(freeBytes: 1 << 30, bitrate: 8_000_000) == 17)
        #expect((DiskSpace.freeBytes(at: FileManager.default.temporaryDirectory) ?? 0) > 0)
    }

    @Test func writerHonoursCodecQualityAndStereoMic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rec.mp4")
        let w = try MovieWriter(url: url, width: 320, height: 240, fps: 30, systemAudio: false, microphone: true,
                                codec: .hevc, quality: .high, microphoneChannels: 2)
        var t = 0.0
        while t < 1 {
            let pts = CMTime(seconds: 200 + t, preferredTimescale: 48_000)
            w.appendVideo(videoSample(320, 240, at: pts, shade: UInt8(t * 100)))
            w.appendMicrophone(audioSample(frames: 1_600, channels: 1, at: pts, amplitude: 0.1)) // mono device into a stereo track
            t += 1.0 / 30
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try await w.finish()
        let asset = AVURLAsset(url: url)
        let v = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let sub = try await v.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(sub == (w.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264))
        let a = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let ch = try await a.load(.formatDescriptions).first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
        #expect(ch == 2)
        #expect(try await asset.load(.isPlayable))
    }
}

// MARK: - Composition and export

private func meanLuma(_ cg: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
    var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let ctx = CGContext(data: &buf, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    var sum = 0.0, n = 0.0
    for py in Int(y.lowerBound * Double(cg.height))..<Int(y.upperBound * Double(cg.height)) {
        for px in Int(x.lowerBound * Double(cg.width))..<Int(x.upperBound * Double(cg.width)) { sum += Double(buf[(py * cg.width + px) * 4]); n += 1 }
    }
    return sum / n
}

private func frame(_ c: ComposedVideo, at s: Double) async throws -> CGImage {
    let gen = AVAssetImageGenerator(asset: c.composition)
    gen.videoComposition = c.videoComposition
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    return try await gen.image(at: CMTime(seconds: s, preferredTimescale: 600)).image
}

@Suite struct VideoProCompositionTests {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ns-vpro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func mutedRangesLeaveSilenceAndSelectionPicksTracks() async throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let asset = AVURLAsset(url: try await makeSource(in: dir, microphone: true))
        var p = VideoProject(duration: 3)
        var c = try await VideoComposer.build(project: p, asset: asset)
        #expect(c.audioTrackCount == 2)
        p.audioSelection = .microphone
        c = try await VideoComposer.build(project: p, asset: asset)
        #expect(c.audioTrackCount == 1 && c.audioMix?.inputParameters.count == 1)
        p.audioSelection = .system
        p.mutes = [MuteRange(start: 1, end: 2)]
        c = try await VideoComposer.build(project: p, asset: asset)
        let segs = try #require(c.composition.tracks(withMediaType: .audio)[0].segments)
        #expect(segs.filter { !$0.isEmpty }.count == 2) // audible before and after the muted second
        #expect(abs(c.outputDuration - 3) < 0.1) // muting never shortens the video
        // Speed keeps the hole in place.
        p.speed = 2
        c = try await VideoComposer.build(project: p, asset: asset)
        #expect(c.composition.tracks(withMediaType: .audio)[0].segments!.filter { !$0.isEmpty }.count == 2)
    }

    @Test func cropCaptionAndFollowShowInPreviewAndExport() async throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSource(in: dir)
        let asset = AVURLAsset(url: src)

        // Crop to the right (white) half: the output frame is white everywhere and 160x240.
        var p = VideoProject(duration: 3)
        p.crop = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        var c = try await VideoComposer.build(project: p, asset: asset)
        #expect(c.renderSize == CGSize(width: 160, height: 240))
        var img = try await frame(c, at: 1)
        #expect(meanLuma(img, x: 0.05...0.95, y: 0.05...0.95) > 230)
        let out = dir.appendingPathComponent("crop.mp4")
        try await VideoExporter.export(project: p, source: src, preset: .custom(maxHeight: 120, videoBitrate: 500_000), to: out) { _, _ in }
        let size = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)[0].load(.naturalSize)
        #expect(size == CGSize(width: 80, height: 120))
        #expect(try await luma(out, at: 1, x: 0.1, y: 0.5) > 200)

        // Caption over the white half is visible only inside its time range.
        p = VideoProject(duration: 3)
        let base = meanLuma(try await frame(try await VideoComposer.build(project: p, asset: asset), at: 0.5), x: 0.55...0.95, y: 0.4...0.6)
        p.captions = [VideoCaption(start: 0, end: 1, text: "Hola mundo", x: 0.75, y: 0.5, size: 0.2)]
        c = try await VideoComposer.build(project: p, asset: asset)
        img = try await frame(c, at: 0.5)
        #expect(meanLuma(img, x: 0.55...0.95, y: 0.4...0.6) < base - 30)
        img = try await frame(c, at: 2)
        #expect(abs(meanLuma(img, x: 0.55...0.95, y: 0.4...0.6) - base) < 1)

        // Cursor parked at the right edge: follow pans the view there, so the left probe turns white.
        try RecordingEvents(cursor: [.init(t: 0, x: 0.95, y: 0.5), .init(t: 3, x: 0.95, y: 0.5)]).write(toFolder: dir)
        p = VideoProject(duration: 3)
        #expect(meanLuma(try await frame(try await VideoComposer.build(project: p, asset: asset), at: 1), x: 0.05...0.15, y: 0.4...0.6) < 30)
        p.followIntensity = 1
        img = try await frame(try await VideoComposer.build(project: p, asset: asset), at: 1)
        #expect(meanLuma(img, x: 0.05...0.15, y: 0.4...0.6) > 200)
        // Showing the whole frame while editing a zoom disables follow, like zoom.
        img = try await frame(try await VideoComposer.build(project: p, asset: asset, applyZoom: false), at: 1)
        #expect(meanLuma(img, x: 0.05...0.15, y: 0.4...0.6) < 30)
    }

    @Test func exportsMOVWithOptionsAndFallsBackFromHEVC() async throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSource(in: dir)
        let out = dir.appendingPathComponent("out.mov")
        let preset = ExportPreset.custom(maxHeight: 120, videoBitrate: 500_000)
        let used = try await VideoExporter.export(project: VideoProject(duration: 3), source: src, preset: preset,
                                                  options: ExportOptions(codec: .hevc, container: .mov, fps: 15), to: out) { _, _ in }
        #expect(used == VideoCodec.hevc.resolved(width: 160, height: 120))
        let asset = AVURLAsset(url: out)
        #expect(try await asset.load(.isPlayable))
        let v = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(abs(try await v.load(.nominalFrameRate) - 15) < 1.5)
        let sub = try await v.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(sub == (used == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264))
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".") })
        await #expect(throws: VideoExportError.self) {
            try await VideoExporter.export(project: VideoProject(duration: 3), source: src, preset: preset, options: ExportOptions(fps: 0), to: dir.appendingPathComponent("x.mp4")) { _, _ in }
        }
    }

    @Test func fullyMutedProjectStillExports() async throws {
        let dir = try tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSource(in: dir)
        var p = VideoProject(duration: 3)
        p.mutes = [MuteRange(start: 0, end: 3)]
        let out = dir.appendingPathComponent("muted.mp4")
        try await VideoExporter.export(project: p, source: src, preset: .custom(maxHeight: 120, videoBitrate: 500_000), to: out) { _, _ in }
        #expect(try await AVURLAsset(url: out).load(.isPlayable))
        #expect(try await AVURLAsset(url: out).loadTracks(withMediaType: .audio).isEmpty)
    }
}

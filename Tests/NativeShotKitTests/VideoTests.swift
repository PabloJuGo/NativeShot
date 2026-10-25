import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import NativeShotKit

private let sourceDuration = 10.0

private func ok(_ h: inout VideoEditHistory, _ c: VideoCommand) -> Bool { h.apply(c, sourceDuration: sourceDuration) }
private func fire(_ m: inout ExportStateMachine, _ e: ExportEvent) -> Bool { m.handle(e) }

private func history(_ duration: Double = sourceDuration) -> VideoEditHistory { VideoEditHistory(project: VideoProject(duration: duration)) }

@Suite struct VideoEditingTests {
    @Test func splitDeleteAndTrim() {
        var h = history()
        #expect(ok(&h, .split(at: 4)))
        #expect(h.project.segments.map(\.start) == [0, 4])
        #expect(!ok(&h, .split(at: 4.01))) // would leave a sliver shorter than minSegment
        #expect(ok(&h, .deleteRange(from: 5, to: 6)))
        #expect(h.project.segments.map { [$0.start, $0.end] } == [[0, 4], [4, 5], [6, 10]])
        #expect(ok(&h, .trimStart(to: 1)))
        #expect(ok(&h, .trimEnd(to: 9)))
        #expect(h.project.segments.first?.start == 1 && h.project.segments.last?.end == 9)
    }

    @Test func cannotDeleteEverything() {
        var h = history()
        #expect(!ok(&h, .deleteRange(from: 0, to: 10)))
        #expect(!ok(&h, .deleteSegment(h.project.segments[0].id)))
        #expect(h.project.segments.count == 1 && !h.canUndo)
    }

    @Test func undoRedoRestoresExactly() {
        var h = history()
        let original = h.project
        h.apply(.split(at: 3), sourceDuration: sourceDuration)
        h.apply(.setSpeed(2), sourceDuration: sourceDuration)
        h.apply(.addZoom(ZoomKeyframe(time: 1, rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))), sourceDuration: sourceDuration)
        let edited = h.project
        #expect(h.undo() && h.undo() && h.undo())
        #expect(h.project == original && !h.undo())
        #expect(h.redo() && h.redo() && h.redo())
        #expect(h.project == edited && !h.redo())
        h.undo()
        h.apply(.setSpeed(4), sourceDuration: sourceDuration)
        #expect(!h.canRedo) // a new edit drops the redo branch
    }

    @Test func rejectsInvalidCommands() {
        var h = history()
        #expect(!ok(&h, .setSpeed(100)))
        #expect(!ok(&h, .setAudio(index: 5, AudioTrackSettings())))
        #expect(!ok(&h, .setAudio(index: 0, AudioTrackSettings(gain: 99))))
        #expect(!ok(&h, .addZoom(ZoomKeyframe(time: 1, rect: NormalizedRect(x: 0.8, y: 0, width: 0.5, height: 0.5)))))
        #expect(!ok(&h, .removeZoom(UUID())))
    }

    @Test func timeMapSkipsRemovedStretchesAndHonoursSpeed() {
        var h = history()
        h.apply(.deleteRange(from: 2, to: 4), sourceDuration: sourceDuration)
        let m = h.project.timeMap
        #expect(m.outputDuration == 8)
        #expect(m.outputTime(forSource: 1) == 1)
        #expect(m.outputTime(forSource: 3) == nil)
        #expect(m.outputTime(forSource: 5) == 3)
        #expect(m.sourceTime(forOutput: 1.5) == 1.5)
        #expect(m.sourceTime(forOutput: 3) == 5)
        #expect(m.snapToKept(3) == 4)
        h.apply(.setSpeed(2), sourceDuration: sourceDuration)
        let fast = h.project.timeMap
        #expect(fast.outputDuration == 4)
        #expect(fast.outputTime(forSource: 5) == 1.5)
        #expect(fast.sourceTime(forOutput: 1.5) == 5)
        #expect(fast.sourceTime(forOutput: 99) == 10) // clamps past the end
    }
}

@Suite struct ZoomTimelineTests {
    private let zoomed = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    @Test func easesBetweenFullAndTarget() {
        let t = ZoomTimeline([ZoomKeyframe(time: 1, rect: zoomed, duration: 1)])
        #expect(t.rect(at: 0) == .full)
        #expect(t.rect(at: 1) == .full)
        #expect(abs(t.rect(at: 1.5).width - 0.75) < 1e-9) // ease-in-out is symmetric: halfway at the midpoint
        #expect(t.rect(at: 1.25).width > 0.75) // slow start: less than linear progress
        #expect(t.rect(at: 2) == zoomed && t.rect(at: 50) == zoomed)
    }

    @Test func interruptedTransitionChainsWithoutJump() {
        let other = NormalizedRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4)
        let a = ZoomKeyframe(time: 0, rect: zoomed, duration: 2)
        let b = ZoomKeyframe(time: 1, rect: other, duration: 1)
        let t = ZoomTimeline([b, a]) // order of input does not matter
        let before = t.rect(at: 1 - 1e-9), after = t.rect(at: 1 + 1e-9)
        #expect(abs(before.x - after.x) < 1e-6 && abs(before.width - after.width) < 1e-6)
        #expect(t.rect(at: 2) == other)
    }

    @Test func zeroDurationIsInstant() {
        #expect(ZoomTimeline([ZoomKeyframe(time: 1, rect: zoomed, duration: 0)]).rect(at: 1) == zoomed)
    }
}

@Suite struct AutoZoomTests {
    private func click(_ t: Double, _ x: Double, _ y: Double) -> VideoClickEvent { VideoClickEvent(t: t, x: x, y: y) }

    @Test func nearbyClicksFormOneZoom() {
        let ks = AutoZoom.suggest(clicks: [click(5, 0.3, 0.3), click(5.5, 0.32, 0.31), click(6.2, 0.28, 0.3)], duration: 30)
        #expect(ks.count == 2) // zoom in + zoom out
        let zin = ks[0], zout = ks[1]
        #expect(zin.auto && zin.time < 5 && zin.time >= 4)
        #expect(zin.rect.width == 0.5 && abs((zin.rect.x + zin.rect.width / 2) - 0.3) < 0.02)
        #expect(zout.rect == .full)
        #expect(zout.time - zin.time >= 0.6 + 2.0) // minimum duration: transition plus hold
    }

    @Test func distantClicksSplitAndChain() {
        // Second cluster starts right after the first would zoom out: the zoom-out is skipped and the zooms chain.
        let ks = AutoZoom.suggest(clicks: [click(2, 0.2, 0.2), click(5, 0.8, 0.8)], duration: 30)
        #expect(ks.count == 3)
        #expect(ks[0].rect != .full && ks[1].rect != .full && ks[2].rect == .full)
        let far = AutoZoom.suggest(clicks: [click(2, 0.2, 0.2), click(20, 0.8, 0.8)], duration: 30)
        #expect(far.count == 4)
    }

    @Test func spreadOutClicksDoNotZoomAndBadInputIsIgnored() {
        #expect(AutoZoom.suggest(clicks: [click(1, 0.1, 0.1), click(1.2, 0.3, 0.1), click(1.4, 0.45, 0.1), click(1.6, 0.6, 0.1), click(1.8, 0.8, 0.1)], duration: 30).allSatisfy { $0.rect == .full || $0.rect.width < 0.9 })
        #expect(AutoZoom.suggest(clicks: [click(-1, 0.5, 0.5), click(5, 2, 0.5), click(.nan, 0.5, 0.5), click(99, 0.5, 0.5)], duration: 30).isEmpty)
        #expect(AutoZoom.suggest(clicks: [], duration: 30).isEmpty)
    }

    @Test func rectStaysInsideFrameAndOutputIsDeterministic() {
        let clicks = [click(1, 0.99, 0.01), click(10, 0.01, 0.99)]
        let a = AutoZoom.suggest(clicks: clicks, duration: 30), b = AutoZoom.suggest(clicks: clicks.reversed(), duration: 30)
        #expect(a == b)
        #expect(a.allSatisfy { $0.rect.isValid })
    }

    @Test func autoKeyframesAreReplacedButManualOnesKept() {
        var h = history(30)
        let manual = ZoomKeyframe(time: 9, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        h.apply(.addZoom(manual), sourceDuration: 30)
        h.apply(.setAutoZooms(AutoZoom.suggest(clicks: [click(2, 0.5, 0.5)], duration: 30)), sourceDuration: 30)
        #expect(h.project.zooms.contains(manual) && h.project.zooms.count == 3)
        h.apply(.setAutoZooms([]), sourceDuration: 30)
        #expect(h.project.zooms == [manual])
    }

    @Test func sidecarLoading() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-ev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("source.mp4")
        let sidecar = VideoClickEvents.sidecarURL(forSource: src)
        #expect(VideoClickEvents.load(from: sidecar) == nil) // missing: auto zoom disabled
        try Data(#"{"version":1,"clicks":[{"t":1.5,"x":0.25,"y":0.75}]}"#.utf8).write(to: sidecar)
        #expect(VideoClickEvents.load(from: sidecar) == [VideoClickEvent(t: 1.5, x: 0.25, y: 0.75)])
        try Data(#"{"version":2,"clicks":[]}"#.utf8).write(to: sidecar)
        #expect(VideoClickEvents.load(from: sidecar) == nil)
        try Data("nope".utf8).write(to: sidecar)
        #expect(VideoClickEvents.load(from: sidecar) == nil)
    }
}

@Suite struct VideoProjectPackageTests {
    private func makeLibrary() throws -> (root: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ns-lib-\(UUID().uuidString)")
        let src = root.appendingPathComponent("originals/abc/source.mp4")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src)
        return (root, src)
    }

    private func sample() -> VideoProject {
        var h = history()
        h.apply(.split(at: 5), sourceDuration: sourceDuration)
        h.apply(.addZoom(ZoomKeyframe(time: 1, rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5), curve: .linear)), sourceDuration: sourceDuration)
        h.apply(.setAudio(index: 1, AudioTrackSettings(muted: true, gain: 1.5, fadeIn: 0.5, fadeOut: 1)), sourceDuration: sourceDuration)
        h.apply(.setSpeed(1.5), sourceDuration: sourceDuration)
        return h.project
    }

    private func edit(_ pkg: URL, _ file: String, _ transform: (inout [String: Any]) -> Void) throws {
        let u = pkg.appendingPathComponent(file)
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as! [String: Any]
        transform(&obj)
        try JSONSerialization.data(withJSONObject: obj).write(to: u)
    }

    @Test func roundTrip() throws {
        let (root, src) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("a.nshotvideo")
        let p = sample()
        try VideoProjectPackage.write(p, source: src, sourceDuration: sourceDuration, libraryRoot: root, to: pkg)
        try VideoProjectPackage.write(p, source: src, sourceDuration: sourceDuration, libraryRoot: root, to: pkg) // overwrite
        let opened = try VideoProjectPackage.read(from: pkg, libraryRoot: root)
        #expect(opened.project == p)
        #expect(opened.sourceURL.lastPathComponent == "source.mp4" && opened.sourceDuration == sourceDuration)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: pkg.appendingPathComponent("manifest.json"))) as! [String: Any]
        #expect(manifest["source"] as? String == "originals/abc/source.mp4") // relative, never absolute
    }

    @Test func sourceOutsideLibraryIsRefusedOnWrite() throws {
        let (root, _) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: VideoProjectError.self) {
            try VideoProjectPackage.write(sample(), source: URL(fileURLWithPath: "/etc/hosts"), sourceDuration: 1, libraryRoot: root, to: root.appendingPathComponent("b.nshotvideo"))
        }
    }

    @Test func rejectsCorruptAndMaliciousPackages() throws {
        let (root, src) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("c.nshotvideo")
        func fresh() throws { try? FileManager.default.removeItem(at: pkg); try VideoProjectPackage.write(sample(), source: src, sourceDuration: sourceDuration, libraryRoot: root, to: pkg) }
        func opens() throws { _ = try VideoProjectPackage.read(from: pkg, libraryRoot: root) }

        try fresh()
        try edit(pkg, "manifest.json") { $0["formatVersion"] = 99 }
        #expect(throws: VideoProjectError.unsupportedVersion(99)) { try opens() }
        for bad in ["../outside.mp4", "/etc/hosts", "originals/../../x", "~/x", ""] {
            try fresh()
            try edit(pkg, "manifest.json") { $0["source"] = bad }
            #expect(throws: VideoProjectError.unsafePath(bad)) { try opens() }
        }
        try fresh()
        try edit(pkg, "manifest.json") { $0["source"] = "originals/abc/gone.mp4" }
        #expect(throws: VideoProjectError.missingSource("originals/abc/gone.mp4")) { try opens() }

        try fresh()
        try edit(pkg, "manifest.json") { $0["project"] = "../project.json" }
        #expect(throws: VideoProjectError.self) { try opens() }

        // Values out of range
        for mutate: (inout [String: Any]) -> Void in [
            { $0["speed"] = 0 },
            { $0["speed"] = 1e9 },
            { $0["segments"] = [] },
            { $0["segments"] = [["id": UUID().uuidString, "start": 5.0, "end": 4.0]] },
            { $0["segments"] = [["id": UUID().uuidString, "start": 0.0, "end": 500.0]] },
            { $0["audio"] = [["muted": false, "gain": 50.0, "fadeIn": 0.0, "fadeOut": 0.0]] },
            { $0["zooms"] = [["id": UUID().uuidString, "time": 1.0, "duration": 1.0, "curve": "easeInOut", "auto": false,
                              "rect": ["x": 0.9, "y": 0.0, "width": 0.5, "height": 0.5]]] },
        ] {
            try fresh()
            try edit(pkg, "project.json", mutate)
            #expect(throws: VideoProjectError.self) { try opens() }
        }

        try fresh()
        try Data("{not json".utf8).write(to: pkg.appendingPathComponent("project.json"))
        #expect(throws: VideoProjectError.corrupt("project.json")) { try opens() }
        try fresh()
        try FileManager.default.removeItem(at: pkg.appendingPathComponent("manifest.json"))
        #expect(throws: VideoProjectError.missingFile("manifest.json")) { try opens() }
        #expect(throws: VideoProjectError.notAPackage) { _ = try VideoProjectPackage.read(from: root.appendingPathComponent("nope"), libraryRoot: root) }
    }
}

@Suite struct ExportStateTests {
    private func run(_ events: [ExportEvent]) -> ExportStateMachine {
        var m = ExportStateMachine()
        for e in events { m.handle(e) }
        return m
    }

    @Test func happyPath() {
        #expect(run([.begin, .prepared, .encoded, .written, .validated]).phase == .completed)
    }

    @Test func cancelAndFailFromInFlightPhases() {
        let path: [ExportEvent] = [.begin, .prepared, .encoded, .written]
        for n in 0..<4 { #expect(run(Array(path.prefix(n)) + [.cancel]).phase == .cancelled) }
        for n in 1...4 { #expect(run(Array(path.prefix(n)) + [.fail("x")]).phase == .failed("x")) }
        #expect(run(path + [.cancel]).phase == .validating) // the file is complete: too late to cancel
    }

    @Test func terminalStatesAndInvalidJumps() {
        var m = run([.begin, .cancel])
        for e in [ExportEvent.begin, .prepared, .encoded, .written, .validated, .cancel, .fail("x")] { #expect(!fire(&m, e)) }
        m = ExportStateMachine()
        #expect(!fire(&m, .encoded) && !fire(&m, .validated) && !fire(&m, .fail("x")))
        m.handle(.begin)
        #expect(!fire(&m, .begin) && !fire(&m, .written))
        #expect(m.phase == .preparing)
    }

    @Test func presets() {
        #expect(ExportPreset.messaging.outputSize(width: 1920, height: 1080) == (1280, 720))
        #expect(ExportPreset.messaging.outputSize(width: 640, height: 360) == (640, 360)) // never upscales
        #expect(ExportPreset.highQuality.outputSize(width: 1921, height: 1081) == (1920, 1080)) // even dimensions
        #expect(ExportPreset.custom(maxHeight: 10, videoBitrate: 1).isValid == false)
        #expect(ExportPreset.custom(maxHeight: 540, videoBitrate: 2_000_000).isValid)
        #expect(ExportPreset.reducedSize.estimatedBytes(duration: 8) < ExportPreset.highQuality.estimatedBytes(duration: 8))
    }
}

// MARK: - Composition and export on a synthetic MP4

/// Left half black, right half white, so a crop is observable in the output pixels.
func halfAndHalf(_ w: Int, _ h: Int, at pts: CMTime) -> CMSampleBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb!)
    for y in 0..<h { for x in 0..<w { let v: UInt8 = x < w / 2 ? 0 : 255; let p = base + y * bpr + x * 4; p[0] = v; p[1] = v; p[2] = v; p[3] = 255 } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    var fmt: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb!, formatDescriptionOut: &fmt)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb!, formatDescription: fmt!, sampleTiming: &timing, sampleBufferOut: &sb)
    return sb!
}

func makeSource(in dir: URL, seconds: Double = 3, microphone: Bool = false) async throws -> URL {
    let url = dir.appendingPathComponent("source.mp4")
    let w = try MovieWriter(url: url, width: 320, height: 240, fps: 30, systemAudio: true, microphone: microphone)
    var t = 0.0
    while t < seconds - 1e-9 {
        let pts = CMTime(seconds: 100 + t, preferredTimescale: 48_000)
        w.appendVideo(halfAndHalf(320, 240, at: pts))
        for k in 0..<3 { w.appendSystemAudio(audioSample(frames: 480, channels: 2, at: CMTime(seconds: 100 + t + Double(k) * 0.01, preferredTimescale: 48_000), amplitude: 0.2)) }
        if microphone { w.appendMicrophone(audioSample(frames: 480, channels: 1, at: CMTime(seconds: 100 + t, preferredTimescale: 48_000), amplitude: 0.1)) }
        t += 1.0 / 30
        try await Task.sleep(for: .milliseconds(2))
    }
    _ = try await w.finish()
    return url
}

func pixel(_ cg: CGImage, x: Double, y: Double) -> Int {
    var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let ctx = CGContext(data: &buf, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return Int(buf[(Int(y * Double(cg.height)) * cg.width + Int(x * Double(cg.width))) * 4])
}

func luma(_ url: URL, at seconds: Double, x: Double, y: Double) async throws -> Int {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    return pixel(try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image, x: x, y: y)
}

@Suite struct VideoCompositionTests {
    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ns-vid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func compositionFollowsSegmentsAndSpeed() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSource(in: dir)
        let asset = AVURLAsset(url: src)
        let d = try await asset.load(.duration).seconds
        var h = VideoEditHistory(project: VideoProject(duration: d))
        h.apply(.deleteRange(from: 1, to: 2), sourceDuration: d)
        var c = try await VideoComposer.build(project: h.project, asset: asset)
        #expect(abs(c.outputDuration - (d - 1)) < 0.05)
        #expect(c.audioTrackCount == 1 && c.audioMix != nil)
        h.apply(.setSpeed(2), sourceDuration: d)
        c = try await VideoComposer.build(project: h.project, asset: asset)
        #expect(abs(c.outputDuration - (d - 1) / 2) < 0.05)
    }

    @Test func audioMixCarriesMuteGainAndFades() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let asset = AVURLAsset(url: try await makeSource(in: dir))
        var p = VideoProject(duration: 3)
        p.audio[0] = AudioTrackSettings(muted: false, gain: 0.5, fadeIn: 1, fadeOut: 1)
        let mix = try await VideoComposer.build(project: p, asset: asset).audioMix
        let params = try #require(mix?.inputParameters.first)
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange.zero
        #expect(params.getVolumeRamp(for: CMTime(seconds: 0.5, preferredTimescale: 600), startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(start == 0 && end == 0.5 && abs(range.duration.seconds - 1) < 0.01)
        p.audio[0].muted = true
        let muted = try await VideoComposer.build(project: p, asset: asset).audioMix?.inputParameters.first
        #expect(muted?.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range) == true && end == 0)
    }

    @Test func exportsWithZoomAndPreviewMatches() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSource(in: dir)
        var p = VideoProject(duration: 3)
        let out = dir.appendingPathComponent("out.mp4")

        let progressLog = ProgressLog()
        try await VideoExporter.export(project: p, source: src, preset: .custom(maxHeight: 120, videoBitrate: 500_000), to: out) { p, _ in progressLog.add(p) }
        #expect(progressLog.phases.first == .preparing && progressLog.phases.last == .completed)
        let phases = progressLog.phases
        #expect(zip(phases, phases.dropFirst()).allSatisfy { rank($0) < rank($1) }) // never goes backwards
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 160, height: 120))
        #expect(try await luma(out, at: 1, x: 0.1, y: 0.5) < 60) // no zoom: left side is black
        #expect(try await AVURLAsset(url: out).loadTracks(withMediaType: .audio).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".") }) // temp file gone

        // Zoom into the right half: the same pixel is now white, in the export and in the preview composition.
        p.zooms = [ZoomKeyframe(time: 0, rect: NormalizedRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5), duration: 0)]
        try await VideoExporter.export(project: p, source: src, preset: .custom(maxHeight: 120, videoBitrate: 500_000), to: out) { _, _ in } // overwrites atomically
        #expect(try await luma(out, at: 1, x: 0.1, y: 0.5) > 200)
        let preview = try await VideoComposer.build(project: p, asset: AVURLAsset(url: src))
        let gen = AVAssetImageGenerator(asset: preview.composition)
        gen.videoComposition = preview.videoComposition
        let cg = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        #expect(cg.width == 320 && cg.height == 240)
        #expect(pixel(cg, x: 0.1, y: 0.5) > 200)
    }

    @Test func cancelledExportLeavesNothingBehind() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSource(in: dir)
        let out = dir.appendingPathComponent("never.mp4")
        let log = ProgressLog()
        let task = Task { try await VideoExporter.export(project: VideoProject(duration: 3), source: src, preset: .tutorial, to: out) { p, _ in log.add(p) } }
        task.cancel()
        await #expect(throws: VideoExportError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["source.mp4"])
        #expect(log.phases.last == .cancelled)
    }

    @Test func invalidPresetIsRejectedBeforeAnyWork() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: VideoExportError.self) {
            try await VideoExporter.export(project: VideoProject(duration: 1), source: dir.appendingPathComponent("x.mp4"), preset: .custom(maxHeight: 1, videoBitrate: 1), to: dir.appendingPathComponent("o.mp4")) { _, _ in }
        }
    }
}

private func rank(_ p: ExportPhase) -> Int {
    switch p {
    case .queued: 0
    case .preparing: 1
    case .encoding: 2
    case .writing: 3
    case .validating: 4
    case .completed, .cancelled, .failed: 5
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ExportPhase] = []
    func add(_ p: ExportPhase) {
        lock.withLock { if all.last != p { all.append(p) } }
    }
    var phases: [ExportPhase] { lock.withLock { all } }
}

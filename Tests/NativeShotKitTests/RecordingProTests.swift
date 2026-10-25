import AVFoundation
import CoreMedia
import ImageIO
import Foundation
import Testing
@testable import NativeShotKit

@Suite struct RecordingEventsTests {
    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
    private let frame = CMTime(value: 1, timescale: 30)

    @Test func roundTripAndContractShape() throws {
        let e = RecordingEvents(clicks: [.init(t: 1.5, x: 0.25, y: 0.75)])
        let data = try JSONEncoder().encode(e)
        #expect(try JSONDecoder().decode(RecordingEvents.self, from: data) == e)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(obj.keys) == ["version", "clicks"])
        #expect(obj["version"] as? Int == 1)
        #expect(Set((obj["clicks"] as! [[String: Any]])[0].keys) == ["t", "x", "y"])
    }

    @Test func writesFileNextToSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-ev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try RecordingEvents(clicks: []).write(toFolder: dir)
        let back = try JSONDecoder().decode(RecordingEvents.self, from: Data(contentsOf: dir.appendingPathComponent("events.json")))
        #expect(back.version == 1 && back.clicks.isEmpty)
    }

    @Test func normalizesTopLeftAndRejectsOutside() {
        let r = CGRect(x: 100, y: 200, width: 400, height: 200)
        let n = RecordingEvents.normalize(CGPoint(x: 200, y: 250), in: r)
        #expect(n?.x == 0.25 && n?.y == 0.25)
        #expect(RecordingEvents.normalize(CGPoint(x: 99, y: 250), in: r) == nil)
        #expect(RecordingEvents.normalize(CGPoint(x: 200, y: 400), in: r) == nil)
    }

    @Test func clickTimesSkipPauses() {
        var tl = PauseTimeline()
        _ = tl.video(t(10), frameDuration: frame)
        #expect(tl.event(t(10.5))?.seconds == 0.5)
        tl.pause()
        #expect(tl.event(t(12)) == nil) // clicks while paused are not in the movie
        tl.resume()
        #expect(tl.event(t(20)) == nil) // waiting for the first frame after resume
        let out = tl.video(t(25), frameDuration: frame)! // 14 s paused
        #expect(abs(tl.event(t(26))!.seconds - (out.seconds + 1)) < 0.001)
        #expect(tl.event(t(24)) == nil) // before the resume point
    }
}

@Suite struct KeyChordTests {
    @Test func onlyShortcutsProduceLabels() {
        #expect(KeyChord.label(keyCode: 0, character: "a", modifiers: []) == nil)
        #expect(KeyChord.label(keyCode: 0, character: "A", modifiers: .shift) == nil)
        #expect(KeyChord.label(keyCode: 8, character: "c", modifiers: .command) == "⌘C")
        #expect(KeyChord.label(keyCode: 6, character: "z", modifiers: [.command, .shift]) == "⇧⌘Z")
        #expect(KeyChord.label(keyCode: 123, character: nil, modifiers: [.control, .option]) == "⌃⌥←")
        #expect(KeyChord.label(keyCode: 200, character: nil, modifiers: .command) == nil)
    }
}

@Suite struct GIFExporterTests {
    @Test func frameTimes() {
        #expect(GIFExporter.frameTimes(duration: 2, fps: 10).count == 20)
        #expect(GIFExporter.frameTimes(duration: 0.04, fps: 10) == [0])
        #expect(GIFExporter.frameTimes(duration: 0, fps: 10).isEmpty)
        #expect(GIFExporter.frameTimes(duration: 1, fps: 15).last! < 1)
    }

    private func makeVideo(in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("v.mp4")
        let w = try MovieWriter(url: url, width: 160, height: 120, fps: 30, systemAudio: false, microphone: false)
        for i in 0..<60 {
            w.appendVideo(videoSample(160, 120, at: CMTime(value: Int64(9000 + i), timescale: 30), shade: UInt8(i * 4)))
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = try await w.finish()
        return url
    }

    @Test func syntheticMP4ToGIF() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-gif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeVideo(in: dir)
        let expected = GIFExporter.frameTimes(duration: try await AVURLAsset(url: video).load(.duration).seconds, fps: 10).count
        #expect(expected >= 19)
        let out = dir.appendingPathComponent("o.gif")
        let r = try await GIFExporter.export(video: video, to: out, options: .init(fps: 10, maxWidth: 80))
        #expect(r.frames == expected && r.byteSize > 0 && !r.isLarge)
        let src = CGImageSourceCreateWithURL(out as CFURL, nil)!
        #expect(CGImageSourceGetCount(src) == expected)
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        #expect(img.width == 80)
        let gif = (CGImageSourceCopyProperties(src, nil) as! [CFString: Any])[kCGImagePropertyGIFDictionary] as! [CFString: Any]
        #expect(gif[kCGImagePropertyGIFLoopCount] as? Int == 0)
        #expect(await MovieProbe.info(of: video)?.width == 160)
    }

    @Test func cancellationLeavesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-gif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeVideo(in: dir)
        let out = dir.appendingPathComponent("o.gif")
        let task = Task { try await GIFExporter.export(video: video, to: out, options: .init()) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["v.mp4"], "\(left)")
    }
}

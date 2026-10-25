import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NativeShotKit

private func step(_ m: inout RecorderStateMachine, _ e: RecorderEvent) -> Bool { m.handle(e) }

@Suite struct RecorderStateMachineTests {
    private func run(_ events: [RecorderEvent]) -> RecorderStateMachine {
        var m = RecorderStateMachine()
        for e in events { m.handle(e) }
        return m
    }

    private let toRecording: [RecorderEvent] = [.start, .authorized, .configured, .countdownElapsed]

    @Test func happyPath() {
        var m = run(toRecording)
        #expect(m.phase == .recording)
        for (e, p) in [(RecorderEvent.pause, RecorderPhase.paused), (.resume, .recording), (.stop, .finalizing),
                       (.finalized, .ready), (.reset, .idle)] {
            #expect(step(&m, e))
            #expect(m.phase == p)
        }
    }

    @Test func stopIsIdempotent() {
        var m = run(toRecording + [.stop])
        #expect(m.phase == .finalizing)
        #expect(!step(&m, .stop)) // second click must not finalize twice
        #expect(m.phase == .finalizing)
        m.handle(.finalized)
        #expect(!step(&m, .stop))
        #expect(m.phase == .ready)
    }

    @Test func stopFromPaused() {
        #expect(run(toRecording + [.pause, .stop]).phase == .finalizing)
    }

    @Test func cancelFromEveryActivePhase() {
        for n in 1...5 {
            var m = run(Array((toRecording + [.pause]).prefix(n)))
            #expect(m.isBusy)
            #expect(step(&m, .cancel))
            #expect(m.phase == .cancelled)
            #expect(step(&m, .reset))
        }
        var m = run(toRecording + [.stop])
        #expect(!step(&m, .cancel)) // too late: the file is being sealed
    }

    @Test func failures() {
        var m = run([.start, .fail("sin permiso", recoverable: true)])
        #expect(m.phase == .recoverableFailure("sin permiso"))
        #expect(step(&m, .start)) // retry directly
        #expect(m.phase == .authorizing)
        m = run(toRecording + [.fail("fuente perdida", recoverable: false)])
        #expect(m.phase == .fatalFailure("fuente perdida"))
        #expect(!step(&m, .start))
        #expect(step(&m, .reset) && m.phase == .idle)
        m = run(toRecording + [.stop, .fail("disco", recoverable: false)])
        #expect(m.phase == .fatalFailure("disco"))
    }

    @Test func rejectsInvalidTransitions() {
        var m = RecorderStateMachine()
        for e in [RecorderEvent.authorized, .configured, .countdownElapsed, .pause, .resume, .stop, .finalized, .cancel,
                  .fail("x", recoverable: true), .reset] {
            #expect(!step(&m, e))
            #expect(m.phase == .idle)
        }
        m.handle(.start)
        #expect(!step(&m, .start))
        #expect(!step(&m, .pause))
        #expect(!step(&m, .stop))
        m = run(toRecording)
        #expect(!step(&m, .resume))
        #expect(!step(&m, .start))
        m.handle(.pause)
        #expect(!step(&m, .pause))
    }
}

@Suite struct PauseTimelineTests {
    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
    private let frame = CMTime(value: 1, timescale: 30)

    @Test func startsAtZero() {
        var tl = PauseTimeline()
        #expect(tl.audio(t(99)) == nil) // audio before the first frame is dropped
        #expect(tl.video(t(100), frameDuration: frame) == .zero)
        #expect(tl.audio(t(100.5))?.seconds == 0.5)
    }

    @Test func pauseRemovesGap() {
        var tl = PauseTimeline()
        _ = tl.video(t(10), frameDuration: frame)
        _ = tl.video(t(11), frameDuration: frame) // output 1.0
        tl.pause()
        #expect(tl.video(t(12), frameDuration: frame) == nil)
        #expect(tl.audio(t(12)) == nil)
        tl.resume()
        #expect(tl.audio(t(20)) == nil) // waits for the first video frame
        let out = tl.video(t(25), frameDuration: frame)! // 14 s paused
        #expect(abs(out.seconds - (1 + 1.0 / 30)) < 0.001)
        #expect(tl.audio(t(24.9)) == nil) // stale audio from before the resume point
        #expect(abs(tl.audio(t(25.5))!.seconds - (out.seconds + 0.5)) < 0.001)
    }

    @Test func twoPausesAccumulate() {
        var tl = PauseTimeline()
        _ = tl.video(t(0), frameDuration: frame)
        tl.pause(); tl.resume()
        _ = tl.video(t(5), frameDuration: frame)
        tl.pause(); tl.resume()
        let out = tl.video(t(15), frameDuration: frame)!
        #expect(abs(out.seconds - 2.0 / 30) < 0.001)
    }
}

// MARK: - Synthetic media

private func pixelBuffer(_ w: Int, _ h: Int, shade: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!), Int32(shade), CVPixelBufferGetBytesPerRow(pb!) * h)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

func videoSample(_ w: Int, _ h: Int, at pts: CMTime, shade: UInt8 = 120) -> CMSampleBuffer {
    let pb = pixelBuffer(w, h, shade: shade)
    var fmt: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt!, sampleTiming: &timing, sampleBufferOut: &sb)
    return sb!
}

/// Float32 non-interleaved PCM, like ScreenCaptureKit delivers.
func audioSample(frames: Int, channels: Int, at pts: CMTime, amplitude: Float) -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                   extensions: nil, formatDescriptionOut: &fmt)
    let bytes = frames * channels * 4
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                       offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    let samples = [Float](repeating: amplitude, count: frames * channels)
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: frames,
                                                         presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}

@Suite struct MovieWriterTests {
    @Test func meterReadsPeak() {
        let sb = audioSample(frames: 480, channels: 2, at: .zero, amplitude: 0.5)
        #expect(abs(AudioMeter.peak(sb) - 0.5) < 0.001)
    }

    @Test func writesReadableMP4WithPauseAndAudio() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rec.mp4")
        let w = try MovieWriter(url: url, width: 320, height: 240, fps: 30, systemAudio: true, microphone: true)
        let base = 5000.0
        func at(_ s: Double) -> CMTime { CMTime(seconds: base + s, preferredTimescale: 48_000) }
        var clock = 0.0
        // 1 s recorded, 3 s paused, 1 s recorded: expect ~2 s of output.
        func feed(seconds: Double) {
            let end = clock + seconds
            while clock < end - 1e-9 {
                w.appendVideo(videoSample(320, 240, at: at(clock), shade: UInt8(clock * 50) & 0xFF))
                for k in 0..<3 { // 3 audio chunks of 10 ms... per frame period (~33 ms)
                    let a = at(clock + Double(k) * 0.01)
                    w.appendSystemAudio(audioSample(frames: 480, channels: 2, at: a, amplitude: 0.2))
                    w.appendMicrophone(audioSample(frames: 480, channels: 1, at: a, amplitude: 0.1))
                }
                clock += 1.0 / 30
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        feed(seconds: 1)
        w.pause()
        clock += 3
        w.resume()
        feed(seconds: 1)
        let info = try await w.finish()
        let again = try? await w.finish() // double stop must not crash or corrupt
        #expect(again == nil)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2.0) < 0.25)
        #expect(abs(info.duration - 2.0) < 0.25)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 2)
        #expect(try await asset.load(.isPlayable))
        let size = try await asset.loadTracks(withMediaType: .video)[0].load(.naturalSize)
        #expect(Int(size.width) == 320 && Int(size.height) == 240)
        #expect(info.byteSize > 0)
    }

    @Test func emptyRecordingFailsCleanly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = try MovieWriter(url: dir.appendingPathComponent("rec.mp4"), width: 320, height: 240, fps: 30, systemAudio: false, microphone: false)
        await #expect(throws: MovieWriterError.self) { try await w.finish() }
    }
}

import Foundation
import Testing
@testable import NativeShotKit

/// Synthetic "document": text-like stripes (3 px tall glyph rows grouped in lines, blank gaps between lines).
private struct Page {
    let width: Int
    let rows: [[UInt8]] // gray

    static func text(width: Int, height: Int, seed: UInt64 = 7) -> Page {
        func hash(_ a: Int, _ b: Int) -> UInt64 {
            var x = UInt64(truncatingIfNeeded: a) &* 0x9E3779B97F4A7C15 ^ UInt64(truncatingIfNeeded: b) &* 0xC2B2AE3D27D4EB4F ^ seed
            x ^= x >> 29; x = x &* 0xBF58476D1CE4E5B9; x ^= x >> 32
            return x
        }
        let rows = (0..<height).map { y -> [UInt8] in
            guard y % 18 < 12 else { return [UInt8](repeating: 255, count: width) } // gap between lines
            return (0..<width).map { x in hash(y / 3, x / 6) % 3 == 0 ? 25 : 235 }
        }
        return Page(width: width, rows: rows)
    }

    static func repeating(width: Int, height: Int, period: Int) -> Page {
        let base = text(width: width, height: period)
        return Page(width: width, rows: (0..<height).map { base.rows[$0 % period] })
    }

    /// A viewport onto the page with optional sticky header/footer drawn over it.
    func frame(at y: Int, height: Int, header: Int = 0, footer: Int = 0, bpp: Int = 1, jitter: Bool = false) -> ScrollFrame {
        var data: [UInt8] = []
        data.reserveCapacity(width * height * bpp)
        for r in 0..<height {
            var row: [UInt8]
            if r < header { row = [UInt8](repeating: UInt8(40 + r % 7 * 20), count: width) }
            else if r >= height - footer { row = [UInt8](repeating: UInt8(200 - r % 5 * 30), count: width) }
            else { row = rows[y + r] }
            if jitter { row = row.enumerated().map { UInt8(clamping: Int($0.element) + ($0.offset % 5 == 0 ? 1 : 0)) } }
            for v in row { for c in 0..<bpp { data.append(c == 3 ? 255 : v) } }
        }
        return ScrollFrame(width: width, height: height, bytesPerPixel: bpp, data: data)
    }

    func expected(rows range: Range<Int>, bpp: Int = 1) -> [UInt8] {
        range.flatMap { r in rows[r].flatMap { v in (0..<bpp).map { $0 == 3 ? 255 : v } } }
    }
}

private func joined(_ s: ScrollStitcher) -> [UInt8] { s.finish().flatMap(\.data) }

@Suite struct ScrollStitcherTests {
    @Test func stitchesPlainScroll() {
        let page = Page.text(width: 480, height: 2400)
        var cfg = ScrollConfig(); cfg.maxSegmentHeight = 500 // force several tiles
        var s = ScrollStitcher(config: cfg)
        #expect(s.add(page.frame(at: 0, height: 400)) == .first)
        for y in [120, 250, 380, 505, 640, 700, 900] {
            guard case .appended = s.add(page.frame(at: y, height: 400)) else { Issue.record("no join at \(y)"); return }
        }
        #expect(s.finish().count > 1 && s.finish().allSatisfy { $0.height <= 500 })
        #expect(joined(s) == page.expected(rows: 0..<1300))
    }

    @Test func excludesStickyHeaderAndFooter() {
        let page = Page.text(width: 480, height: 2400)
        let (hh, fh, h) = (60, 40, 400)
        var s = ScrollStitcher()
        _ = s.add(page.frame(at: 0, height: h, header: hh, footer: fh))
        var y = 0
        for step in [110, 130, 90, 150] {
            y += step
            guard case .appended = s.add(page.frame(at: y, height: h, header: hh, footer: fh)) else { Issue.record("no join at \(y)"); return }
        }
        // Header once at the top, body continuous, footer once at the bottom.
        let f0 = page.frame(at: 0, height: h, header: hh, footer: fh)
        let fN = page.frame(at: y, height: h, header: hh, footer: fh)
        let rb = 480
        let expected = Array(f0.data[0..<(hh * rb)]) + page.expected(rows: hh..<(y + h - fh)) + Array(fN.data[((h - fh) * rb)...])
        #expect(joined(s) == expected)
    }

    @Test func largeShiftStillJoins() {
        let page = Page.text(width: 480, height: 2400)
        var s = ScrollStitcher()
        _ = s.add(page.frame(at: 0, height: 400))
        guard case .appended(let n, let c) = s.add(page.frame(at: 300, height: 400)) else { Issue.record("no join"); return }
        #expect(n == 700 && c >= 0.3)
        #expect(joined(s) == page.expected(rows: 0..<700))
    }

    @Test func toleratesSmallPixelNoise() {
        let page = Page.text(width: 480, height: 1200)
        var s = ScrollStitcher()
        _ = s.add(page.frame(at: 0, height: 400))
        guard case .appended = s.add(page.frame(at: 150, height: 400, jitter: true)) else { Issue.record("noise broke the join"); return }
    }

    @Test func repetitiveContentIsAmbiguous() {
        let page = Page.repeating(width: 480, height: 1200, period: 40)
        var s = ScrollStitcher()
        _ = s.add(page.frame(at: 0, height: 400))
        #expect(s.add(page.frame(at: 50, height: 400)) == .rejected(.ambiguous))
        #expect(s.finish().count == 1 && s.finish()[0].height == 400) // nothing was corrupted
    }

    @Test func blankContentIsNotMatched() {
        let blank = Page(width: 480, rows: Array(repeating: [UInt8](repeating: 255, count: 480), count: 1200))
        var s = ScrollStitcher()
        _ = s.add(blank.frame(at: 0, height: 400))
        // Two blank frames are identical: no movement, not a join.
        #expect(s.add(blank.frame(at: 100, height: 400)) == .still)
    }

    @Test func noOverlapFailsExplicitly() {
        let page = Page.text(width: 480, height: 2400)
        var s = ScrollStitcher()
        _ = s.add(page.frame(at: 0, height: 400))
        #expect(s.add(page.frame(at: 900, height: 400)) == .rejected(.noOverlap))
        #expect(s.rejectedFrames == 1)
        // A later frame that does overlap the last accepted one still joins.
        guard case .appended = s.add(page.frame(at: 200, height: 400)) else { Issue.record("recovery failed"); return }
        #expect(joined(s) == page.expected(rows: 0..<600))
    }

    @Test func identicalFramesMeanNoMovement() {
        let page = Page.text(width: 480, height: 800)
        var s = ScrollStitcher()
        _ = s.add(page.frame(at: 0, height: 400))
        #expect(s.add(page.frame(at: 0, height: 400)) == .still)
        _ = s.add(page.frame(at: 100, height: 400))
        #expect(s.add(page.frame(at: 100, height: 400)) == .still)
    }

    @Test func scrollingBackAndForthDoesNotDuplicate() {
        let page = Page.text(width: 480, height: 2400)
        var s = ScrollStitcher()
        _ = s.add(page.frame(at: 0, height: 400))
        _ = s.add(page.frame(at: 150, height: 400))
        #expect(s.add(page.frame(at: 60, height: 400)) == .scrolledBack)
        _ = s.add(page.frame(at: 200, height: 400))
        _ = s.add(page.frame(at: 330, height: 400))
        #expect(joined(s) == page.expected(rows: 0..<730))
    }

    @Test func memoryLimitStopsAccumulating() {
        let page = Page.text(width: 480, height: 2400)
        var cfg = ScrollConfig(); cfg.maxTotalBytes = 480 * 600
        var s = ScrollStitcher(config: cfg)
        _ = s.add(page.frame(at: 0, height: 400))
        _ = s.add(page.frame(at: 150, height: 400)) // 550 rows stored
        #expect(s.add(page.frame(at: 300, height: 400)) == .limitReached)
        #expect(joined(s).count <= 480 * 700)
    }

    @Test func mismatchedSizeIsRejected() {
        let page = Page.text(width: 480, height: 800)
        var s = ScrollStitcher()
        _ = s.add(page.frame(at: 0, height: 400))
        #expect(s.add(page.frame(at: 0, height: 300)) == .rejected(.sizeMismatch))
    }

    @Test func joinTimeOnRetinaSizedRegion() {
        // 1500x1000 RGBA with sticky header: a typical large window region at 1x, half a 2x screen.
        let page = Page.text(width: 1500, height: 3000)
        let a = page.frame(at: 0, height: 1000, header: 80, bpp: 4)
        let b = page.frame(at: 237, height: 1000, header: 80, bpp: 4)
        var s = ScrollStitcher()
        _ = s.add(a)
        let t = ContinuousClock().measure {
            let r = s.add(b)
            if case .appended = r {} else { Issue.record("no join: \(r)") }
        }
        print("scroll join 1500x1000 RGBA:", t)
        #expect(t < .seconds(5)) // debug-build ceiling; release is far lower
        #expect(s.height == 1237)
    }
}

/// Regression (QA self-test, 2026-10-25): rows of thick solid bars made the ±1 px shifts score almost as high as the
/// true one, so every real scroll was rejected as ambiguous.
@Test func thickBlocksAreNotAmbiguous() {
    let w = 320, rowH = 88, viewport = 800
    func page(offset: Int) -> ScrollFrame {
        var d = [UInt8](repeating: 255, count: w * viewport)
        for y in 0..<viewport {
            let docY = y + offset, r = docY / rowH, inRow = docY % rowH
            guard inRow >= 20, inRow < 68 else { continue } // 48 px tall bars
            for b in 0..<5 {
                let x0 = 40 + b * 56, bw = 20 + (r * 37 + b * 53) % 34
                for x in x0..<min(w, x0 + bw) { d[y * w + x] = UInt8(40 + (r * 29 + b * 47) % 160) }
            }
        }
        return ScrollFrame(width: w, height: viewport, bytesPerPixel: 1, data: d)
    }
    var s = ScrollStitcher()
    _ = s.add(page(offset: 0))
    let r = s.add(page(offset: 160))
    guard case .appended = r else { Issue.record("rejected: \(r)"); return }
    #expect(s.height == 960)
}

/// Regression (QA self-test, 2026-10-25): the rounded bottom corners of a window at the end of every frame were
/// stitched into the middle of the image at each join.
@Test func frameEdgeArtifactsDoNotSurviveJoins() {
    let w = 320, viewport = 400, corner = 16
    func page(offset: Int) -> ScrollFrame {
        var d = [UInt8](repeating: 255, count: w * viewport)
        for y in 0..<viewport {
            let docY = y + offset, r = docY / 44, inRow = docY % 44
            if inRow >= 10, inRow < 34 {
                for b in 0..<5 {
                    let x0 = 40 + b * 56, bw = 20 + (r * 37 + b * 53) % 34
                    for x in x0..<min(w, x0 + bw) { d[y * w + x] = UInt8(40 + (r * 29 + b * 47) % 160) }
                }
            }
            if y >= viewport - corner { for x in 0..<6 { d[y * w + x] = 0 } } // dark rounded-corner pixels
        }
        return ScrollFrame(width: w, height: viewport, bytesPerPixel: 1, data: d)
    }
    var s = ScrollStitcher()
    for off in stride(from: 0, through: 400, by: 100) { _ = s.add(page(offset: off)) }
    // Scroll back and forward again (crashed once: the committed end lay outside the new frame).
    for off in [300, 200, 300, 400] { _ = s.add(page(offset: off)) }
    guard let img = s.finish().first else { Issue.record("no output"); return }
    #expect(img.height == 800)
    let body = img.height - corner // the real bottom of the last frame keeps its corner
    let dark = (0..<body).filter { img.data[$0 * w] == 0 }
    #expect(dark.isEmpty, "corner pixels inside the image at rows \(dark.prefix(5))")
}

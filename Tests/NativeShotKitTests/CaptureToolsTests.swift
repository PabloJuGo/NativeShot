import CoreGraphics
import Foundation
import Testing
@testable import NativeShotKit

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

@Suite struct RegionEditorTests {
    @Test func createsFreeRectInAnyDirection() {
        var e = RegionEditor()
        e.begin(at: CGPoint(x: 300, y: 300), tolerance: 8, bounds: screen)
        e.update(to: CGPoint(x: 100, y: 200), ratio: nil, bounds: screen)
        e.end()
        #expect(e.rect == CGRect(x: 100, y: 200, width: 200, height: 100))
    }

    @Test func clickWithoutDragDiscards() {
        var e = RegionEditor()
        e.begin(at: CGPoint(x: 50, y: 50), tolerance: 8, bounds: screen)
        e.end()
        #expect(e.rect == nil)
    }

    @Test func movesInsideAndStaysOnScreen() {
        var e = RegionEditor(rect: CGRect(x: 100, y: 100, width: 200, height: 100))
        e.begin(at: CGPoint(x: 200, y: 150), tolerance: 8, bounds: screen)
        e.update(to: CGPoint(x: 5000, y: 150), ratio: nil, bounds: screen)
        e.end()
        #expect(e.rect == CGRect(x: 800, y: 100, width: 200, height: 100))
    }

    @Test func cornerHandleResizesFromOppositeCorner() {
        var e = RegionEditor(rect: CGRect(x: 100, y: 100, width: 200, height: 100))
        e.begin(at: CGPoint(x: 302, y: 201), tolerance: 8, bounds: screen)
        e.update(to: CGPoint(x: 400, y: 300), ratio: nil, bounds: screen)
        #expect(e.rect == CGRect(x: 100, y: 100, width: 300, height: 200))
    }

    @Test func edgeHandleChangesOneSideOnly() {
        var e = RegionEditor(rect: CGRect(x: 100, y: 100, width: 200, height: 100))
        e.begin(at: CGPoint(x: 100, y: 150), tolerance: 8, bounds: screen)
        e.update(to: CGPoint(x: 40, y: 400), ratio: nil, bounds: screen)
        #expect(e.rect == CGRect(x: 40, y: 100, width: 260, height: 100))
    }

    @Test func fixedRatioHoldsWhileDraggingAndFitsScreen() {
        var e = RegionEditor()
        e.begin(at: CGPoint(x: 100, y: 100), tolerance: 8, bounds: screen)
        e.update(to: CGPoint(x: 420, y: 150), ratio: 16.0 / 9, bounds: screen)
        let r = e.rect!
        #expect(abs(r.width / r.height - 16.0 / 9) < 0.001)
        e.update(to: CGPoint(x: 5000, y: 5000), ratio: 1, bounds: screen)
        #expect(e.rect!.width == e.rect!.height)
        #expect(screen.contains(e.rect!))
    }

    @Test func edgeResizeWithRatioKeepsRatio() {
        let r = RegionEditor.resized(CGRect(x: 100, y: 100, width: 200, height: 100), handle: .right, to: CGPoint(x: 500, y: 0), ratio: 2, bounds: screen)
        #expect(r.width == 400 && r.height == 200 && r.midY == 150)
    }

    @Test func exactSizeKeepsOriginAndClamps() {
        let r = CGRect(x: 900, y: 700, width: 50, height: 50)
        #expect(RegionEditor.resized(r, toSize: CGSize(width: 200, height: 100), bounds: screen) == CGRect(x: 800, y: 700, width: 200, height: 100))
        #expect(RegionEditor.resized(r, toSize: CGSize(width: 0, height: 100), bounds: screen) == nil)
    }

    @Test func parsesTypedSizes() {
        #expect(RegionEditor.parseSize("1280x720") == CGSize(width: 1280, height: 720))
        #expect(RegionEditor.parseSize(" 800 × 600 ") == CGSize(width: 800, height: 600))
        #expect(RegionEditor.parseSize("800") == nil)
        #expect(RegionEditor.parseSize("0x5") == nil)
        #expect(AspectPreset.sixteenNine.ratio == 16.0 / 9 && AspectPreset.free.ratio == nil)
    }

    @Test func notchBandIsRemovedFromTheTop() {
        let r = DisplayGeometry.excludingTop(CGRect(x: 0, y: 0, width: 1512, height: 982), inset: 38)
        #expect(r == CGRect(x: 0, y: 38, width: 1512, height: 944))
        #expect(DisplayGeometry.excludingTop(CGRect(x: 0, y: 0, width: 10, height: 10), inset: 500).height == 1)
    }
}

@Suite struct LoupeAndCompositionTests {
    @Test func loupeSourceSlidesInsideTheImage() {
        #expect(Loupe.sourceRect(centerX: 0, y: 0, side: 15, imageWidth: 100, imageHeight: 100) == CGRect(x: 0, y: 0, width: 15, height: 15))
        #expect(Loupe.sourceRect(centerX: 99, y: 50, side: 15, imageWidth: 100, imageHeight: 100) == CGRect(x: 85, y: 43, width: 15, height: 15))
        #expect(Loupe.hex(r: 255, g: 0, b: 10) == "#FF000A")
    }

    @Test func compositionStacksWithSpacing() {
        let l = RegionComposition.layout(sizes: [(100, 50), (80, 30)], spacing: 16)
        #expect(l.width == 100 && l.height == 96 && l.origins == [0, 66])
        let img = { (w: Int, h: Int) -> CGImage in
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return c.makeImage()!
        }
        let out = RegionComposition.compose([img(100, 50), img(80, 30)])
        #expect(out?.width == 100 && out?.height == 96)
        #expect(RegionComposition.compose([]) == nil)
    }
}

@Suite struct HorizontalScrollAndPDFTests {
    @Test func transposeIsItsOwnInverse() {
        let f = ScrollFrame(width: 3, height: 2, bytesPerPixel: 1, data: [1, 2, 3, 4, 5, 6])
        let t = f.transposed()
        #expect(t.width == 2 && t.height == 3 && t.data == [1, 4, 2, 5, 3, 6])
        #expect(t.transposed() == f)
    }

    @Test func horizontalStitchRebuildsTheWidePage() {
        // Wide "page": 400 columns of per-column pseudo-texture, viewport 160 wide, scrolling 40 columns per step.
        let height = 60, total = 400
        func hash(_ a: Int, _ b: Int) -> UInt64 {
            var h = UInt64(truncatingIfNeeded: a) &* 0x9E3779B97F4A7C15 ^ UInt64(truncatingIfNeeded: b) &* 0xC2B2AE3D27D4EB4F
            h ^= h >> 29; h = h &* 0xBF58476D1CE4E5B9; h ^= h >> 32
            return h
        }
        func column(_ x: Int) -> [UInt8] { (0..<height).map { y in hash(x / 2, y / 3) % 3 == 0 ? 25 : 235 } }
        func view(at x0: Int) -> ScrollFrame {
            var data: [UInt8] = []
            for y in 0..<height { for x in x0..<(x0 + 160) { data.append(column(x)[y]) } }
            return ScrollFrame(width: 160, height: height, bytesPerPixel: 1, data: data)
        }
        var s = ScrollStitcher(axis: .horizontal)
        for x0 in stride(from: 0, through: 240, by: 40) { _ = s.add(view(at: x0)) }
        let out = s.finish()
        #expect(out.count == 1)
        #expect(out[0].height == height)
        #expect(out[0].width == 400)
        #expect(out[0] == { var d: [UInt8] = []; for y in 0..<height { for x in 0..<total { d.append(column(x)[y]) } }; return ScrollFrame(width: total, height: height, bytesPerPixel: 1, data: d) }())
    }

    @Test func pageRangesCoverEverything() {
        let r = ScrollPDF.pageRanges(total: 2500, pageLength: 1000)
        #expect(r == [0..<1000, 1000..<2000, 2000..<2500])
        #expect(ScrollPDF.pageRanges(total: 0, pageLength: 10).isEmpty)
    }

    @Test func pdfHasOnePagePerRangeAcrossTiles() throws {
        func img(_ w: Int, _ h: Int) -> CGImage {
            let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(CGColor(gray: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return c.makeImage()!
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        // 100 px wide → pages of 141 px; 300 + 200 = 500 rows in two tiles → 4 pages.
        try ScrollPDF.write(parts: [img(100, 300), img(100, 200)], axis: .vertical, scale: 2, to: url)
        let doc = try #require(CGPDFDocument(url as CFURL))
        #expect(doc.numberOfPages == 4)
        #expect(throws: ScrollPDF.PDFError.self) { try ScrollPDF.write(parts: [], axis: .vertical, scale: 1, to: url) }
    }
}

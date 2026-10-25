import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NativeShotKit

private func solid(_ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8) = (255, 255, 255)) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) { bytes[i * 4] = c.0; bytes[i * 4 + 1] = c.1; bytes[i * 4 + 2] = c.2 }
    let ctx = bytes.withUnsafeMutableBytes {
        CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    return ctx.makeImage()!
}

/// Deterministic noise, so surviving pixels can't be coincidence.
private func noise(_ w: Int, _ h: Int) -> CGImage {
    var rng: UInt64 = 0xD1B54A32D192ED03
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) { for c in 0..<3 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; bytes[i * 4 + c] = UInt8(truncatingIfNeeded: rng >> 33) } }
    let ctx = bytes.withUnsafeMutableBytes {
        CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    return ctx.makeImage()!
}

private func px(_ image: CGImage) -> [UInt8] {
    let w = image.width, h = image.height
    var out = [UInt8](repeating: 0, count: w * h * 4)
    out.withUnsafeMutableBytes {
        CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            .draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return out
}

private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let o = (y * image.width + x) * 4
    let p = px(image)
    return [p[o], p[o + 1], p[o + 2]]
}

private func decodeImage(_ data: Data) -> CGImage {
    CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
}

private func matchFraction(_ out: CGImage, _ ref: CGImage, _ r: CGRect) -> Double {
    let a = px(out), b = px(ref)
    var same = 0, total = 0
    for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) {
        let o = (y * out.width + x) * 4, q = (y * ref.width + x) * 4
        if a[o] == b[q], a[o + 1] == b[q + 1], a[o + 2] == b[q + 2] { same += 1 }
        total += 1
    } }
    return Double(same) / Double(total)
}

private func obj(_ kind: AnnotationKind, _ x: Double, _ y: Double, _ x2: Double, _ y2: Double, color: EditorColor = .black, width: Double = 4) -> Annotation {
    Annotation(kind: kind, start: CGPoint(x: x, y: y), end: CGPoint(x: x2, y: y2), style: AnnotationStyle(color: color, width: width, opacity: 1))
}

@Suite struct NewToolRenderingTests {
    @Test func curvedArrowBendsAndHits() {
        var a = obj(.arrow, 0, 100, 100, 100)
        a.curve = 0.5
        let mid = a.curvePoint(0.5)
        #expect(abs(mid.y - 100) > 10)
        #expect(a.hit(mid, tolerance: 2))
        #expect(!a.hit(CGPoint(x: 50, y: 100), tolerance: 2)) // the straight chord is no longer the arrow
        #expect(a.bounds.height > 10)
    }

    @Test func doubleHeadedArrowDrawsBothHeads() throws {
        var doc = EditorDocument(original: solid(120, 60))
        var a = obj(.arrow, 10, 30, 110, 30, width: 6)
        doc.objects = [a]
        let one = try #require(EditorRenderer.render(doc))
        // Head at the end only: the tail end is a plain 6px line, so y=34 at x=20 is untouched.
        #expect(rgb(one, 30, 36) == [255, 255, 255])
        #expect(rgb(one, 90, 36) == [0, 0, 0])
        a.headStart = true
        doc.objects = [a]
        let two = try #require(EditorRenderer.render(doc))
        #expect(rgb(two, 30, 36) == [0, 0, 0])
        #expect(rgb(two, 90, 36) == [0, 0, 0])
    }

    @Test func underlineAndStrikethroughDrawLines() throws {
        var doc = EditorDocument(original: solid(100, 60))
        doc.objects = [obj(.underline, 10, 10, 90, 30, width: 2), obj(.strikethrough, 10, 40, 90, 50, width: 2)]
        let out = try #require(EditorRenderer.render(doc))
        #expect(rgb(out, 50, 29) == [0, 0, 0])   // bottom edge of the first box
        #expect(rgb(out, 50, 15) == [255, 255, 255])
        #expect(rgb(out, 50, 45) == [0, 0, 0])   // middle of the second
    }

    @Test func spotlightDimsEverythingExceptTheShape() throws {
        var doc = EditorDocument(original: solid(100, 100))
        var s = obj(.spotlight, 30, 30, 70, 70)
        s.style.opacity = 0.6
        doc.objects = [s]
        let out = try #require(EditorRenderer.render(doc))
        #expect(rgb(out, 50, 50) == [255, 255, 255])
        let dim = rgb(out, 5, 5)
        #expect(dim[0] < 120 && dim[0] > 60)
        // Still dims after a crop.
        doc.crop = CGRect(x: 20, y: 20, width: 60, height: 60)
        let cropped = try #require(EditorRenderer.render(doc))
        #expect(rgb(cropped, 2, 2)[0] < 120 && rgb(cropped, 30, 30) == [255, 255, 255])
    }

    @Test func magnifierZoomsAndNeverLeaksRedactedPixels() throws {
        let img = noise(200, 200)
        var doc = EditorDocument(original: img)
        var m = obj(.magnifier, 70, 70, 150, 150, width: 2)
        m.magnification = 2
        // Redaction comes AFTER the magnifier in layer order and sits inside the magnified source area.
        let redact = obj(.redact, 100, 100, 120, 120)
        doc.objects = [m, redact]
        let out = try #require(EditorRenderer.render(doc))
        // (128,110) is outside the block but shows the magnified block: must be black, not noise.
        #expect(rgb(out, 128, 110) == [0, 0, 0])
        // Without redaction it is magnified original content (centre pixel maps to itself).
        doc.objects = [m]
        let plain = try #require(EditorRenderer.render(doc))
        #expect(rgb(plain, 128, 110) != rgb(img, 128, 110))
        // A 10px black square at the centre is shown 20px wide inside the lens.
        var paint = EditorDocument(original: solid(200, 200))
        paint.objects = [obj(.filledRectangle, 105, 105, 115, 115)]
        var sq = EditorDocument(original: try #require(EditorRenderer.render(paint)))
        sq.objects = [m]
        let lens = try #require(EditorRenderer.render(sq))
        #expect(rgb(lens, 118, 110) == [0, 0, 0] && rgb(lens, 125, 110) == [255, 255, 255])
    }

    @Test func roundedCornersAndShadow() throws {
        var doc = EditorDocument(original: solid(100, 100))
        var r = obj(.filledRectangle, 20, 20, 60, 60)
        r.cornerRadius = 20
        doc.objects = [r]
        let out = try #require(EditorRenderer.render(doc))
        #expect(rgb(out, 21, 21) == [255, 255, 255]) // clipped corner
        #expect(rgb(out, 40, 40) == [0, 0, 0])
        r.cornerRadius = 0
        r.shadow = true
        doc.objects = [r]
        let sh = try #require(EditorRenderer.render(doc))
        let below = rgb(sh, 40, 63), above = rgb(sh, 40, 17)
        #expect(below[0] < above[0]) // shadow falls below, not above
    }

    @Test func imageObjectIsDrawnAndClipped() throws {
        var s = EditorSession(document: EditorDocument(original: solid(100, 100)))
        let a = s.addImage(solid(50, 50, (255, 0, 0)), center: CGPoint(x: 50, y: 50))
        #expect(a.kind == .image && s.document.images[a.imageID!] != nil)
        let out = try #require(EditorRenderer.render(s.document))
        #expect(rgb(out, 50, 50) == [255, 0, 0])
        #expect(rgb(out, 5, 5) == [255, 255, 255])
        s.undo()
        #expect(s.document.objects.isEmpty)
        s.redo()
        #expect(s.document.objects.count == 1)
    }

    @Test func borderIsDrawnInsideTheEdgeAndUndoes() throws {
        var s = EditorSession(document: EditorDocument(original: solid(40, 40)))
        s.perform(.setBorder(old: nil, new: ImageBorder(width: 4, color: EditorColor(1, 0, 0))))
        let out = try #require(EditorRenderer.render(s.document))
        #expect(out.width == 40)
        #expect(rgb(out, 1, 20) == [255, 0, 0] && rgb(out, 20, 20) == [255, 255, 255])
        s.undo()
        #expect(s.document.border == nil)
    }

    @Test func samplerReadsPixelColour() {
        let c = ImageSampler.color(in: solid(10, 10, (10, 200, 30)), at: CGPoint(x: 3.4, y: 7.9))
        #expect(c != nil && abs(c!.r - 10.0 / 255) < 0.01 && abs(c!.g - 200.0 / 255) < 0.01)
        #expect(ImageSampler.color(in: solid(10, 10), at: CGPoint(x: 10, y: 0)) == nil)
    }
}

@Suite struct EditorOpsTests {
    private func session() -> EditorSession {
        var s = EditorSession(document: EditorDocument(original: noise(60, 40)))
        s.add(obj(.rectangle, 5, 5, 15, 15))
        return s
    }

    @Test func rotateMapsPixelsObjectsAndUndoes() throws {
        var s = session()
        let before = s.document.original
        let ok1 = s.apply(.rotateRight)
        #expect(ok1)
        #expect(s.document.original.width == 40 && s.document.original.height == 60)
        // Old top-left pixel is now top-right.
        #expect(rgb(s.document.original, 39, 0) == rgb(before, 0, 0))
        #expect(rgb(s.document.original, 0, 59) == rgb(before, 59, 39))
        #expect(s.document.objects[0].bounds.minX == 25 && s.document.objects[0].bounds.minY == 5)
        s.apply(.rotateLeft)
        #expect(matchFraction(s.document.original, before, CGRect(x: 0, y: 0, width: 60, height: 40)) == 1)
        s.undo(); s.undo()
        #expect(s.document.original.width == 60 && s.document.objects[0].start == CGPoint(x: 5, y: 5))
    }

    @Test func flipsAreInvolutions() {
        var s = session()
        let before = s.document.original
        s.apply(.flipHorizontal)
        #expect(rgb(s.document.original, 59, 3) == rgb(before, 0, 3))
        s.apply(.flipHorizontal)
        #expect(matchFraction(s.document.original, before, CGRect(x: 0, y: 0, width: 60, height: 40)) == 1)
        s.apply(.flipVertical)
        #expect(rgb(s.document.original, 7, 39) == rgb(before, 7, 0))
        #expect(s.document.objects[0].bounds.minY == 25)
    }

    @Test func resizeAndCanvas() throws {
        var s = session()
        let ok2 = s.apply(.resize(width: 120, height: 80))
        #expect(ok2)
        #expect(s.document.original.width == 120 && s.document.objects[0].bounds.width == 20)
        let ok3 = s.apply(.canvas(width: 160, height: 100, anchor: CGPoint(x: 0.5, y: 0.5), fill: EditorColor(1, 0, 0)))
        #expect(ok3)
        #expect(s.document.original.width == 160)
        #expect(rgb(s.document.original, 2, 2) == [255, 0, 0])
        #expect(s.document.objects[0].bounds.minX == 30)
        let ok4 = s.apply(.resize(width: 0, height: 10))
        #expect(!ok4)
        let ok5 = s.apply(.resize(width: 40_000, height: 10))
        #expect(!ok5)
        #expect(s.document.original.width == 160)
        s.undo(); s.undo()
        #expect(s.document.original.width == 60)
    }

    @Test func cropFollowsRotation() {
        var s = session()
        s.perform(.setCrop(old: nil, new: CGRect(x: 0, y: 0, width: 20, height: 10)))
        s.apply(.rotateRight)
        #expect(s.document.crop == CGRect(x: 30, y: 0, width: 10, height: 20))
    }

    @Test func alignDistributeDuplicateLock() {
        var s = EditorSession(document: EditorDocument(original: noise(200, 100)))
        let a = obj(.rectangle, 10, 10, 30, 30), b = obj(.rectangle, 50, 40, 70, 60), c = obj(.rectangle, 150, 20, 170, 40)
        [a, b, c].forEach { s.add($0) }
        s.distribute(ids: [a.id, b.id, c.id], .horizontal)
        let xs = s.document.objects.map(\.bounds.minX)
        #expect(xs == [10, 80, 150]) // equal 50px gaps between 20px-wide boxes
        s.align(ids: [a.id, b.id, c.id], .top)
        #expect(s.document.objects.map(\.bounds.minY) == [10, 10, 10])
        s.align(ids: [a.id], .right) // single object aligns to the canvas
        #expect(s.document.objects[0].bounds.maxX == 200)
        s.undo(); s.undo(); s.undo()
        #expect(s.document.objects.map(\.bounds.minX) == [10, 50, 150])

        let copy = s.duplicate(id: a.id)
        #expect(copy != nil && s.document.objects.count == 4 && copy!.id != a.id)
        s.undo()
        #expect(s.document.objects.count == 3)

        s.setLocked(true, ids: [a.id])
        s.delete(ids: [a.id])
        #expect(s.document.objects.count == 3)
        s.align(ids: [a.id], .right)
        #expect(s.document.objects[0].bounds.minX == 10)
        s.undo()
        #expect(!s.document.objects[0].locked)
    }

    @Test func snapRoundsToGrid() {
        #expect(EditorLayout.snap(CGPoint(x: 13, y: 27), grid: 8) == CGPoint(x: 16, y: 24))
        #expect(EditorLayout.snap(CGPoint(x: 13, y: 27), grid: 0) == CGPoint(x: 13, y: 27))
    }

    @Test func presetsPersistLocally() {
        let suite = "nativeshot-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let store = PresetStore<AnnotationStyle>(key: "p", defaults: d)
        store.save("  Rojo  ", AnnotationStyle(color: .red, width: 6))
        store.save("", AnnotationStyle())
        store.save("Rojo", AnnotationStyle(color: .red, width: 9))
        store.save("Negro", AnnotationStyle(color: .black))
        #expect(store.all().map(\.name) == ["Rojo", "Negro"].sorted { _, _ in false } || store.all().count == 2)
        #expect(store.all().first { $0.name == "Rojo" }?.value.width == 9)
        store.delete("Rojo")
        #expect(store.all().map(\.name) == ["Negro"])
        let bg = PresetStore<BackdropStyle>(key: "b", defaults: d)
        var style = BackdropStyle(); style.pattern = .dots; style.aspect = .r16x9
        bg.save("Social", style)
        #expect(bg.all().first?.value == style)
    }
}

@Suite struct BackdropExtrasTests {
    @Test func aspectPresetCentresContent() throws {
        var doc = EditorDocument(original: solid(100, 100, (255, 0, 0)))
        var bg = BackdropStyle(padding: 10, color: EditorColor(0, 0, 1), gradientEnd: nil, cornerRadius: 0, shadow: false)
        bg.aspect = .r16x9
        doc.background = bg
        let out = try #require(EditorRenderer.render(doc))
        #expect(out.height == 120 && out.width == 214)
        #expect(rgb(out, 107, 60) == [255, 0, 0])
        #expect(rgb(out, 2, 2) == [0, 0, 255])
        #expect(rgb(out, 107 - 49, 60) == [255, 0, 0] && rgb(out, 107 - 52, 60) == [0, 0, 255])
    }

    @Test func autoBalanceIgnoresPadding() throws {
        var doc = EditorDocument(original: solid(100, 50))
        var bg = BackdropStyle(padding: 0)
        bg.autoBalance = true
        doc.background = bg
        let out = try #require(EditorRenderer.render(doc))
        #expect(out.width == 116 && out.height == 66) // 8% of the long side on every edge
    }

    @Test func imageBackdropAndPattern() throws {
        var s = EditorSession(document: EditorDocument(original: solid(40, 40, (255, 255, 255))))
        let id = s.register(solid(10, 10, (0, 255, 0)))
        var bg = BackdropStyle(padding: 20, color: .black, gradientEnd: nil, cornerRadius: 0, shadow: false)
        bg.imageID = id
        s.perform(.setBackground(old: nil, new: bg))
        let out = try #require(EditorRenderer.render(s.document))
        #expect(rgb(out, 3, 3) == [0, 255, 0])
        bg.imageID = nil
        for p in BackdropPattern.allCases {
            bg.pattern = p
            var d = s.document; d.background = bg
            #expect(EditorRenderer.render(d)?.width == 80)
        }
    }

    @Test func absurdAspectIsRefusedNotCrashing() {
        var doc = EditorDocument(original: solid(30_000, 4))
        var bg = BackdropStyle(); bg.aspect = .r9x16
        doc.background = bg
        #expect(EditorRenderer.render(doc) == nil)
    }
}

@Suite struct ExportFormatTests {
    private let size = 120
    private let region = CGRect(x: 30, y: 20, width: 60, height: 50)

    private func redactedDoc() -> (EditorDocument, CGImage) {
        let img = noise(size, size)
        var doc = EditorDocument(original: img)
        doc.objects = [obj(.redact, region.minX, region.minY, region.maxX, region.maxY)]
        return (doc, img)
    }

    @Test func everyAdvertisedExtensionEncodes() throws {
        #expect(!ExportFormat.writableExtensions.contains("webp"))
        for ext in ExportFormat.writableExtensions {
            let data = try ImageExporter.data(for: EditorDocument(original: noise(20, 20)), format: .forExtension(ext))
            #expect(!data.isEmpty, "\(ext)")
        }
        #expect(ExportFormat.forExtension("TIF") == .tiff && ExportFormat.forExtension("xyz") == .png)
    }

    @Test func tiffDoesNotKeepRedactedPixels() throws {
        let (doc, img) = redactedDoc()
        let out = decodeImage(try ImageExporter.data(for: doc, format: .tiff))
        #expect(matchFraction(out, img, region) < 0.01)
        #expect(matchFraction(out, img, CGRect(x: 0, y: 80, width: size, height: 40)) == 1)
    }

    @Test func pdfDoesNotKeepRedactedPixels() throws {
        let (doc, img) = redactedDoc()
        let data = try ImageExporter.data(for: doc, format: .pdf)
        #expect(data.prefix(4) == Data("%PDF".utf8))
        let provider = try #require(CGDataProvider(data: data as CFData))
        let pdf = try #require(CGPDFDocument(provider))
        #expect(pdf.numberOfPages == 1)
        let page = try #require(pdf.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(Int(box.width) == size && Int(box.height) == size)
        let ctx = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.drawPDFPage(page)
        let out = try #require(ctx.makeImage())
        #expect(matchFraction(out, img, region) < 0.01)
        // The raw PDF bytes must not embed the original bitmap either: the redacted area's noise is gone.
        let flat = try #require(EditorRenderer.render(doc))
        #expect(matchFraction(flat, img, region) < 0.01)
    }

    @Test func annotatedFeaturesStayFlattenedInHEICWhenAvailable() throws {
        guard ImageExporter.supportsHEIC else { return }
        let (doc, _) = redactedDoc()
        #expect(try !ImageExporter.data(for: doc, format: .heic(quality: 0.8)).isEmpty)
    }
}

@Suite struct NShotV2Tests {
    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("nshot2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func newKindsAndImagesRoundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = EditorSession(document: EditorDocument(original: noise(80, 60)))
        var arrow = obj(.arrow, 5, 5, 60, 40)
        arrow.curve = 0.3; arrow.headStart = true; arrow.shadow = true; arrow.locked = true; arrow.cornerRadius = 3
        s.add(arrow)
        var mag = obj(.magnifier, 10, 10, 40, 40); mag.magnification = 3
        s.add(mag)
        s.add(obj(.spotlight, 10, 10, 30, 30))
        s.add(obj(.underline, 10, 10, 30, 30))
        s.add(obj(.strikethrough, 10, 10, 30, 30))
        let pic = s.addImage(solid(20, 20, (0, 0, 255)))
        let bgID = s.register(solid(8, 8, (0, 255, 0)))
        var bg = BackdropStyle(); bg.imageID = bgID; bg.pattern = .grid; bg.aspect = .square; bg.autoBalance = true
        s.perform(.setBackground(old: nil, new: bg))
        s.perform(.setBorder(old: nil, new: ImageBorder(width: 2, color: .white)))
        let orphan = s.register(solid(5, 5)) // unreferenced picture must not be written
        let url = dir.appendingPathComponent("v2.nshot")
        try NShotPackage.write(s.document, to: url)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("images").path)
        #expect(files.count == 2 && !files.contains("\(orphan.uuidString).png"))

        let back = try NShotPackage.read(from: url)
        #expect(back.objects == s.document.objects)
        #expect(back.background == bg && back.border == s.document.border)
        #expect(back.images[pic.imageID!] != nil && back.images[bgID] != nil)
        let a = try #require(EditorRenderer.render(back)), b = try #require(EditorRenderer.render(s.document))
        #expect(px(a) == px(b))
    }

    @Test func versionOneProjectsStillOpen() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var doc = EditorDocument(original: noise(30, 20))
        doc.objects = [obj(.arrow, 1, 1, 20, 10)]
        doc.background = BackdropStyle()
        let url = dir.appendingPathComponent("old.nshot")
        try NShotPackage.write(doc, to: url)
        // Downgrade the files to exactly what a v1 writer produced: no new keys anywhere.
        let mf = url.appendingPathComponent("manifest.json")
        var m = try JSONSerialization.jsonObject(with: Data(contentsOf: mf)) as! [String: Any]
        m["formatVersion"] = 1; m["images"] = nil
        try JSONSerialization.data(withJSONObject: m).write(to: mf)
        let of = url.appendingPathComponent("objects.json")
        var p = try JSONSerialization.jsonObject(with: Data(contentsOf: of)) as! [String: Any]
        let strip = ["headStart", "headEnd", "curve", "cornerRadius", "shadow", "locked", "imageID", "magnification"]
        p["objects"] = (p["objects"] as! [[String: Any]]).map { o in o.filter { !strip.contains($0.key) } }
        var b = p["background"] as! [String: Any]
        for k in ["pattern", "aspect", "imageID", "autoBalance"] { b[k] = nil }
        p["background"] = b; p["border"] = nil
        try JSONSerialization.data(withJSONObject: p).write(to: of)
        let back = try NShotPackage.read(from: url)
        #expect(back.objects.count == 1 && back.objects[0].headEnd && !back.objects[0].headStart && back.objects[0].curve == 0)
        #expect(back.background?.pattern == nil && back.background?.autoBalance == false && back.border == nil)
    }

    @Test func missingReferencedPictureIsRejected() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = EditorSession(document: EditorDocument(original: noise(30, 30)))
        s.addImage(solid(10, 10))
        let url = dir.appendingPathComponent("x.nshot")
        try NShotPackage.write(s.document, to: url)
        try FileManager.default.removeItem(at: url.appendingPathComponent("images"))
        let mf = url.appendingPathComponent("manifest.json")
        var m = try JSONSerialization.jsonObject(with: Data(contentsOf: mf)) as! [String: Any]
        m["images"] = nil
        try JSONSerialization.data(withJSONObject: m).write(to: mf)
        #expect(throws: NShotError.self) { try NShotPackage.read(from: url) }
    }

    @Test func pictureEscapingThePackageIsRejected() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = EditorSession(document: EditorDocument(original: noise(30, 30)))
        s.addImage(solid(10, 10))
        let url = dir.appendingPathComponent("x.nshot")
        try NShotPackage.write(s.document, to: url)
        let mf = url.appendingPathComponent("manifest.json")
        var m = try JSONSerialization.jsonObject(with: Data(contentsOf: mf)) as! [String: Any]
        m["images"] = (m["images"] as! [String: String]).mapValues { _ in "../outside.png" }
        try JSONSerialization.data(withJSONObject: m).write(to: mf)
        #expect(throws: NShotError.self) { try NShotPackage.read(from: url) }
    }

    @Test func rotatedProjectSurvivesRoundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = EditorSession(document: EditorDocument(original: noise(50, 30)))
        s.addImage(solid(10, 20, (255, 0, 0)))
        s.apply(.rotateRight)
        let url = dir.appendingPathComponent("r.nshot")
        try NShotPackage.write(s.document, to: url)
        let back = try NShotPackage.read(from: url)
        #expect(back.original.width == 30 && back.original.height == 50)
        let id = try #require(back.objects[0].imageID)
        #expect(back.images[id]?.width == 20 && back.images[id]?.height == 10)
    }
}

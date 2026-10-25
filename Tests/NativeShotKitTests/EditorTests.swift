import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NativeShotKit

/// Deterministic noise so a surviving original pixel can't be a coincidence of a flat colour.
private func noiseImage(_ w: Int, _ h: Int) -> CGImage {
    var rng: UInt64 = 0x9E3779B97F4A7C15
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) {
        for c in 0..<3 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            bytes[i * 4 + c] = UInt8(truncatingIfNeeded: rng >> 33)
        }
    }
    let ctx = bytes.withUnsafeMutableBytes {
        CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    return ctx.makeImage()!
}

private func pixels(_ image: CGImage) -> [UInt8] {
    let w = image.width, h = image.height
    var out = [UInt8](repeating: 0, count: w * h * 4)
    out.withUnsafeMutableBytes {
        let ctx = CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return out
}

private func decode(_ data: Data) -> CGImage {
    CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
}

/// Fraction of pixels inside `rect` (top-left origin) identical to `reference`.
private func survivors(_ out: CGImage, _ reference: [UInt8], refWidth: Int, rect: CGRect) -> Double {
    let p = pixels(out)
    var same = 0, total = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let o = (y * out.width + x) * 4, r = (y * refWidth + x) * 4
            if p[o] == reference[r], p[o + 1] == reference[r + 1], p[o + 2] == reference[r + 2] { same += 1 }
            total += 1
        }
    }
    return Double(same) / Double(total)
}

@Suite struct EditorModelTests {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Annotation {
        Annotation(kind: .rectangle, start: CGPoint(x: x, y: y), end: CGPoint(x: x + w, y: y + h))
    }

    @Test func undoRedoAndLayers() {
        var s = EditorSession(document: EditorDocument(original: noiseImage(40, 40)))
        let a = rect(1, 1, 5, 5), b = rect(2, 2, 5, 5), c = rect(3, 3, 5, 5)
        [a, b, c].forEach { s.add($0) }
        s.moveLayer(id: a.id, by: 2)
        #expect(s.document.objects.map(\.id) == [b.id, c.id, a.id])
        s.delete(ids: [b.id, a.id])
        #expect(s.document.objects.map(\.id) == [c.id])
        s.undo() // restores both at their original positions
        #expect(s.document.objects.map(\.id) == [b.id, c.id, a.id])
        s.undo()
        #expect(s.document.objects.map(\.id) == [a.id, b.id, c.id].reordered(a.id, to: 0))
        s.redo()
        #expect(s.document.objects.map(\.id) == [b.id, c.id, a.id])
        s.add(rect(0, 0, 1, 1))
        #expect(!s.canRedo)
    }

    @Test func styleEditsCoalesce() {
        var s = EditorSession(document: EditorDocument(original: noiseImage(10, 10)))
        let a = rect(1, 1, 5, 5)
        s.add(a)
        var n = a
        for w in [5.0, 6, 7] {
            let old = n
            n.style.width = w
            s.perform(.replace(old: old, new: n), coalescing: true)
        }
        #expect(s.document.objects[0].style.width == 7)
        s.undo()
        #expect(s.document.objects[0].style.width == a.style.width)
        s.undo()
        #expect(s.document.objects.isEmpty)
    }

    @Test func hitTesting() {
        let l = Annotation(kind: .line, start: .zero, end: CGPoint(x: 100, y: 0))
        #expect(l.hit(CGPoint(x: 50, y: 3), tolerance: 2))
        #expect(!l.hit(CGPoint(x: 50, y: 20), tolerance: 2))
    }
}

private extension Array where Element == UUID {
    func reordered(_ id: UUID, to i: Int) -> [UUID] { var a = self; a.removeAll { $0 == id }; a.insert(id, at: i); return a }
}

@Suite struct RedactionTests {
    private let size = 160
    private let region = CGRect(x: 40, y: 30, width: 80, height: 60)

    private func exported(_ kind: AnnotationKind, width: Double = 4) throws -> (CGImage, [UInt8]) {
        let img = noiseImage(size, size)
        var doc = EditorDocument(original: img)
        doc.objects = [Annotation(kind: kind, start: region.origin, end: CGPoint(x: region.maxX, y: region.maxY),
                                  style: AnnotationStyle(color: .black, width: width, opacity: 0.3))]
        // Round-trip through the encoded PNG: what the user ends up with on disk.
        return (decode(try ImageExporter.data(for: doc, format: .png)), pixels(img))
    }

    @Test(arguments: [AnnotationKind.pixelate, .blur, .redact])
    func originalPixelsDoNotSurviveInPNG(kind: AnnotationKind) throws {
        let (out, ref) = try exported(kind)
        #expect(survivors(out, ref, refWidth: size, rect: region) < 0.01)
        // Outside the region the image is untouched.
        let outside = CGRect(x: 0, y: 100, width: size, height: 60)
        #expect(survivors(out, ref, refWidth: size, rect: outside) == 1)
    }

    @Test func redactIsOpaqueSolidEvenWithLowOpacity() throws {
        let (out, _) = try exported(.redact)
        let p = pixels(out)
        let o = (50 * size + 60) * 4
        #expect(p[o] == 0 && p[o + 1] == 0 && p[o + 2] == 0 && p[o + 3] == 255)
    }

    @Test func redactionUnderOtherObjectsAlsoErasesThem() throws {
        // A drawn arrow beneath the block must not be recoverable either.
        var doc = EditorDocument(original: noiseImage(size, size))
        doc.objects = [Annotation(kind: .filledRectangle, start: CGPoint(x: 50, y: 40), end: CGPoint(x: 100, y: 80)),
                       Annotation(kind: .redact, start: region.origin, end: CGPoint(x: region.maxX, y: region.maxY), style: .init(color: .black))]
        let p = pixels(decode(try ImageExporter.data(for: doc, format: .png)))
        let o = (60 * size + 70) * 4
        #expect(p[o] == 0 && p[o + 1] == 0 && p[o + 2] == 0)
    }

    @Test func cropAndBackgroundChangeOutputSize() throws {
        var doc = EditorDocument(original: noiseImage(size, size))
        doc.crop = CGRect(x: 10, y: 10, width: 50, height: 40)
        #expect(decode(try ImageExporter.data(for: doc, format: .png)).width == 50)
        doc.background = BackdropStyle(padding: 20)
        let out = decode(try ImageExporter.data(for: doc, format: .png))
        #expect(out.width == 90 && out.height == 80)
    }

    @Test func exportCarriesNoMetadata() throws {
        let data = try ImageExporter.data(for: EditorDocument(original: noiseImage(20, 20)), format: .jpeg(quality: 0.8))
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        // The encoder only writes structural EXIF (colour space, dimensions), never dates or camera data.
        let exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        #expect(Set(exif.keys).isSubset(of: [kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension]))
        #expect(props[kCGImagePropertyTIFFDictionary] == nil)
    }
}

@Suite struct NShotPackageTests {
    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("nshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func makeProject(in dir: URL) throws -> URL {
        var doc = EditorDocument(original: noiseImage(30, 20))
        doc.objects = [Annotation(kind: .text, start: CGPoint(x: 2, y: 2), end: CGPoint(x: 2, y: 2), text: "hola"),
                       Annotation(kind: .freehand, start: .zero, end: .zero, points: [.zero, CGPoint(x: 5, y: 5)])]
        doc.crop = CGRect(x: 1, y: 1, width: 10, height: 10)
        doc.background = BackdropStyle()
        let url = dir.appendingPathComponent("p.nshot")
        try NShotPackage.write(doc, to: url)
        return url
    }

    private func rewriteManifest(_ url: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let f = url.appendingPathComponent("manifest.json")
        var m = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
        edit(&m)
        try JSONSerialization.data(withJSONObject: m).write(to: f)
    }

    @Test func roundTrip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject(in: dir)
        try NShotPackage.write(EditorDocument(original: noiseImage(30, 20)), to: url) // overwrite is atomic
        let url2 = try makeProject(in: try tempDir())
        let doc = try NShotPackage.read(from: url2)
        #expect(doc.objects.count == 2 && doc.objects[0].text == "hola")
        #expect(doc.crop == CGRect(x: 1, y: 1, width: 10, height: 10) && doc.background != nil)
        #expect(doc.original.width == 30 && doc.original.height == 20)
    }

    @Test(arguments: ["../outside.png", "/etc/passwd", "a/../../b", "", "sub//x", "~/x", "a\\b"])
    func rejectsUnsafePaths(path: String) throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject(in: dir)
        try rewriteManifest(url) { $0["image"] = path }
        #expect(throws: NShotError.self) { try NShotPackage.read(from: url) }
    }

    @Test func rejectsSymlinkEscape() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject(in: dir)
        let outside = dir.appendingPathComponent("secret.png")
        try FileManager.default.moveItem(at: url.appendingPathComponent("original.png"), to: outside)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("original.png"), withDestinationURL: outside)
        #expect(throws: NShotError.self) { try NShotPackage.read(from: url) }
    }

    @Test func rejectsNewerVersionAndBadSizes() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject(in: dir)
        try rewriteManifest(url) { $0["formatVersion"] = 99 }
        #expect(throws: NShotError.unsupportedVersion(99)) { try NShotPackage.read(from: url) }
        try rewriteManifest(url) { $0["formatVersion"] = 1; $0["width"] = 31 }
        #expect(throws: NShotError.sizeMismatch) { try NShotPackage.read(from: url) }
        try rewriteManifest(url) { $0["width"] = 30; $0["height"] = 1_000_000 }
        #expect(throws: NShotError.self) { try NShotPackage.read(from: url) }
    }

    @Test func rejectsCorruptContent() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject(in: dir)
        try Data("{not json".utf8).write(to: url.appendingPathComponent("objects.json"))
        #expect(throws: NShotError.self) { try NShotPackage.read(from: url) }
        let url2 = try makeProject(in: try tempDir())
        try Data("garbage".utf8).write(to: url2.appendingPathComponent("original.png"))
        #expect(throws: NShotError.self) { try NShotPackage.read(from: url2) }
        try FileManager.default.removeItem(at: url2.appendingPathComponent("manifest.json"))
        #expect(throws: NShotError.self) { try NShotPackage.read(from: url2) }
        #expect(throws: NShotError.notAPackage) { try NShotPackage.read(from: dir.appendingPathComponent("nope.nshot")) }
    }

    @Test func rejectsInvalidObjects() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject(in: dir)
        let f = url.appendingPathComponent("objects.json")
        var s = String(decoding: try Data(contentsOf: f), as: UTF8.self)
        s = s.replacingOccurrences(of: "\"opacity\":1", with: "\"opacity\":7")
        try Data(s.utf8).write(to: f)
        #expect(throws: NShotError.self) { try NShotPackage.read(from: url) }
    }
}

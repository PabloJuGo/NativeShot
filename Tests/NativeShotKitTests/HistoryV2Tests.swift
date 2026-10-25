import Foundation
import ImageIO
import Testing
@testable import NativeShotKit

@Suite struct HistoryV2Tests {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ns-\(UUID().uuidString)") }

    @Test func migratesV1ToV2KeepingData() async throws {
        let url = tmp().appendingPathComponent("library.sqlite")
        let a = StoredArtifact(type: .screenshot, sourceApp: "Safari", width: 5, height: 5, format: "png",
                               originalPath: "originals/x/source.png", byteSize: 9, favorite: true)
        do {
            let v1 = try HistoryStore(url: url, upTo: 1)
            try await v1.insert(a)
            try await v1.setOCRText("hola mundo", for: a.id)
        }
        let s = try HistoryStore(url: url)
        #expect(try await s.search(HistoryQuery()).map(\.id) == [a.id])
        #expect(try await s.search(HistoryQuery(text: "mundo")).map(\.id) == [a.id])
        #expect(try await s.search(HistoryQuery(text: "safari")).map(\.id) == [a.id]) // name reindexed by v2
        #expect(try await s.search(HistoryQuery(favoritesOnly: true)).count == 1)
        try await s.setOCRBlocks([OCRBlock(text: "hola", x: 0, y: 0, w: 1, h: 1)], for: a.id)
        #expect(try await s.ocrBlocks(for: a.id).count == 1)
    }

    @Test func trashPurgeAndTextIndexCleanup() async throws {
        let s = try HistoryStore(url: tmp().appendingPathComponent("library.sqlite"))
        let a = StoredArtifact(type: .screenshot, width: 1, height: 1, format: "png", originalPath: "originals/a/source.png",
                               byteSize: 1, isPrivate: true, projectPath: "projects/a")
        try await s.insert(a)
        try await s.setOCRText("secreto", for: a.id)
        try await s.setOCRBlocks([OCRBlock(text: "secreto", x: 0, y: 0, w: 1, h: 1)], for: a.id)
        let got = try await s.search(HistoryQuery()).first
        #expect(got?.isPrivate == true && got?.projectPath == "projects/a")
        try await s.clearTextIndex()
        #expect(try await s.search(HistoryQuery(text: "secreto")).isEmpty)
        #expect(try await s.ocrBlocks(for: a.id).isEmpty)
        try await s.trash(a.id, at: Date(timeIntervalSince1970: 100))
        #expect(try await s.count(HistoryQuery(trashedOnly: true)) == 1)
        #expect(try await s.trashedIDs(before: Date(timeIntervalSince1970: 50)).isEmpty)
        #expect(try await s.trashedIDs(before: Date()) == [a.id])
        try await s.purge(try await s.trashedIDs())
        #expect(try await s.count(HistoryQuery(includeDeleted: true)) == 0)
    }

    @Test func benchmark20kRows() async throws {
        let s = try HistoryStore(url: tmp().appendingPathComponent("library.sqlite"))
        let words = ["factura", "pedido", "reunión", "contraseña", "informe", "diseño", "error", "captura"]
        let items = (0..<20_000).map { i in
            StoredArtifact(type: i % 7 == 0 ? .video : .screenshot, createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
                           sourceApp: "App\(i % 30)", width: 100, height: 100, format: "png",
                           originalPath: "originals/\(UUID().uuidString)/source.png", byteSize: 1)
        }
        let clock = ContinuousClock()
        let tInsert = try await clock.measure { try await s.insert(contentsOf: items) }
        let tOCR = try await clock.measure {
            for (i, a) in items.enumerated() where i % 4 == 0 {
                try await s.setOCRText("\(words[i % 8]) \(words[(i / 8) % 8]) número \(i)", for: a.id)
            }
        }
        var hits = 0
        let tFTS = try await clock.measure { hits = try await s.search(HistoryQuery(text: "numero", limit: 100)).count }
        let tTwo = try await clock.measure { _ = try await s.search(HistoryQuery(text: "factura reunion", limit: 100)) }
        let tPage = try await clock.measure { _ = try await s.search(HistoryQuery(limit: 200, offset: 15_000)) }
        let tCount = try await clock.measure { _ = try await s.count(HistoryQuery(text: "numero")) }
        print("BENCH 20k insert=\(tInsert) ocr5k=\(tOCR) fts(numero,100)=\(tFTS) fts(2 terms)=\(tTwo) page(200@15000)=\(tPage) count(fts)=\(tCount)")
        #expect(hits == 100)
        #expect(tFTS < .seconds(1) && tPage < .seconds(1))
    }
}

@Suite struct ThumbnailTests {
    @Test func generatesBoundedJPEG() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("s.png")
        let ctx = CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let png = CGImageDestinationCreateWithURL(src as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(png, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(png))
        let out = Thumbnails.url(for: UUID(), root: dir)
        try Thumbnails.generate(from: src, to: out)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyPixelWidth] as? Int == Thumbnails.maxPixel)
    }
}

import CoreGraphics
import Foundation
import NativeShotKit

/// Synthetic scrolling page: a text-like body with a sticky header and footer on every frame.
enum ScrollPage {
    static let width = 1500
    static let viewport = 1000
    static let step = 400
    static let header = 60
    static let footer = 40

    /// One body row of the page at absolute row `y` (gray values, same hash pattern as the Kit tests).
    static func row(_ y: Int) -> [UInt8] {
        if y % 18 >= 12 { return [UInt8](repeating: 255, count: width) }
        var out = [UInt8](repeating: 235, count: width)
        for x0 in stride(from: 0, to: width, by: 6) {
            var h = UInt64(truncatingIfNeeded: y / 3) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: x0 / 6) &* 0xC2B2_AE3D_27D4_EB4F ^ 7
            h ^= h >> 29; h = h &* 0xBF58_476D_1CE4_E5B9; h ^= h >> 32
            let v: UInt8 = h % 3 == 0 ? 25 : 235
            for x in x0..<min(x0 + 6, width) { out[x] = v }
        }
        return out
    }

    /// Viewport `i` of the page, RGBA like a Retina capture.
    static func frame(_ i: Int) -> ScrollFrame {
        var data: [UInt8] = []
        data.reserveCapacity(width * viewport * 4)
        for r in 0..<viewport {
            let gray: [UInt8]
            if r < header {
                gray = [UInt8](repeating: UInt8(40 + r % 7 * 20), count: width)
            } else if r >= viewport - footer {
                gray = [UInt8](repeating: UInt8(200 - r % 5 * 30), count: width)
            } else {
                gray = row(i * step + r)
            }
            for v in gray { data.append(contentsOf: [v, v, v, 255]) }
        }
        return ScrollFrame(width: width, height: viewport, bytesPerPixel: 4, data: data)
    }
}

enum Scenarios {
    // MARK: PNG writes (B-03 without real capture)

    static func pngWrite(width: Int, height: Int, reps: Int) throws -> BenchResult {
        let image = makeScreenshot(width: width, height: height)
        let dir = try makeScratchDir("png")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("capture.png")
        var samples: [Double] = []
        for _ in 0..<reps {
            samples.append(try timeMS { try writePNG(image, to: dest) })
            try FileManager.default.removeItem(at: dest)
        }
        // One extra write just to report the output size.
        try writePNG(image, to: dest)
        let size = fileSize(dest)
        return BenchResult(id: "png_\(width)x\(height)", name: "Escritura PNG \(width)×\(height) (ImageIO)", samples: samples,
                           notes: ["bytes": "\(size)", "mpx": String(format: "%.1f", Double(width * height) / 1e6)])
    }

    // MARK: History search (FTS5)

    static func search(rows total: Int, reps: Int) async throws -> [BenchResult] {
        let dir = try makeScratchDir("fts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(url: dir.appendingPathComponent("library.sqlite"))
        let vocab = ["factura", "reunion", "numero", "pedido", "cliente", "informe", "proyecto", "captura", "texto", "imagen"]
            + (0..<490).map { "palabra\($0)" }
        var rng = SplitMix(state: 7)
        var batch: [StoredArtifact] = []
        var ocr: [(UUID, String)] = []
        for i in 0..<total {
            let a = StoredArtifact(type: .screenshot, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60),
                                   sourceApp: "App\(i % 7)", width: 2560, height: 1440, format: "png",
                                   originalPath: "originals/\(i)/source.png", byteSize: 1_000)
            batch.append(a)
            ocr.append((a.id, (0..<12).map { _ in vocab[Int(rng.next() % UInt64(vocab.count))] }.joined(separator: " ")))
            if batch.count == 1_000 {
                try await store.insert(contentsOf: batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        try await store.insert(contentsOf: batch)
        for (id, text) in ocr { try await store.setOCRText(text, for: id) }

        let suffix = "\(total / 1000)k filas"
        var hits = 0
        var s1: [Double] = [], s2: [Double] = [], s3: [Double] = [], s4: [Double] = [], s5: [Double] = []
        for _ in 0..<reps {
            s1.append(try await timeMSAsync { hits = try await store.search(HistoryQuery(text: "numero", limit: 100)).count })
        }
        for _ in 0..<reps {
            s2.append(try await timeMSAsync { _ = try await store.search(HistoryQuery(text: "factura reunion", limit: 100)) })
        }
        for _ in 0..<reps {
            s3.append(try await timeMSAsync { _ = try await store.count(HistoryQuery(text: "numero")) })
        }
        for _ in 0..<reps {
            s4.append(try await timeMSAsync { _ = try await store.search(HistoryQuery(limit: 200, offset: 15_000)) })
        }
        for _ in 0..<reps {
            s5.append(try await timeMSAsync { _ = try await store.search(HistoryQuery(limit: 100)) })
        }
        return [
            BenchResult(id: "fts_una_palabra", name: "Búsqueda FTS «numero» (100 resultados), \(suffix)", samples: s1,
                        notes: ["resultados": "\(hits)"]),
            BenchResult(id: "fts_dos_palabras", name: "Búsqueda FTS «factura reunion», \(suffix)", samples: s2),
            BenchResult(id: "fts_conteo", name: "Conteo FTS «numero», \(suffix)", samples: s3),
            BenchResult(id: "listado_offset_15000", name: "Página de 200 con offset 15000 (sin texto), \(suffix)", samples: s4),
            BenchResult(id: "listado_primera_pagina", name: "Primera página de 100 (biblioteca), \(suffix)", samples: s5),
        ]
    }

    // MARK: Scroll stitching (B-06)

    static func stitch(frames n: Int, reps: Int) -> BenchResult {
        var samples: [Double] = []
        var accepted = 0, rejected = 0, outHeight = 0, expected = 0
        for _ in 0..<reps {
            let frames = (0..<n).map { ScrollPage.frame($0) } // built outside the timer
            var stitcher = ScrollStitcher()
            var parts: [ScrollFrame] = []
            samples.append(timeMS {
                for f in frames { _ = stitcher.add(f) }
                parts = stitcher.finish()
            })
            accepted = stitcher.acceptedFrames
            rejected = stitcher.rejectedFrames
            outHeight = parts.reduce(0) { $0 + $1.height }
            expected = (n - 1) * ScrollPage.step + ScrollPage.viewport
        }
        let ok = rejected == 0 && outHeight == expected
        return BenchResult(id: "scroll_\(n)_frames", name: "Stitching de \(n) capturas 1500×1000 RGBA", samples: samples,
                           notes: ["aceptadas": "\(accepted)", "rechazadas": "\(rejected)",
                                   "alto_salida": "\(outHeight) px (esperado \(expected))",
                                   "verificacion": ok ? "correcta" : "FALLO"])
    }

    // MARK: Editor render and export (EditorRenderer with redaction)

    static func editor(reps: Int) throws -> [BenchResult] {
        var doc = EditorDocument(original: makeScreenshot(width: 2560, height: 1440))
        var objects: [Annotation] = []
        func rect(_ kind: AnnotationKind, _ x: Double, _ y: Double, _ w: Double, _ h: Double, width: Double = 4) -> Annotation {
            Annotation(kind: kind, start: CGPoint(x: x, y: y), end: CGPoint(x: x + w, y: y + h), style: AnnotationStyle(width: width))
        }
        for i in 0..<10 {
            objects.append(Annotation(kind: .arrow, start: CGPoint(x: 200 + Double(i) * 200, y: 300), end: CGPoint(x: 260 + Double(i) * 200, y: 420)))
        }
        for i in 0..<4 { objects.append(rect(.rectangle, 100 + Double(i) * 500, 600, 400, 200)) }
        for i in 0..<3 {
            objects.append(Annotation(kind: .text, start: CGPoint(x: 150, y: 900 + Double(i) * 60), end: .zero, text: "Texto de prueba línea \(i)\nsegunda línea"))
        }
        for i in 0..<2 {
            objects.append(Annotation(kind: .counter, start: CGPoint(x: 1800 + Double(i) * 60, y: 200), end: .zero, number: i + 1))
        }
        objects.append(rect(.pixelate, 1200, 500, 300, 200, width: 6))
        objects.append(rect(.pixelate, 1600, 500, 300, 200, width: 6))
        objects.append(rect(.blur, 300, 1100, 400, 300, width: 8))
        objects.append(rect(.redact, 1200, 1100, 300, 60))
        doc.objects = objects

        var renderSamples: [Double] = [], exportSamples: [Double] = []
        var rendered = true
        for _ in 0..<reps {
            renderSamples.append(timeMS { rendered = EditorRenderer.render(doc) != nil })
        }
        var bytes = 0
        for _ in 0..<reps {
            exportSamples.append(try timeMS { bytes = try ImageExporter.data(for: doc, format: .png).count })
        }
        return [
            BenchResult(id: "editor_render", name: "Render del editor 2560×1440 con 22 objetos (2 pixelado, 1 desenfoque, 1 redacción)",
                        samples: renderSamples, notes: ["ok": "\(rendered)"]),
            BenchResult(id: "editor_exportar_png", name: "Exportar PNG del editor 2560×1440 (render + codificación)",
                        samples: exportSamples, notes: ["bytes": "\(bytes)"]),
        ]
    }

    // MARK: Library inserts and reads with memory (B-04)

    static func library(cycles: Int) async throws -> BenchResult {
        let dir = try makeScratchDir("library")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HistoryStore(url: dir.appendingPathComponent("library.sqlite"))
        let image = makeScreenshot(width: 2560, height: 1440)
        let before = residentBytes()
        var samples: [Double] = []
        var rssAt: [Int: UInt64] = [:]
        for i in 0..<cycles {
            samples.append(try await timeMSAsync {
                let id = UUID()
                let folder = dir.appendingPathComponent("originals/\(id.uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let src = folder.appendingPathComponent("source.png")
                try writePNG(image, to: src)
                try Thumbnails.generate(from: src, to: Thumbnails.url(for: id, root: dir))
                try await store.insert(StoredArtifact(id: id, type: .screenshot, createdAt: Date(), sourceApp: "Bench", width: 2560,
                                                      height: 1440, format: "png", originalPath: "originals/\(id.uuidString)/source.png",
                                                      byteSize: Int64(fileSize(src))))
                _ = try await store.search(HistoryQuery(limit: 50))
                _ = try Data(contentsOf: Thumbnails.url(for: id, root: dir))
            })
            if i == 0 || (i + 1) % 100 == 0 { rssAt[i + 1] = residentBytes() }
        }
        let after = residentBytes()
        let listed = try await store.count(HistoryQuery())
        func mb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1_048_576) }
        var notes: [String: String] = [
            "rss_antes_MB": mb(before), "rss_despues_MB": mb(after),
            "delta_MB": String(format: "%.1f", (Double(after) - Double(before)) / 1_048_576),
            "rss_pico_MB": mb(peakResidentBytes()), "filas_en_biblioteca": "\(listed)",
            "disco_MB": String(format: "%.0f", Double(directorySize(dir)) / 1_048_576),
        ]
        if let at100 = rssAt[100], cycles > 100 {
            let slope = (Double(after) - Double(at100)) / Double(cycles - 100) / 1024
            notes["rss_ciclo_100_MB"] = mb(at100)
            notes["crecimiento_KB_por_ciclo_tras_100"] = String(format: "%.1f", slope)
        }
        return BenchResult(id: "biblioteca_\(cycles)_ciclos", name: "Ciclo biblioteca: captura PNG 2560×1440 + miniatura + insert + listado + lectura",
                           samples: samples, notes: notes)
    }

    static func directorySize(_ url: URL) -> Int {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let f = e?.nextObject() as? URL { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }
}

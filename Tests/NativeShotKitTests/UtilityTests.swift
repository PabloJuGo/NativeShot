import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NativeShotKit

@Suite struct DiagnosticsTests {
    @Test func redactsHomeAndOtherUsers() {
        #expect(Diagnostics.redact("/Users/ana/Pictures/NativeShot", home: "/Users/ana") == "~/Pictures/NativeShot")
        #expect(Diagnostics.redact("/Users/otra/x and /Users/ana/y", home: "/Users/ana") == "~/x and ~/y")
        #expect(Diagnostics.redact("sin rutas", home: "/Users/ana") == "sin rutas")
    }

    @Test func jsonHasNoPersonalPaths() throws {
        let r = DiagnosticReport(app: "0.1", macOS: "15.0", locale: "es", permissions: ["screen": "granted"],
                                 preferences: ["saveFolder": "/Users/ana/Pictures/NativeShot"], counts: ["captures": 3])
        let text = String(decoding: try r.json(home: "/Users/ana"), as: UTF8.self)
        let back = try JSONDecoder().decode(DiagnosticReport.self, from: Data(text.utf8))
        #expect(!text.contains("Users") && !text.contains("ana/"))
        #expect(back.preferences["saveFolder"] == "~/Pictures/NativeShot")
        #expect(back.counts["captures"] == 3)
    }
}

@MainActor
@Suite struct KeyboardLabelTests {
    @Test func relabelsOnLayoutChange() {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let r = ShortcutRegistry(registrar: FakeRegistrar(), defaults: d)
        r.activate()
        let code = r.bindings[.region]!.keyCode
        r.refreshLabels { $0 == code ? "Ñ" : nil }
        #expect(r.bindings[.region]?.keyLabel == "Ñ")
        #expect(r.bindings[.selector]?.keyLabel == "5") // nil label keeps the previous one
    }

    @Test func currentLayoutGivesPrintableLabelForLetterKeys() {
        // kVK_ANSI_A = 0. Skipped silently where no layout data exists (headless CI).
        if let l = KeyboardLayoutLabels.label(forKeyCode: 0) { #expect(l.count >= 1) }
        #expect(!KeyboardLayoutLabels.isPrintable("\u{1C}"))
        #expect(!KeyboardLayoutLabels.isPrintable(" "))
    }
}

@Suite struct ExportOptionsTests {
    private func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @Test func downscaleHalvesPixels() {
        let half = ImageExporter.downscaled(image(100, 60), factor: 2)
        #expect(half.width == 50 && half.height == 30)
        #expect(ImageExporter.downscaled(image(100, 60), factor: 1).width == 100)
    }

    @Test func formatsEncodeAndDecode() throws {
        var formats: [ExportFormat] = [.png, .jpeg(quality: 0.8)]
        if ImageExporter.supportsHEIC { formats.append(.heic(quality: 0.8)) }
        for f in formats {
            let data = try ImageExporter.encode(image(32, 32), format: f)
            let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetCount(src) == 1)
        }
    }
}

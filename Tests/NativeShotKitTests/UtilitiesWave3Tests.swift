import CoreGraphics
import Foundation
import Testing
@testable import NativeShotKit

@Suite struct PreferencesBackupTests {
    let backup = PreferencesBackup(rules: [
        "playSound": .bool, "timerSeconds": .int(0...10), "jpegQuality": .double(0.1...1),
        "exportFormat": .string(allowed: ["png", "jpeg", "heic"], maxLength: 8), "saveFolder": .path,
    ])

    @Test func exportOmitsPathsAndUnknownKeysUnlessAsked() throws {
        let values: [String: Any] = ["playSound": true, "timerSeconds": 3, "saveFolder": "/Users/ana/Pictures", "secretToken": "x"]
        #expect(backup.sensitiveKeys(in: values) == ["saveFolder"])
        let plain = try backup.validate(try backup.export(values, includeSensitive: false))
        #expect(plain.accepted.keys.sorted() == ["playSound", "timerSeconds"])
        let full = try backup.validate(try backup.export(values, includeSensitive: true))
        #expect(full.accepted["saveFolder"] == .string("/Users/ana/Pictures"))
        #expect(full.accepted["secretToken"] == nil)
    }

    @Test func importRejectsBadValuesButKeepsGoodOnes() throws {
        let json = #"{"app":"NativeShot","version":1,"preferences":{"playSound":false,"timerSeconds":99,"jpegQuality":0.5,"exportFormat":"exe","saveFolder":"relative","evil":1}}"#
        let r = try backup.validate(Data(json.utf8))
        #expect(r.accepted.keys.sorted() == ["jpegQuality", "playSound"])
        #expect(Set(r.rejected.map(\.key)) == ["timerSeconds", "exportFormat", "saveFolder", "evil"])
    }

    @Test func importRejectsForeignOrNewerFiles() {
        #expect(throws: (any Error).self) { try backup.validate(Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try backup.validate(Data(#"{"app":"Other","version":1,"preferences":{}}"#.utf8)) }
        #expect(throws: (any Error).self) { try backup.validate(Data(#"{"app":"NativeShot","version":99,"preferences":{}}"#.utf8)) }
    }
}

@Suite struct URLSchemeTests {
    func parse(_ s: String, enabled: Bool = true, allowed: Set<URLSchemeCommand> = [.region, .openLibrary]) -> Result<URLSchemeCommand, URLSchemeCommand.Rejection> {
        URLSchemeCommand.parse(URL(string: s)!, enabled: enabled, allowed: allowed)
    }

    @Test func disabledByDefaultFlag() {
        #expect(parse("nativeshot://region", enabled: false) == .failure(.disabled))
    }

    @Test func allowlistAndStrictShape() {
        #expect(parse("nativeshot://region") == .success(.region))
        #expect(parse("NativeShot://Open-Library/") == .success(.openLibrary))
        #expect(parse("nativeshot://ocr") == .failure(.notAllowed(.ocr)))
        #expect(parse("nativeshot://nope") == .failure(.unknown))
        #expect(parse("https://region") == .failure(.wrongScheme))
        for bad in ["nativeshot://region?x=1", "nativeshot://region#a", "nativeshot://region/extra", "nativeshot://u@region", "nativeshot://region:80"] {
            #expect(parse(bad) == .failure(.unexpectedParameters), "\(bad)")
        }
    }
}

@Suite struct UpdateCheckTests {
    @Test func endpointOnlyForGithubRepos() {
        #expect(UpdateCheck.latestReleaseEndpoint(repository: "https://github.com/acme/native-shot.git")?.absoluteString == "https://api.github.com/repos/acme/native-shot/releases/latest")
        #expect(UpdateCheck.latestReleaseEndpoint(repository: "https://github.com/acme") == nil)
        #expect(UpdateCheck.latestReleaseEndpoint(repository: "http://github.com/acme/x") == nil)
        #expect(UpdateCheck.latestReleaseEndpoint(repository: "https://evil.example/acme/x") == nil)
        #expect(UpdateCheck.latestReleaseEndpoint(repository: "") == nil)
    }

    @Test func versionComparison() {
        #expect(UpdateCheck.isNewer("v1.0.1", than: "1.0.0"))
        #expect(UpdateCheck.isNewer("1.0.0", than: "1.0.0-rc1"))
        #expect(!UpdateCheck.isNewer("1.0.0-rc1", than: "1.0.0"))
        #expect(!UpdateCheck.isNewer("1.0", than: "1.0.0"))
        #expect(UpdateCheck.isNewer("2.0", than: "1.9.9"))
    }

    @Test func parsesRelease() {
        let ok = #"{"tag_name":"v1.2.0","html_url":"https://github.com/a/b/releases/tag/v1.2.0","draft":false}"#
        #expect(UpdateCheck.parseLatest(Data(ok.utf8))?.tag == "v1.2.0")
        #expect(UpdateCheck.parseLatest(Data(#"{"tag_name":"v1","html_url":"javascript:x"}"#.utf8)) == nil)
        #expect(UpdateCheck.parseLatest(Data("garbage".utf8)) == nil)
    }
}

@Suite struct ExportJobTests {
    func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        return ctx.makeImage()!
    }

    @Test func writesNamedScaledFileAndNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-\(UUID().uuidString)")
        let r = ExportRequest(folder: dir, template: "x/{type}", format: .jpeg(quality: 0.8), downscale: 2)
        let a = try ExportJob.run(image(), r), b = try ExportJob.run(image(), r)
        #expect(a.lastPathComponent == "xscreenshot.jpg" && b.lastPathComponent == "xscreenshot 2.jpg") // "/" stripped
        #expect(a.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(try Data(contentsOf: a).count > 0)
    }

    @Test func metadataIsOptIn() throws {
        let plain = try ImageExporter.encode(image(), format: .png)
        let kept = try ImageExporter.encode(image(), format: .png, keepMetadata: true)
        #expect(!String(decoding: plain, as: UTF8.self).contains("NativeShot"))
        #expect(kept.count > plain.count)
    }
}

@Suite struct ShortcutCompatTests {
    @Test func newActionsAppendedWithoutDefaults() {
        #expect(Array(ShortcutAction.allCases.prefix(8)) == [.selector, .region, .window, .display, .lastRegion, .textRecognition, .recordScreen, .scrolling])
        for a in ShortcutAction.allCases.dropFirst(8) { #expect(a.defaultCombo == nil) }
    }
}

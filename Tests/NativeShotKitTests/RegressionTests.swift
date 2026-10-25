import Foundation
import SQLite3
import Testing
@testable import NativeShotKit

/// Regressions found by the QA review of the Kit (each test reproduces a bug that was fixed).
@Suite struct KitRegressionTests {
    func tmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// APFS and HFS+ reject names longer than 255 UTF-8 bytes; `prefix(200)` counted characters, not bytes.
    @Test func longMultibyteNamesFitFileNameLimit() {
        let app = String(repeating: "🙂", count: 150)
        let name = FileNamingPolicy(template: "{app} {date}").name(date: Date(), type: "x", app: app, timeZone: .gmt, ext: "png")
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(".png"))
    }

    /// A corrupt or tampered library row must not crash the app when the library is listed.
    @Test func corruptRowIsSkippedNotFatal() async throws {
        let url = try tmpDir().appendingPathComponent("library.sqlite")
        let store = try HistoryStore(url: url)
        let good = StoredArtifact(type: .screenshot, width: 1, height: 1, format: "png", originalPath: "originals/a/source.png", byteSize: 1)
        let bad = StoredArtifact(type: .screenshot, width: 1, height: 1, format: "png", originalPath: "originals/b/source.png", byteSize: 1)
        try await store.insert(contentsOf: [good, bad])
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "UPDATE artifacts SET id='not-a-uuid' WHERE id='\(bad.id.uuidString)'", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let listed = try await store.search(HistoryQuery())
        #expect(listed.map(\.id) == [good.id])
    }

    /// FTS5 syntax typed by the user is quoted, so operators and stray quotes never raise a SQL error.
    @Test func hostileSearchTextIsInert() async throws {
        let store = try HistoryStore(url: try tmpDir().appendingPathComponent("library.sqlite"))
        try await store.insert(StoredArtifact(type: .screenshot, width: 1, height: 1, format: "png", originalPath: "originals/a/source.png", byteSize: 1))
        for text in ["\"", "*", "NEAR(", "a\"b OR NOT", "-", "col:x", ")("] {
            _ = try await store.search(HistoryQuery(text: text))
            _ = try await store.count(HistoryQuery(text: text))
        }
    }

    /// `tail` builds a frame of `maxRows + footer` rows; a non-positive budget must answer nil, not trap.
    @Test func tailWithNoBudgetReturnsNil() {
        let w = 200, h = 300
        func page(_ y: Int) -> ScrollFrame {
            var data: [UInt8] = []
            data.reserveCapacity(w * h)
            for r in 0..<h {
                for x in 0..<w {
                    let v = (y + r) &* 2654435761 &+ x &* 40503
                    data.append(UInt8(truncatingIfNeeded: (v ^ (v >> 13)) & 0xFF))
                }
            }
            return ScrollFrame(width: w, height: h, bytesPerPixel: 1, data: data)
        }
        var stitcher = ScrollStitcher()
        _ = stitcher.add(page(0))
        guard case .appended = stitcher.add(page(100)) else {
            Issue.record("two shifted frames should join")
            return
        }
        #expect(stitcher.tail(maxRows: 0) == nil)
        #expect(stitcher.tail(maxRows: -5) == nil)
        #expect(stitcher.tail(maxRows: 50)?.height == 50)
    }
}

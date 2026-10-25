import Foundation
import Testing
@testable import NativeShotKit

@Suite struct HistoryTagsTests {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ns-\(UUID().uuidString)/library.sqlite") }
    func item(_ app: String?, _ n: Int) -> StoredArtifact {
        StoredArtifact(type: .screenshot, sourceApp: app, width: 4, height: 4, format: "png", originalPath: "originals/\(n)/source.png", byteSize: 1)
    }

    @Test func migratesV2ToV3WithoutLoss() async throws {
        let url = tmp()
        let a = item("Safari", 1)
        do {
            let v2 = try HistoryStore(url: url, upTo: 2)
            try await v2.insert(a)
            try await v2.setOCRText("hola mundo", for: a.id)
            try await v2.setFavorite(true, for: a.id)
        }
        let s = try HistoryStore(url: url)
        let got = try await s.search(HistoryQuery())
        #expect(got.map(\.id) == [a.id] && got[0].favorite && got[0].sourceApp == "Safari")
        #expect(try await s.search(HistoryQuery(text: "mundo")).count == 1)
        try await s.addTag("Trabajo", to: [a.id])
        #expect(try await s.tags(for: a.id) == ["trabajo"])
    }

    @Test func tagSearchFilterAndRemoval() async throws {
        let s = try HistoryStore(url: tmp())
        let a = item("Safari", 1), b = item("Xcode", 2)
        try await s.insert(contentsOf: [a, b])
        try await s.addTag("  Factura  2026 ", to: [a.id, b.id])
        try await s.addTag("solo-a", to: [a.id])
        try await s.addTag("   ", to: [a.id]) // ignored
        #expect(try await s.allTags().map(\.name) == ["factura 2026", "solo-a"])
        var q = HistoryQuery(); q.tag = "SOLO-A"
        #expect(try await s.search(q).map(\.id) == [a.id])
        #expect(try await s.search(HistoryQuery(text: "solo-a")).map(\.id) == [a.id]) // free text finds tags
        q = HistoryQuery(); q.sourceApp = "Xcode"
        #expect(try await s.search(q).map(\.id) == [b.id])
        #expect(try await s.sourceApps() == ["Safari", "Xcode"])
        try await s.removeTag("solo-a", from: [a.id])
        #expect(try await s.search(HistoryQuery(text: "solo-a")).isEmpty)
        #expect(try await s.allTags().map(\.name) == ["factura 2026"])
        try await s.purge([a.id])
        #expect(try await s.tags(for: a.id).isEmpty) // cascade
    }
}

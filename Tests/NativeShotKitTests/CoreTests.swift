import Carbon.HIToolbox
import Foundation
import Testing
@testable import NativeShotKit

@Suite struct CaptureStateMachineTests {
    @Test func happyPath() {
        var m = CaptureStateMachine()
        for e in [CaptureEvent.begin, .overlayShown, .selectionConfirmed, .pixelsReceived, .artifactStored] {
            let ok = m.handle(e)
            #expect(ok)
        }
        #expect(m.phase == .ready)
        m.handle(.reset)
        #expect(m.phase == .idle)
    }

    @Test func rejectsInvalidTransitions() {
        var m = CaptureStateMachine()
        let early = m.handle(.pixelsReceived)
        #expect(!early && m.phase == .idle)
        m.handle(.begin)
        let again = m.handle(.begin) // double press while busy is ignored
        #expect(!again)
        #expect(m.isBusy)
    }

    @Test func cancelAndFail() {
        var m = CaptureStateMachine()
        m.handle(.begin); m.handle(.overlayShown)
        m.handle(.cancel)
        #expect(m.phase == .cancelled && !m.isBusy)
        m.handle(.reset); m.handle(.begin); m.handle(.selectionConfirmed)
        let lateCancel = m.handle(.cancel) // capture already running
        #expect(!lateCancel)
        m.handle(.fail("x"))
        #expect(m.phase == .failed("x"))
    }
}

@Suite struct GeometryTests {
    @Test func flipIsInvolution() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 200)
        let f = DisplayGeometry.flip(r, primaryHeight: 1000)
        #expect(f == CGRect(x: 10, y: 780, width: 300, height: 200))
        #expect(DisplayGeometry.flip(f, primaryHeight: 1000) == r)
    }

    @Test func dragInAnyDirection() {
        #expect(DisplayGeometry.rect(from: CGPoint(x: 50, y: 80), to: CGPoint(x: 10, y: 20)) == CGRect(x: 10, y: 20, width: 40, height: 60))
    }

    @Test func localClipsToSecondaryDisplay() {
        let display = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(DisplayGeometry.local(CGRect(x: 1400, y: 100, width: 100, height: 100), in: display) == CGRect(x: 0, y: 100, width: 60, height: 100))
        #expect(DisplayGeometry.local(CGRect(x: 0, y: 0, width: 100, height: 100), in: display) == nil)
    }

    @Test func pixelMath() {
        let r = CGRect(x: 0.3, y: 0.3, width: 10.1, height: 10.1)
        let a = DisplayGeometry.pixelAligned(r, scale: 2)
        #expect(a == CGRect(x: 0, y: 0, width: 10.5, height: 10.5))
        #expect(DisplayGeometry.pixelSize(of: a, scale: 2) == (21, 21))
    }
}

@Suite struct FileNamingTests {
    let date = Date(timeIntervalSince1970: 1_792_900_000) // 2026-10-25 in UTC

    @Test func defaultTemplate() {
        let n = FileNamingPolicy.default.name(date: date, type: "screenshot", timeZone: .gmt, ext: "png")
        #expect(n.hasPrefix("NativeShot 2026-10-2") && n.hasSuffix(".png"))
    }

    @Test func templateCannotEscapeFolder() {
        let n = FileNamingPolicy(template: "../../etc/{type}").name(date: date, type: "x", ext: "png")
        #expect(!n.contains("/") && !n.hasPrefix("."))
        #expect(FileNamingPolicy(template: "///").name(date: date, type: "x", ext: "png") == "NativeShot.png")
    }

    @Test func uniqueNeverOverwrites() {
        let folder = URL(fileURLWithPath: "/tmp/f")
        let taken: Set<String> = ["/tmp/f/a.png", "/tmp/f/a 2.png"]
        #expect(FileNamingPolicy.uniqueURL(in: folder, name: "a.png") { taken.contains($0.path) }.lastPathComponent == "a 3.png")
    }
}

@MainActor
final class FakeRegistrar: HotKeyRegistrar {
    var registered: [UInt32: KeyCombo] = [:]
    var refuse: Set<KeyCombo> = []
    func register(_ combo: KeyCombo, id: UInt32) throws(ShortcutError) {
        if refuse.contains(combo) { throw .systemRefused(-9878) }
        registered[id] = combo
    }
    func unregister(id: UInt32) { registered[id] = nil }
}

@MainActor
@Suite struct ShortcutRegistryTests {
    func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return d
    }

    @Test func activatesDefaultsWithoutSystemCombos() {
        let r = ShortcutRegistry(registrar: FakeRegistrar(), defaults: makeDefaults())
        #expect(r.activate().isEmpty)
        #expect(r.bindings[.selector]?.displayString == "⌃⌥⌘5")
        #expect(!r.bindings.values.contains(.commandShift5))
    }

    @Test func rejectsDuplicatesAndBareKeys() {
        let r = ShortcutRegistry(registrar: FakeRegistrar(), defaults: makeDefaults())
        r.activate()
        #expect(throws: ShortcutError.duplicate(.selector)) { try r.bind(.region, to: r.bindings[.selector]!) }
        #expect(throws: ShortcutError.notAcceptable) {
            try r.bind(.region, to: KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey), keyLabel: "A"))
        }
    }

    @Test func failedRebindKeepsPrevious() {
        let fake = FakeRegistrar()
        let r = ShortcutRegistry(registrar: fake, defaults: makeDefaults())
        r.activate()
        let before = r.bindings[.selector]!
        fake.refuse = [.commandShift5]
        #expect(throws: ShortcutError.systemRefused(-9878)) { try r.bind(.selector, to: .commandShift5) }
        #expect(r.bindings[.selector] == before)
        #expect(fake.registered.values.contains(before))
    }

    @Test func persistsAcrossLaunches() throws {
        let d = makeDefaults()
        let r1 = ShortcutRegistry(registrar: FakeRegistrar(), defaults: d)
        r1.activate()
        try r1.bind(.selector, to: .commandShift5)
        r1.unbind(.window)
        let r2 = ShortcutRegistry(registrar: FakeRegistrar(), defaults: d)
        r2.activate()
        #expect(r2.bindings[.selector] == .commandShift5)
        #expect(r2.bindings[.window] == nil)
    }

    @Test func cocoaModifierConversion() {
        let cmdShift: UInt = (1 << 20) | (1 << 17)
        #expect(KeyCombo.carbonModifiers(fromCocoa: cmdShift) == UInt32(cmdKey | shiftKey))
    }
}

@Suite struct HistoryStoreTests {
    func makeStore() throws -> HistoryStore {
        try HistoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ns-\(UUID().uuidString)/library.sqlite"))
    }

    func item(_ name: String, at t: TimeInterval) -> StoredArtifact {
        StoredArtifact(type: .screenshot, createdAt: Date(timeIntervalSince1970: t), width: 10, height: 10,
                       format: "png", originalPath: "originals/\(name)", byteSize: 100)
    }

    @Test func insertSearchAndTrash() async throws {
        let s = try makeStore()
        let a = item("factura.png", at: 1), b = item("otra.png", at: 2)
        try await s.insert(a); try await s.insert(b)
        #expect(try await s.search(HistoryQuery()).map(\.id) == [b.id, a.id])
        try await s.setOCRText("Número de pedido añadido", for: b.id)
        #expect(try await s.search(HistoryQuery(text: "numero")).map(\.id) == [b.id]) // diacritics-insensitive
        #expect(try await s.search(HistoryQuery(text: "fact")).map(\.id) == [a.id])
        #expect(try await s.search(HistoryQuery(text: "\"; DROP TABLE artifacts; --")).isEmpty)
        try await s.trash(a.id)
        #expect(try await s.search(HistoryQuery()).map(\.id) == [b.id])
        try await s.restore(a.id)
        try await s.purge(b.id)
        #expect(try await s.search(HistoryQuery()).map(\.id) == [a.id])
    }

    @Test func retentionSkipsFavorites() async throws {
        let s = try makeStore()
        let items = (1...4).map { item("\($0).png", at: TimeInterval($0)) }
        for i in items { try await s.insert(i) }
        try await s.setFavorite(true, for: items[0].id)
        let ids = try await s.retentionCandidates(maxCount: 2, maxAge: nil)
        #expect(ids == [items[1].id]) // newest 2 kept, oldest is favorite
        #expect(try await s.retentionCandidates(maxCount: nil, maxAge: nil).isEmpty)
    }
}

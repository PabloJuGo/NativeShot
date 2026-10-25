import AppKit
import ImageIO
import UniformTypeIdentifiers
import NativeShotKit

/// Managed local library in Application Support: originals on disk + SQLite index.
@MainActor
final class Library: ObservableObject {
    let root: URL
    let store: HistoryStore?
    @Published private(set) var recent: [StoredArtifact] = []
    /// Bumped on every change to the stored set so open windows know to reload.
    @Published private(set) var revision = 0

    /// HIS: private session. While on, nothing is stored or indexed; captures live in a temporary file only.
    /// Deliberately not persisted: every launch starts with history as configured.
    var privateSession = false
    var storesHistory: Bool { UserDefaults.standard.bool(forKey: Prefs.keepHistory) && !privateSession }

    init() {
        #if NATIVESHOT_QA
        // The self-test must never touch the user's real library.
        if let qa = ProcessInfo.processInfo.environment["NS_QA_LIBRARY"] {
            root = URL(fileURLWithPath: qa, isDirectory: true)
            store = try? HistoryStore(url: root.appendingPathComponent("library.sqlite"))
            return
        }
        #endif
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeShot", isDirectory: true)
        store = try? HistoryStore(url: root.appendingPathComponent("library.sqlite"))
    }

    func url(for a: StoredArtifact) -> URL { root.appendingPathComponent(a.originalPath) }

    /// Writes the PNG atomically off the main thread and indexes it. Returns the file URL.
    /// Thumbnail and OCR run afterwards in the background and never delay the caller.
    func add(_ image: CGImage, sourceApp: String?) async throws -> (UUID, URL) {
        let id = UUID()
        let rel = "originals/\(id.uuidString)/source.png"
        let keep = storesHistory
        // Without history the file only has to outlive the thumbnail actions (copy, drag, save).
        let url = keep ? root.appendingPathComponent(rel)
                       : FileManager.default.temporaryDirectory.appendingPathComponent("NativeShot/\(id.uuidString).png")
        let size = try await Task.detached(priority: .userInitiated) {
            try Self.writePNG(image, to: url)
        }.value
        if keep, let store {
            try await store.insert(StoredArtifact(id: id, type: .screenshot, sourceApp: sourceApp, width: image.width,
                                                  height: image.height, format: "png", originalPath: rel, byteSize: size))
            await applyRetention()
            await refresh()
            index(id: id, image: image, original: url, ocr: UserDefaults.standard.bool(forKey: Prefs.ocrIndex))
        }
        return (id, url)
    }

    private func index(id: UUID, image: CGImage, original: URL, ocr: Bool) {
        guard let store else { return }
        let thumb = Thumbnails.url(for: id, root: root)
        Task.detached(priority: .utility) {
            try? Thumbnails.generate(from: original, to: thumb)
            guard ocr, let blocks = try? OCRIndexer.recognize(image), !blocks.isEmpty else { return }
            // The item may have been deleted while Vision ran; a missing row just makes these no-ops.
            try? await store.setOCRText(blocks.map(\.text).joined(separator: "\n"), for: id)
            try? await store.setOCRBlocks(blocks, for: id)
        }
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL) throws -> Int64 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
        // Rename is atomic on the same volume: a crash never leaves a half-written original.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    func setOCR(_ text: String, for id: UUID) async {
        guard UserDefaults.standard.bool(forKey: Prefs.ocrIndex) else { return }
        try? await store?.setOCRText(text, for: id)
    }

    func refresh() async {
        recent = (try? await store?.search(HistoryQuery(limit: 8))) ?? []
        revision += 1
    }

    // MARK: Trash and purge

    /// Removes the item from history and deletes its files (QAO "Eliminar").
    func delete(id: UUID) async { await purge([id]) }

    func trash(_ ids: [UUID]) async {
        for id in ids { try? await store?.trash(id) }
        await refresh()
    }

    func restore(_ ids: [UUID]) async {
        for id in ids { try? await store?.restore(id) }
        await refresh()
    }

    func setFavorite(_ on: Bool, for id: UUID) async {
        try? await store?.setFavorite(on, for: id)
        await refresh()
    }

    // MARK: Tags (HIS)

    func tags(for id: UUID) async -> [String] { (try? await store?.tags(for: id)) ?? [] }
    func allTags() async -> [(name: String, count: Int)] { (try? await store?.allTags()) ?? [] }
    func sourceApps() async -> [String] { (try? await store?.sourceApps()) ?? [] }

    func addTag(_ tag: String, to ids: [UUID]) async {
        try? await store?.addTag(tag, to: ids)
        await refresh()
    }

    func removeTag(_ tag: String, from ids: [UUID]) async {
        try? await store?.removeTag(tag, from: ids)
        await refresh()
    }

    /// Row, OCR blocks, search entry, original and thumbnail go together. Rows first, so a failure
    /// can only leave orphan files, never rows pointing at nothing.
    func purge(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do { try await store?.purge(ids) } catch { return }
        let root = root
        await Task.detached(priority: .utility) {
            for id in ids {
                try? FileManager.default.removeItem(at: root.appendingPathComponent("originals/\(id.uuidString)"))
                try? FileManager.default.removeItem(at: Thumbnails.url(for: id, root: root))
            }
        }.value
        await refresh()
    }

    func emptyTrash() async {
        await purge((try? await store?.trashedIDs()) ?? [])
    }

    /// Trashed items older than `trashRetentionDays`. Favorites are no exception here: the user trashed them on purpose.
    func purgeExpiredTrash() async {
        let days = UserDefaults.standard.integer(forKey: Prefs.trashRetentionDays)
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        await purge((try? await store?.trashedIDs(before: cutoff)) ?? [])
    }

    func clearTextIndex() async {
        try? await store?.clearTextIndex()
        await refresh()
    }

    /// Count-based retention moves old items to the trash (still recoverable); favorites are exempt.
    private func applyRetention() async {
        let max = UserDefaults.standard.integer(forKey: Prefs.historyMaxCount)
        guard max > 0, let ids = try? await store?.retentionCandidates(maxCount: max, maxAge: nil), !ids.isEmpty else { return }
        for id in ids { try? await store?.trash(id) }
    }
}

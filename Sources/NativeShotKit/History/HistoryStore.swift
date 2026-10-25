import Foundation
import SQLite3

public enum ArtifactType: String, Sendable, Codable { case screenshot, video, gif, project }

public struct StoredArtifact: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var type: ArtifactType
    public var createdAt: Date
    public var sourceApp: String?
    public var width: Int
    public var height: Int
    public var format: String
    /// Relative to the library root, so the library can be moved.
    public var originalPath: String
    public var byteSize: Int64
    public var favorite: Bool
    public var deletedAt: Date?
    public var isPrivate: Bool
    /// Relative to the library root; set for editable projects.
    public var projectPath: String?

    public init(id: UUID = UUID(), type: ArtifactType, createdAt: Date = Date(), sourceApp: String? = nil,
                width: Int, height: Int, format: String, originalPath: String, byteSize: Int64,
                favorite: Bool = false, deletedAt: Date? = nil, isPrivate: Bool = false, projectPath: String? = nil) {
        self.id = id; self.type = type; self.createdAt = createdAt; self.sourceApp = sourceApp
        self.width = width; self.height = height; self.format = format; self.originalPath = originalPath
        self.byteSize = byteSize; self.favorite = favorite; self.deletedAt = deletedAt
        self.isPrivate = isPrivate; self.projectPath = projectPath
    }
}

public struct HistoryQuery: Sendable {
    public var text: String?
    public var type: ArtifactType?
    public var favoritesOnly = false
    /// Exact (normalized) user tag.
    public var tag: String?
    /// Exact source app name.
    public var sourceApp: String?
    public var includeDeleted = false
    /// Only the internal trash (wins over `includeDeleted`).
    public var trashedOnly = false
    public var limit = 100
    public var offset = 0
    public init(text: String? = nil, type: ArtifactType? = nil, favoritesOnly: Bool = false,
                includeDeleted: Bool = false, trashedOnly: Bool = false, limit: Int = 100, offset: Int = 0) {
        self.text = text; self.type = type; self.favoritesOnly = favoritesOnly
        self.includeDeleted = includeDeleted; self.trashedOnly = trashedOnly; self.limit = limit; self.offset = offset
    }
}

public struct OCRBlock: Sendable, Equatable {
    public var text: String
    /// Normalized (0...1) bounding box, origin bottom-left as Vision reports it.
    public var x, y, w, h: Double
    public init(text: String, x: Double, y: Double, w: Double, h: Double) {
        self.text = text; self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public struct HistoryError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Serialized SQLite access. Every statement is parameterized.
public actor HistoryStore {
    private nonisolated(unsafe) let db: OpaquePointer?
    public static let schemaVersion: Int32 = 3

    public init(url: URL) throws { try self.init(url: url, upTo: Self.schemaVersion) }

    /// `upTo` lets tests build an older database to exercise migrations.
    init(url: URL, upTo: Int32) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw HistoryError(description: msg)
        }
        db = handle
        try Self.exec(handle, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try Self.migrate(handle, upTo: upTo)
    }

    deinit { sqlite3_close(db) }

    private static func migrate(_ db: OpaquePointer?, upTo: Int32) throws {
        var version: Int32 = 0
        try query(db, "PRAGMA user_version", []) { version = sqlite3_column_int($0, 0) }
        if version < 1, upTo >= 1 {
            try exec(db, """
            BEGIN;
            CREATE TABLE artifacts(
              id TEXT PRIMARY KEY, type TEXT NOT NULL, created_at REAL NOT NULL, source_app TEXT,
              display_id INTEGER, width INTEGER NOT NULL, height INTEGER NOT NULL, format TEXT NOT NULL,
              original_path TEXT NOT NULL, project_path TEXT, byte_size INTEGER NOT NULL,
              favorite INTEGER NOT NULL DEFAULT 0, is_private INTEGER NOT NULL DEFAULT 0, deleted_at REAL);
            CREATE INDEX artifacts_created ON artifacts(created_at DESC);
            CREATE TABLE tags(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
            CREATE TABLE artifact_tags(artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
              tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE, PRIMARY KEY(artifact_id, tag_id));
            CREATE TABLE ocr_blocks(artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
              idx INTEGER NOT NULL, text TEXT NOT NULL, x REAL, y REAL, w REAL, h REAL, PRIMARY KEY(artifact_id, idx));
            CREATE VIRTUAL TABLE artifact_search USING fts5(artifact_id UNINDEXED, name, ocr_text, tokenize='unicode61 remove_diacritics 2');
            PRAGMA user_version = 1;
            COMMIT;
            """)
        }
        if version < 2, upTo >= 2 {
            // Missing from v1: sessions, exports and the indexes the library queries rely on.
            try exec(db, """
            BEGIN;
            CREATE TABLE capture_sessions(id TEXT PRIMARY KEY, started_at REAL NOT NULL, mode TEXT NOT NULL,
              display_id INTEGER, artifact_id TEXT REFERENCES artifacts(id) ON DELETE SET NULL);
            CREATE TABLE exports(id INTEGER PRIMARY KEY, artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
              created_at REAL NOT NULL, format TEXT NOT NULL, path TEXT NOT NULL);
            CREATE INDEX exports_artifact ON exports(artifact_id);
            CREATE INDEX artifacts_deleted ON artifacts(deleted_at) WHERE deleted_at IS NOT NULL;
            CREATE INDEX artifacts_favorite ON artifacts(created_at DESC) WHERE favorite = 1;
            -- FTS rowid = artifacts.rowid so updates and deletes are O(log n); with artifact_id UNINDEXED
            -- they were a full scan (~2 ms per OCR update at 20k rows). Never VACUUM without rebuilding this.
            CREATE TEMP TABLE old_ocr AS SELECT artifact_id, ocr_text FROM artifact_search;
            CREATE INDEX old_ocr_id ON old_ocr(artifact_id);
            DROP TABLE artifact_search;
            CREATE VIRTUAL TABLE artifact_search USING fts5(artifact_id UNINDEXED, name, ocr_text, tokenize='unicode61 remove_diacritics 2');
            INSERT INTO artifact_search(rowid, artifact_id, name, ocr_text)
              SELECT a.rowid, a.id,
                trim(coalesce(a.source_app,'') || ' ' || a.format || ' ' || strftime('%Y-%m-%d', a.created_at, 'unixepoch')),
                coalesce(o.ocr_text, '')
              FROM artifacts a LEFT JOIN old_ocr o ON o.artifact_id = a.id;
            DROP TABLE old_ocr;
            PRAGMA user_version = 2;
            COMMIT;
            """)
        }
        if version < 3, upTo >= 3 {
            // v3: user tags and source-app filters. The tag tables already exist since v1, so only indexes are added;
            // no row is rewritten.
            try exec(db, """
            BEGIN;
            CREATE INDEX IF NOT EXISTS artifact_tags_tag ON artifact_tags(tag_id);
            CREATE INDEX IF NOT EXISTS artifacts_source ON artifacts(source_app) WHERE source_app IS NOT NULL;
            PRAGMA user_version = 3;
            COMMIT;
            """)
        }
    }

    public func insert(_ a: StoredArtifact) throws { try insert(contentsOf: [a]) }

    /// One transaction for the whole batch (imports, benchmarks).
    public func insert(contentsOf items: [StoredArtifact]) throws {
        try Self.exec(db, "BEGIN")
        do {
            for a in items {
                try Self.run(db, """
                INSERT INTO artifacts(id,type,created_at,source_app,width,height,format,original_path,byte_size,favorite,deleted_at,is_private,project_path)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [a.id.uuidString, a.type.rawValue, a.createdAt.timeIntervalSince1970, a.sourceApp, a.width, a.height,
                      a.format, a.originalPath, a.byteSize, a.favorite ? 1 : 0, a.deletedAt?.timeIntervalSince1970,
                      a.isPrivate ? 1 : 0, a.projectPath])
                try Self.run(db, "INSERT INTO artifact_search(rowid,artifact_id,name,ocr_text) VALUES((SELECT rowid FROM artifacts WHERE id=?),?,?,'')",
                             [a.id.uuidString, a.id.uuidString, Self.searchName(a)])
            }
            try Self.exec(db, "COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Source app, format, UTC day and file name: what a user might type to find a capture by name.
    static func searchName(_ a: StoredArtifact) -> String {
        [a.sourceApp, a.format, a.createdAt.formatted(.iso8601.year().month().day()), (a.originalPath as NSString).lastPathComponent]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// Replaces the searchable OCR text of an artifact (OCR indexing is optional).
    public func setOCRText(_ text: String, for id: UUID) throws {
        try Self.run(db, "UPDATE artifact_search SET ocr_text=? WHERE rowid=(SELECT rowid FROM artifacts WHERE id=?)", [text, id.uuidString])
    }

    public func setFavorite(_ favorite: Bool, for id: UUID) throws {
        try Self.run(db, "UPDATE artifacts SET favorite=? WHERE id=?", [favorite ? 1 : 0, id.uuidString])
    }

    /// Soft delete into the internal trash; `purge` removes rows for good.
    public func trash(_ id: UUID, at date: Date = Date()) throws {
        try Self.run(db, "UPDATE artifacts SET deleted_at=? WHERE id=?", [date.timeIntervalSince1970, id.uuidString])
    }

    public func restore(_ id: UUID) throws {
        try Self.run(db, "UPDATE artifacts SET deleted_at=NULL WHERE id=?", [id.uuidString])
    }

    public func purge(_ id: UUID) throws { try purge([id]) }

    /// Rows, search entries and OCR blocks go together (blocks via ON DELETE CASCADE).
    public func purge(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try Self.exec(db, "BEGIN")
        do {
            for id in ids {
                try Self.run(db, "DELETE FROM artifact_search WHERE rowid=(SELECT rowid FROM artifacts WHERE id=?)", [id.uuidString])
                try Self.run(db, "DELETE FROM artifacts WHERE id=?", [id.uuidString])
            }
            try Self.exec(db, "COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Stores the recognized lines with their boxes; replaces any previous blocks.
    public func setOCRBlocks(_ blocks: [OCRBlock], for id: UUID) throws {
        try Self.exec(db, "BEGIN")
        do {
            try Self.run(db, "DELETE FROM ocr_blocks WHERE artifact_id=?", [id.uuidString])
            for (i, b) in blocks.enumerated() {
                try Self.run(db, "INSERT INTO ocr_blocks(artifact_id,idx,text,x,y,w,h) VALUES(?,?,?,?,?,?,?)",
                             [id.uuidString, i, b.text, b.x, b.y, b.w, b.h])
            }
            try Self.exec(db, "COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func ocrBlocks(for id: UUID) throws -> [OCRBlock] {
        var out: [OCRBlock] = []
        try Self.query(db, "SELECT text,x,y,w,h FROM ocr_blocks WHERE artifact_id=? ORDER BY idx", [id.uuidString]) {
            out.append(OCRBlock(text: String(cString: sqlite3_column_text($0, 0)), x: sqlite3_column_double($0, 1),
                                y: sqlite3_column_double($0, 2), w: sqlite3_column_double($0, 3), h: sqlite3_column_double($0, 4)))
        }
        return out
    }

    /// Drops every recognized text and box; the captures themselves stay.
    public func clearTextIndex() throws {
        try Self.exec(db, "BEGIN; UPDATE artifact_search SET ocr_text=''; DELETE FROM ocr_blocks; COMMIT;")
    }

    /// Trashed items, optionally only those trashed before `date`.
    /// Distinct source apps present in the library (filter menu).
    public func sourceApps() throws -> [String] {
        var out: [String] = []
        try Self.query(db, "SELECT DISTINCT source_app FROM artifacts WHERE source_app IS NOT NULL AND deleted_at IS NULL ORDER BY source_app COLLATE NOCASE", []) {
            out.append(String(cString: sqlite3_column_text($0, 0)))
        }
        return out
    }

    public func trashedIDs(before date: Date? = nil) throws -> [UUID] {
        var ids: [UUID] = []
        try Self.query(db, "SELECT id FROM artifacts WHERE deleted_at IS NOT NULL AND deleted_at < ?",
                       [date?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude]) {
            if let id = Self.uuid($0, 0) { ids.append(id) }
        }
        return ids
    }

    public func count(_ q: HistoryQuery) throws -> Int {
        let (from, conds, args) = Self.filter(q)
        var n = 0
        try Self.query(db, "SELECT COUNT(*) FROM artifacts a" + from + (conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND ")), args) {
            n = Int(sqlite3_column_int64($0, 0))
        }
        return n
    }

    private static func filter(_ q: HistoryQuery) -> (join: String, conds: [String], args: [Any?]) {
        var join = "", conds: [String] = [], args: [Any?] = []
        if let text = q.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            join = " JOIN artifact_search s ON s.artifact_id = a.id"
            conds.append("artifact_search MATCH ?")
            args.append(ftsQuery(text))
        }
        if let t = q.type { conds.append("a.type = ?"); args.append(t.rawValue) }
        if q.favoritesOnly { conds.append("a.favorite = 1") }
        if let tag = q.tag.flatMap(normalizeTag) {
            conds.append("EXISTS (SELECT 1 FROM artifact_tags x JOIN tags t ON t.id = x.tag_id WHERE x.artifact_id = a.id AND t.name = ?)")
            args.append(tag)
        }
        if let app = q.sourceApp { conds.append("a.source_app = ?"); args.append(app) }
        if q.trashedOnly { conds.append("a.deleted_at IS NOT NULL") } else if !q.includeDeleted { conds.append("a.deleted_at IS NULL") }
        return (join, conds, args)
    }

    /// LIMIT/OFFSET paging. shortcut: offset cost grows with depth; switch to keyset paging if pages go past ~10k rows.
    public func search(_ q: HistoryQuery) throws -> [StoredArtifact] {
        var (sql, conds, args) = Self.filter(q)
        sql = "SELECT a.id,a.type,a.created_at,a.source_app,a.width,a.height,a.format,a.original_path,a.byte_size,a.favorite,a.deleted_at,a.is_private,a.project_path FROM artifacts a" + sql
        if !conds.isEmpty { sql += " WHERE " + conds.joined(separator: " AND ") }
        sql += " ORDER BY a.created_at DESC LIMIT ? OFFSET ?"
        args.append(q.limit); args.append(q.offset)
        var out: [StoredArtifact] = []
        try Self.query(db, sql, args) { if let a = Self.artifact(from: $0) { out.append(a) } }
        return out
    }

    private static func artifact(from s: OpaquePointer?) -> StoredArtifact? {
        guard let id = uuid(s, 0) else { return nil } // a damaged row is skipped, not fatal
        return StoredArtifact(
            id: id,
            type: ArtifactType(rawValue: String(cString: sqlite3_column_text(s, 1))) ?? .screenshot,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
            sourceApp: sqlite3_column_text(s, 3).map { String(cString: $0) },
            width: Int(sqlite3_column_int64(s, 4)), height: Int(sqlite3_column_int64(s, 5)),
            format: String(cString: sqlite3_column_text(s, 6)),
            originalPath: String(cString: sqlite3_column_text(s, 7)),
            byteSize: sqlite3_column_int64(s, 8), favorite: sqlite3_column_int(s, 9) != 0,
            deletedAt: sqlite3_column_type(s, 10) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 10)),
            isPrivate: sqlite3_column_int(s, 11) != 0,
            projectPath: sqlite3_column_text(s, 12).map { String(cString: $0) })
    }

    // MARK: Tags (HIS)

    /// Lowercased, single-spaced, at most 40 characters; nil when nothing is left.
    public static func normalizeTag(_ raw: String) -> String? {
        let t = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return t.isEmpty ? nil : String(t.prefix(40))
    }

    public func tags(for id: UUID) throws -> [String] {
        var out: [String] = []
        try Self.query(db, "SELECT t.name FROM tags t JOIN artifact_tags x ON x.tag_id=t.id WHERE x.artifact_id=? ORDER BY t.name", [id.uuidString]) {
            out.append(String(cString: sqlite3_column_text($0, 0)))
        }
        return out
    }

    /// Every tag in use with its item count (library sidebar / filter menu).
    public func allTags() throws -> [(name: String, count: Int)] {
        var out: [(String, Int)] = []
        try Self.query(db, "SELECT t.name, COUNT(*) FROM tags t JOIN artifact_tags x ON x.tag_id=t.id JOIN artifacts a ON a.id=x.artifact_id WHERE a.deleted_at IS NULL GROUP BY t.id ORDER BY t.name", []) {
            out.append((String(cString: sqlite3_column_text($0, 0)), Int(sqlite3_column_int64($0, 1))))
        }
        return out
    }

    public func addTag(_ raw: String, to ids: [UUID]) throws {
        guard let tag = Self.normalizeTag(raw) else { return }
        try Self.exec(db, "BEGIN")
        do {
            try Self.run(db, "INSERT OR IGNORE INTO tags(name) VALUES(?)", [tag])
            for id in ids {
                try Self.run(db, "INSERT OR IGNORE INTO artifact_tags(artifact_id,tag_id) SELECT ?, id FROM tags WHERE name=?", [id.uuidString, tag])
                try refreshSearchName(id)
            }
            try Self.exec(db, "COMMIT")
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }

    public func removeTag(_ raw: String, from ids: [UUID]) throws {
        guard let tag = Self.normalizeTag(raw) else { return }
        try Self.exec(db, "BEGIN")
        do {
            for id in ids {
                try Self.run(db, "DELETE FROM artifact_tags WHERE artifact_id=? AND tag_id=(SELECT id FROM tags WHERE name=?)", [id.uuidString, tag])
                try refreshSearchName(id)
            }
            try Self.run(db, "DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM artifact_tags)", [])
            try Self.exec(db, "COMMIT")
        } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
    }

    /// Free-text search also finds tags: they live in the FTS `name` column next to the file facts.
    private func refreshSearchName(_ id: UUID) throws {
        var found: StoredArtifact?
        try Self.query(db, "SELECT id,type,created_at,source_app,width,height,format,original_path,byte_size,favorite,deleted_at,is_private,project_path FROM artifacts WHERE id=?", [id.uuidString]) {
            found = Self.artifact(from: $0)
        }
        guard let a = found else { return }
        let tags = try tags(for: id)
        try Self.run(db, "UPDATE artifact_search SET name=? WHERE rowid=(SELECT rowid FROM artifacts WHERE id=?)",
                     [Self.searchName(a) + (tags.isEmpty ? "" : " " + tags.joined(separator: " ")), id.uuidString])
    }

    /// Ids of items beyond the retention policy (oldest first). `maxCount`/`maxAge` nil = never delete.
    public func retentionCandidates(maxCount: Int?, maxAge: TimeInterval?, now: Date = Date()) throws -> [UUID] {
        var ids: [UUID] = []
        if let maxAge {
            try Self.query(db, "SELECT id FROM artifacts WHERE favorite=0 AND deleted_at IS NULL AND created_at < ? ORDER BY created_at",
                           [now.timeIntervalSince1970 - maxAge]) { if let id = Self.uuid($0, 0) { ids.append(id) } }
        }
        if let maxCount {
            try Self.query(db, "SELECT id FROM artifacts WHERE favorite=0 AND deleted_at IS NULL ORDER BY created_at DESC LIMIT -1 OFFSET ?",
                           [maxCount]) { if let id = Self.uuid($0, 0), !ids.contains(id) { ids.append(id) } }
        }
        return ids
    }

    /// User text becomes a prefix search of quoted terms, so FTS syntax in input can't break the query.
    static func ftsQuery(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " ")
    }

    // MARK: - SQLite helpers

    /// Parses a UUID column; nil for a value the app would never have written.
    private static func uuid(_ stmt: OpaquePointer?, _ col: Int32) -> UUID? {
        sqlite3_column_text(stmt, col).flatMap { UUID(uuidString: String(cString: $0)) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw HistoryError(description: msg)
        }
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryError(description: String(cString: sqlite3_errmsg(db)))
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            default: sqlite3_finalize(stmt); throw HistoryError(description: "unsupported bind type")
            }
        }
        return stmt
    }

    private static func run(_ db: OpaquePointer?, _ sql: String, _ args: [Any?]) throws {
        let stmt = try prepare(db, sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryError(description: String(cString: sqlite3_errmsg(db))) }
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, _ args: [Any?], row: (OpaquePointer?) -> Void) throws {
        let stmt = try prepare(db, sql, args)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc == SQLITE_DONE { return }
            throw HistoryError(description: String(cString: sqlite3_errmsg(db)))
        }
    }
}

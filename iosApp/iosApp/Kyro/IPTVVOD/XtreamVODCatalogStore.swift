#if os(iOS)
import Foundation
import SQLite3

/// Provider-scoped, paged catalog. A refresh remains invisible until its generation is promoted.
actor XtreamVODCatalogStore {
    private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The catalog is re-downloadable, so a purgeable cache is appropriate on iOS.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        (fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("IPTVVOD", isDirectory: true)
    }

    init(directory: URL? = nil) throws {
        let root = directory ?? Self.defaultDirectory()
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { throw XtreamVODError.storage }
        let path = root.appendingPathComponent("catalog.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw XtreamVODError.storage
        }
        let openedDatabase = database
        func initialize(_ sql: String) throws {
            guard sqlite3_exec(openedDatabase, sql, nil, nil, nil) == SQLITE_OK else { throw XtreamVODError.storage }
        }
        // NORMAL is durable across app crashes in WAL mode and keeps 100k-row imports fast. A power
        // loss can drop only the last commit; promotion is a single transaction, so the active
        // catalog is always a complete generation.
        try initialize("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;")
        try initialize("""
            CREATE TABLE IF NOT EXISTS vod_items (
              provider TEXT NOT NULL, kind TEXT NOT NULL, generation TEXT NOT NULL, remote_id INTEGER NOT NULL,
              title TEXT NOT NULL, category TEXT NOT NULL, poster TEXT, ext TEXT, summary TEXT, genre TEXT, rating TEXT,
              PRIMARY KEY(provider, kind, generation, remote_id)
            );
            CREATE TABLE IF NOT EXISTS vod_active (
              provider TEXT NOT NULL, kind TEXT NOT NULL, generation TEXT NOT NULL,
              PRIMARY KEY(provider, kind)
            );
            CREATE INDEX IF NOT EXISTS vod_browse ON vod_items(provider, kind, generation, title COLLATE NOCASE);
            CREATE INDEX IF NOT EXISTS vod_category_browse ON vod_items(provider, kind, generation, category, title COLLATE NOCASE);
            """)
    }

    deinit { if let database { sqlite3_close(database) } }

    /// Close explicitly before test fixtures are removed; production stores close on deinit.
    func close() {
        if let database { sqlite3_close(database) }
        database = nil
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw XtreamVODError.storage }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw XtreamVODError.storage
        }
        return statement
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_text(statement, index, value, -1, Self.transient) }
        else { sqlite3_bind_null(statement, index) }
    }

    func stage(_ items: [XtreamVODItem], generation: String) throws {
        guard !items.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT OR REPLACE INTO vod_items(provider,kind,generation,remote_id,title,category,poster,ext,summary,genre,rating)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(statement) }
            for item in items {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(item.providerID.uuidString, at: 1, in: statement)
                bind(item.kind.rawValue, at: 2, in: statement)
                bind(generation, at: 3, in: statement)
                sqlite3_bind_int64(statement, 4, sqlite3_int64(item.remoteID))
                bind(item.title, at: 5, in: statement)
                bind(item.category, at: 6, in: statement)
                bind(item.poster, at: 7, in: statement)
                bind(item.fileExtension, at: 8, in: statement)
                bind(item.summary, at: 9, in: statement)
                bind(item.genre, at: 10, in: statement)
                bind(item.rating, at: 11, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw XtreamVODError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func promote(providerID: UUID, kind: XtreamVODKind, generation: String) throws {
        try promoteAll(providerID: providerID, generations: [(kind, generation)])
    }

    func promoteAll(providerID: UUID, generations: [(XtreamVODKind, String)]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for (kind, generation) in generations {
                let statement = try prepare("INSERT OR REPLACE INTO vod_active(provider,kind,generation) VALUES(?,?,?)")
                bind(providerID.uuidString, at: 1, in: statement)
                bind(kind.rawValue, at: 2, in: statement)
                bind(generation, at: 3, in: statement)
                let result = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw XtreamVODError.storage }
                let cleanup = try prepare("DELETE FROM vod_items WHERE provider=? AND kind=? AND generation<>?")
                bind(providerID.uuidString, at: 1, in: cleanup)
                bind(kind.rawValue, at: 2, in: cleanup)
                bind(generation, at: 3, in: cleanup)
                let cleanResult = sqlite3_step(cleanup)
                sqlite3_finalize(cleanup)
                guard cleanResult == SQLITE_DONE else { throw XtreamVODError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func discard(providerID: UUID, kind: XtreamVODKind, generation: String) {
        guard let statement = try? prepare("DELETE FROM vod_items WHERE provider=? AND kind=? AND generation=?") else { return }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        bind(generation, at: 3, in: statement)
        sqlite3_step(statement)
    }

    func remove(providerID: UUID) {
        for table in ["vod_active", "vod_items"] {
            guard let statement = try? prepare("DELETE FROM \(table) WHERE provider=?") else { continue }
            bind(providerID.uuidString, at: 1, in: statement)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    func count(providerID: UUID, kind: XtreamVODKind) -> Int {
        guard let statement = try? prepare("""
            SELECT COUNT(*) FROM vod_items i JOIN vod_active a
              ON i.provider=a.provider AND i.kind=a.kind AND i.generation=a.generation
            WHERE i.provider=? AND i.kind=?
            """) else { return 0 }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    func categories(providerID: UUID, kind: XtreamVODKind) -> [String] {
        guard let statement = try? prepare("""
            SELECT DISTINCT i.category FROM vod_items i JOIN vod_active a
              ON i.provider=a.provider AND i.kind=a.kind AND i.generation=a.generation
            WHERE i.provider=? AND i.kind=? ORDER BY i.category COLLATE NOCASE
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { names.append(String(cString: raw)) }
        }
        return names
    }

    func page(providerID: UUID, kind: XtreamVODKind, query: String = "", category: String? = nil,
              offset: Int = 0, limit: Int = 100) -> [XtreamVODItem] {
        let statement: OpaquePointer
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Browsing (no query) walks the title index directly instead of testing every row.
        let categoryFilter = category == nil ? "" : " AND i.category=?"
        let filter = trimmed.isEmpty ? "" : " AND i.title LIKE ? ESCAPE '\\'"
        do {
            statement = try prepare("""
                SELECT i.remote_id,i.title,i.category,i.poster,i.ext,i.summary,i.genre,i.rating
                FROM vod_items i JOIN vod_active a
                  ON i.provider=a.provider AND i.kind=a.kind AND i.generation=a.generation
                WHERE i.provider=? AND i.kind=?\(categoryFilter)\(filter)
                ORDER BY i.title COLLATE NOCASE, i.remote_id LIMIT ? OFFSET ?
                """)
        } catch { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        var next: Int32 = 3
        if let category {
            bind(category, at: next, in: statement)
            next += 1
        }
        if !trimmed.isEmpty {
            let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            bind("%\(escaped)%", at: next, in: statement)
            next += 1
        }
        sqlite3_bind_int(statement, next, Int32(min(max(limit, 1), 100)))
        sqlite3_bind_int(statement, next + 1, Int32(max(0, offset)))
        func value(_ index: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: raw)
        }
        var items: [XtreamVODItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(.init(providerID: providerID, kind: kind, remoteID: Int(sqlite3_column_int64(statement, 0)),
                               title: value(1) ?? "Untitled", category: value(2) ?? "Other",
                               poster: value(3), fileExtension: value(4), summary: value(5),
                               genre: value(6), rating: value(7)))
        }
        return items
    }

    func item(providerID: UUID, kind: XtreamVODKind, remoteID: Int) -> XtreamVODItem? {
        guard let statement = try? prepare("""
            SELECT i.title,i.category,i.poster,i.ext,i.summary,i.genre,i.rating
            FROM vod_items i JOIN vod_active a
              ON i.provider=a.provider AND i.kind=a.kind AND i.generation=a.generation
            WHERE i.provider=? AND i.kind=? AND i.remote_id=? LIMIT 1
            """) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, at: 1, in: statement)
        bind(kind.rawValue, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, sqlite3_int64(remoteID))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func value(_ index: Int32) -> String? {
            guard let raw = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: raw)
        }
        return .init(providerID: providerID, kind: kind, remoteID: remoteID,
                     title: value(0) ?? "Untitled", category: value(1) ?? "Other",
                     poster: value(2), fileExtension: value(3), summary: value(4),
                     genre: value(5), rating: value(6))
    }
}
#endif

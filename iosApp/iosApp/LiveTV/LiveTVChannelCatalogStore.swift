#if os(iOS) || KYRO_CHANNEL_HOST_TESTS
import Foundation
import SQLite3

/// Disk-backed provider catalog foundation. A generation is invisible until `promote` verifies
/// its contiguous ordinals and atomically switches `channel_active`. Callers fetch bounded pages
/// or individual IDs; no query returns an entire catalog of `LiveTVChannel` values.
actor LiveTVChannelCatalogStore {
    enum StoreError: Error { case storage, invalidGeneration, invalidIdentity }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var database: OpaquePointer?

    static func defaultDirectory() -> URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("Silo/LiveTV/ChannelCatalog", isDirectory: true)
    }

    init(directory: URL? = nil) throws {
        let root = directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        // M3U stream addresses may embed provider credentials. This cache is excluded from
        // backups by location and inherits data protection for the database and WAL files.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: root.path)
        #endif
        guard sqlite3_open_v2(root.appendingPathComponent("channels.sqlite").path, &database,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.storage
        }
        let db = database
        func initialize(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.storage }
        }
        try initialize("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;")
        try initialize("""
            CREATE TABLE IF NOT EXISTS channel_items (
              provider TEXT NOT NULL, generation TEXT NOT NULL, ordinal INTEGER NOT NULL,
              id TEXT NOT NULL, guide_id TEXT, name TEXT NOT NULL, category TEXT NOT NULL,
              stream_url TEXT NOT NULL, logo_url TEXT, stream_id INTEGER,
              PRIMARY KEY(provider,generation,id), UNIQUE(provider,generation,ordinal)
            );
            CREATE TABLE IF NOT EXISTS channel_active (
              provider TEXT PRIMARY KEY, generation TEXT NOT NULL, channel_count INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS channel_favorites (
              provider TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(provider,id)
            );
            CREATE INDEX IF NOT EXISTS channel_order ON channel_items(provider,generation,ordinal);
            CREATE INDEX IF NOT EXISTS channel_category ON channel_items(provider,generation,category,ordinal);
            CREATE INDEX IF NOT EXISTS channel_guide ON channel_items(provider,generation,guide_id,ordinal);
            CREATE VIRTUAL TABLE IF NOT EXISTS channel_search USING fts5(
              name, category, content='channel_items', content_rowid='rowid',
              tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS channel_fts_insert AFTER INSERT ON channel_items BEGIN
              INSERT INTO channel_search(rowid,name,category) VALUES(new.rowid,new.name,new.category);
            END;
            CREATE TRIGGER IF NOT EXISTS channel_fts_delete AFTER DELETE ON channel_items BEGIN
              INSERT INTO channel_search(channel_search,rowid,name,category)
                VALUES('delete',old.rowid,old.name,old.category);
            END;
            """)
    }

    deinit { if let database { sqlite3_close(database) } }
    func close() { if let database { sqlite3_close(database) }; database = nil }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.storage }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.storage
        }
        return statement
    }
    private func bind(_ text: String?, _ index: Int32, _ statement: OpaquePointer) {
        if let text { sqlite3_bind_text(statement, index, text, -1, Self.transient) }
        else { sqlite3_bind_null(statement, index) }
    }

    /// The caller assigns contiguous source ordinals before batching. Parsers must deduplicate
    /// IDs first; ignored duplicates leave ordinal gaps and make promotion fail safely.
    func stage(_ channels: [LiveTVChannel], providerID: UUID, generation: String,
               startingOrdinal: Int) throws -> Int {
        guard !channels.isEmpty else { return 0 }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT OR IGNORE INTO channel_items
                  (provider,generation,ordinal,id,guide_id,name,category,stream_url,logo_url,stream_id)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(statement) }
            var inserted = 0
            for (offset, channel) in channels.enumerated() {
                if offset.isMultiple(of: 256) { try Task.checkCancellation() }
                guard channel.id.hasPrefix(providerID.uuidString + ":"),
                      ["http", "https"].contains(channel.streamURL.scheme?.lowercased() ?? "") else {
                    throw StoreError.invalidIdentity
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(providerID.uuidString, 1, statement)
                bind(generation, 2, statement)
                sqlite3_bind_int64(statement, 3, sqlite3_int64(startingOrdinal + offset))
                bind(channel.id, 4, statement)
                bind(channel.guideID, 5, statement)
                bind(channel.name, 6, statement)
                bind(channel.category, 7, statement)
                bind(channel.streamURL.absoluteString, 8, statement)
                bind(channel.logoURL?.absoluteString, 9, statement)
                if let streamID = channel.streamID { sqlite3_bind_int64(statement, 10, sqlite3_int64(streamID)) }
                else { sqlite3_bind_null(statement, 10) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.storage }
                inserted += Int(sqlite3_changes(database))
            }
            try execute("COMMIT")
            return inserted
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Refuses incomplete or non-contiguous imports. Promotion never deletes the old generation
    /// in its transaction; the reader-visible switch stays short even at 100,000 rows.
    func promote(providerID: UUID, generation: String, expectedCount: Int) throws {
        guard expectedCount > 0 else { throw StoreError.invalidGeneration }
        try execute("BEGIN IMMEDIATE")
        do {
            let check = try prepare("""
                SELECT COUNT(*),MIN(ordinal),MAX(ordinal) FROM channel_items
                WHERE provider=? AND generation=?
                """)
            bind(providerID.uuidString, 1, check)
            bind(generation, 2, check)
            let valid = sqlite3_step(check) == SQLITE_ROW
                && sqlite3_column_int64(check, 0) == expectedCount
                && sqlite3_column_int64(check, 1) == 0
                && sqlite3_column_int64(check, 2) == expectedCount - 1
            sqlite3_finalize(check)
            guard valid else { throw StoreError.invalidGeneration }
            let statement = try prepare("""
                INSERT INTO channel_active(provider,generation,channel_count) VALUES(?,?,?)
                ON CONFLICT(provider) DO UPDATE SET generation=excluded.generation,
                  channel_count=excluded.channel_count
                """)
            bind(providerID.uuidString, 1, statement)
            bind(generation, 2, statement)
            sqlite3_bind_int64(statement, 3, sqlite3_int64(expectedCount))
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw StoreError.storage }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func count(providerID: UUID) -> Int {
        guard let statement = try? prepare("SELECT channel_count FROM channel_active WHERE provider=?") else { return 0 }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    func setFavorite(_ favorite: Bool, channelID: String, providerID: UUID) throws {
        guard channelID.hasPrefix(providerID.uuidString + ":") else { throw StoreError.invalidIdentity }
        let statement = try prepare(favorite
            ? "INSERT OR IGNORE INTO channel_favorites(provider,id) VALUES(?,?)"
            : "DELETE FROM channel_favorites WHERE provider=? AND id=?")
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        bind(channelID, 2, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.storage }
    }

    private static func expression(_ query: String) -> String? {
        let terms = query.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
        guard !terms.isEmpty else { return nil }
        let bounded = Array(terms.prefix(8))
        // Prefix-expanding a ubiquitous token such as "Channel" traverses its entire posting
        // list even when a later token is selective. Only the trailing, in-progress token needs
        // prefix matching for typeahead; preceding words are exact terms.
        return bounded.enumerated().map { index, term in
            "\"\(term)\"" + (index == bounded.count - 1 ? "*" : "")
        }.joined(separator: " AND ")
    }

    /// Unfiltered pages seek directly to their ordinal; category/favorites pages use their
    /// respective indexes. A supplied `afterOrdinal` supports constant-memory keyset scrolling.
    func page(providerID: UUID, query: String = "", category: String? = nil,
              favoritesOnly: Bool = false, offset: Int = 0, afterOrdinal: Int? = nil,
              limit: Int = 100) -> [LiveTVChannel] {
        let search = Self.expression(query)
        let favoriteJoin = favoritesOnly ? " JOIN channel_favorites f ON f.provider=i.provider AND f.id=i.id" : ""
        let categoryFilter = category == nil ? "" : " AND i.category=?"
        // An ordinary FTS JOIN lets SQLite choose the ordinal index first, then probe the FTS
        // virtual table once per channel (seconds at 100K). The rowid subquery computes the
        // bounded match set once before applying provider/generation and ordinal order.
        let searchFilter = search == nil ? "" : " AND i.rowid IN (SELECT rowid FROM channel_search WHERE channel_search MATCH ?)"
        let ordinalFilter = afterOrdinal == nil && category == nil && search == nil && !favoritesOnly
            ? " AND i.ordinal>=?" : (afterOrdinal == nil ? "" : " AND i.ordinal>?")
        guard let statement = try? prepare("""
            SELECT i.id,i.guide_id,i.name,i.category,i.stream_url,i.logo_url,i.stream_id
            FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            \(favoriteJoin)
            WHERE i.provider=?\(categoryFilter)\(searchFilter)\(ordinalFilter)
            ORDER BY i.ordinal LIMIT ? OFFSET ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        var next: Int32 = 2
        if let category { bind(category, next, statement); next += 1 }
        if let search { bind(search, next, statement); next += 1 }
        if let afterOrdinal {
            sqlite3_bind_int64(statement, next, sqlite3_int64(afterOrdinal))
            next += 1
        } else if category == nil && search == nil && !favoritesOnly {
            sqlite3_bind_int64(statement, next, sqlite3_int64(max(0, offset)))
            next += 1
        }
        sqlite3_bind_int(statement, next, Int32(min(max(limit, 1), 200)))
        sqlite3_bind_int(statement, next + 1,
                         Int32(afterOrdinal == nil && (category != nil || search != nil || favoritesOnly) ? max(0, offset) : 0))
        var channels: [LiveTVChannel] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func value(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            guard let id = value(0), let name = value(2), let category = value(3),
                  let rawURL = value(4), let streamURL = URL(string: rawURL) else { continue }
            channels.append(LiveTVChannel(id: id, guideID: value(1), name: name, streamURL: streamURL,
                                          logoURL: value(5).flatMap(URL.init(string:)), category: category,
                                          streamID: sqlite3_column_type(statement, 6) == SQLITE_NULL
                                              ? nil : Int(sqlite3_column_int64(statement, 6))))
        }
        return channels
    }

    func channel(providerID: UUID, id: String) -> LiveTVChannel? {
        guard id.hasPrefix(providerID.uuidString + ":") else { return nil }
        guard let statement = try? prepare("""
            SELECT i.guide_id,i.name,i.category,i.stream_url,i.logo_url,i.stream_id
            FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            WHERE i.provider=? AND i.id=? LIMIT 1
            """) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        bind(id, 2, statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func value(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        guard let name = value(1), let category = value(2),
              let rawURL = value(3), let streamURL = URL(string: rawURL) else { return nil }
        return LiveTVChannel(id: id, guideID: value(0), name: name, streamURL: streamURL,
                             logoURL: value(4).flatMap(URL.init(string:)), category: category,
                             streamID: sqlite3_column_type(statement, 5) == SQLITE_NULL
                                 ? nil : Int(sqlite3_column_int64(statement, 5)))
    }

    /// A guide ID may legitimately map to several provider channels. Keep the lookup bounded
    /// and provider/generation-scoped rather than building a process-wide EPG association map.
    func channelIDs(providerID: UUID, guideID: String, limit: Int = 200) -> [String] {
        guard let statement = try? prepare("""
            SELECT i.id FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            WHERE i.provider=? AND i.guide_id=? ORDER BY i.ordinal LIMIT ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        bind(guideID, 2, statement)
        sqlite3_bind_int(statement, 3, Int32(min(max(limit, 1), 200)))
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { ids.append(String(cString: raw)) }
        }
        return ids
    }

    func categories(providerID: UUID) -> [(name: String, count: Int)] {
        guard let statement = try? prepare("""
            SELECT i.category,COUNT(*) FROM channel_items i JOIN channel_active a
              ON i.provider=a.provider AND i.generation=a.generation
            WHERE i.provider=? GROUP BY i.category
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(providerID.uuidString, 1, statement)
        var result: [(String, Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) {
                result.append((String(cString: raw), Int(sqlite3_column_int64(statement, 1))))
            }
        }
        return result.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    /// Removes only generations not referenced by `channel_active`, including crash orphans.
    /// Each transaction deletes at most 1,024 rows, then yields to reader requests.
    func pruneOrphans() async throws {
        var cursor: sqlite3_int64 = 0
        while true {
            try Task.checkCancellation()
            let selection = try prepare("""
                SELECT i.rowid FROM channel_items i WHERE i.rowid>? AND NOT EXISTS (
                  SELECT 1 FROM channel_active a WHERE a.provider=i.provider
                    AND a.generation=i.generation
                ) ORDER BY i.rowid LIMIT 1024
                """)
            sqlite3_bind_int64(selection, 1, cursor)
            var ids: [sqlite3_int64] = []
            var result = sqlite3_step(selection)
            while result == SQLITE_ROW {
                ids.append(sqlite3_column_int64(selection, 0))
                result = sqlite3_step(selection)
            }
            sqlite3_finalize(selection)
            guard result == SQLITE_DONE else { throw StoreError.storage }
            guard let last = ids.last else { return }
            cursor = last
            try execute("BEGIN IMMEDIATE")
            do {
                let deletion = try prepare("DELETE FROM channel_items WHERE rowid=?")
                defer { sqlite3_finalize(deletion) }
                for id in ids {
                    sqlite3_reset(deletion)
                    sqlite3_bind_int64(deletion, 1, id)
                    guard sqlite3_step(deletion) == SQLITE_DONE else { throw StoreError.storage }
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            await Task.yield()
        }
    }

    func remove(providerID: UUID) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["channel_active", "channel_favorites", "channel_items"] {
                let statement = try prepare("DELETE FROM \(table) WHERE provider=?")
                bind(providerID.uuidString, 1, statement)
                let result = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw StoreError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
#endif

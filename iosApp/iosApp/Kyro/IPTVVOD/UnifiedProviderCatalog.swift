#if os(iOS) || KYRO_VOD_HOST_TESTS
import Foundation
import SQLite3

// Provider-qualified Movies/Series catalog (Kyro Labs M2).
//
// Build 110's unified index has two storage arms, Silo's per-profile mirror and IPTV's active
// generations. This adds a third, generic arm keyed by a provider account, so any number of
// media-server accounts can contribute titles at once and without a Silo session. The Silo and
// IPTV arms and their tables are unchanged and remain the path for those two sources.
//
// Accounts are the text form of `ProviderAccountRef` ("jellyfin:<uuid>"), so this file does not
// depend on the provider package and compiles under the Mac host tests. Every table key includes
// the account, so the same remote ID on two servers is two different rows.

// MARK: - Source identity

/// One provider account contributing to a grid, optionally limited to some of its libraries.
struct UnifiedProviderSource: Hashable, Sendable {
    let account: String
    /// Nil reads every active library snapshot of the account; an empty list reads none.
    var libraries: [String]? = nil
}

/// One movie or series as a provider's catalog sync stages it.
struct UnifiedProviderRecord: Sendable, Equatable {
    let contentID: String
    let title: String
    let year: Int?
    let poster: String?
    /// The provider's opaque detail data, never interpreted by the index.
    let payload: Data
}

extension UnifiedCatalogKeys {
    /// The Xtream account of an IPTV provider, in the `ProviderAccountRef` text form. The Live TV
    /// provider's own UUID is the account ID, so existing IPTV rows have a stable identity.
    static func iptvAccount(providerID: UUID) -> String { "xtream:" + providerID.uuidString.lowercased() }

    /// Unique per (account, library, content). The fields are escaped so no pair of different
    /// triples can produce the same key: `%` and the separator are percent-encoded.
    static func providerEntryKey(account: String, library: String, contentID: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "\u{1F}", with: "%1F")
        }
        return "p:" + [account, library, contentID].map(escape).joined(separator: "\u{1F}")
    }
}

// MARK: - Schema, migration and rollback

extension XtreamVODCatalogStore {
    /// Version 2 of the unified catalog schema: additive tables only. Version 1 is Build 110's
    /// Silo and IPTV tables, which this never alters, so a database written by any earlier build
    /// opens unchanged, and an earlier build opens one written by this version unchanged.
    static let providerCatalogVersion = 2
    static let providerCatalogComponent = "provider-catalog"

    static var providerCatalogMigrationSQL: String {
        """
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS unified_schema (
          component TEXT PRIMARY KEY, version INTEGER NOT NULL, applied_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS unified_provider_items (
          account TEXT NOT NULL, library TEXT NOT NULL, kind TEXT NOT NULL, snapshot TEXT NOT NULL,
          content_id TEXT NOT NULL, title TEXT NOT NULL, year INTEGER, poster TEXT, payload BLOB NOT NULL,
          sort_key TEXT NOT NULL, match_key TEXT NOT NULL, entry_key TEXT NOT NULL,
          PRIMARY KEY(account, library, kind, snapshot, content_id)
        );
        CREATE INDEX IF NOT EXISTS unified_provider_browse ON unified_provider_items(kind, sort_key, match_key, entry_key);
        CREATE TABLE IF NOT EXISTS unified_provider_active (
          account TEXT NOT NULL, library TEXT NOT NULL, kind TEXT NOT NULL, snapshot TEXT NOT NULL,
          synced_at REAL NOT NULL, item_count INTEGER NOT NULL,
          PRIMARY KEY(account, library, kind)
        );
        CREATE TABLE IF NOT EXISTS unified_source_identity (
          legacy_key TEXT PRIMARY KEY, origin TEXT NOT NULL, account TEXT
        );
        INSERT OR IGNORE INTO unified_schema(component, version, applied_at)
          VALUES('\(providerCatalogComponent)', \(providerCatalogVersion), strftime('%s','now'));
        COMMIT;
        """
    }

    /// The recorded schema version of the provider catalog, or nil for a version 1 database.
    func providerCatalogSchemaVersion() -> Int? {
        guard let statement = try? prepare("SELECT version FROM unified_schema WHERE component=?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(Self.providerCatalogComponent, at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : nil
    }

    /// Removes exactly what version 2 added, returning the database to Build 110's schema. Silo
    /// and IPTV data, their keys and the full-text index are not touched. The provider catalog is
    /// re-downloadable, so this loses nothing that cannot be synced again.
    func rollbackProviderCatalog() throws {
        try execute("""
            BEGIN IMMEDIATE;
            DROP TABLE IF EXISTS unified_provider_items;
            DROP TABLE IF EXISTS unified_provider_active;
            DROP TABLE IF EXISTS unified_source_identity;
            DELETE FROM unified_schema WHERE component='\(Self.providerCatalogComponent)';
            COMMIT;
            """)
    }

    // MARK: Legacy source identities

    /// Records the provider-qualified identity of the data Build 110 already stored: every IPTV
    /// provider with an active generation gets its Xtream account, and every Silo mirror scope is
    /// listed so the app can bind it to its Silo account. Idempotent; never changes a stored row,
    /// and never replaces an account already bound to a scope.
    @discardableResult
    func backfillLegacySourceIdentities() throws -> Int {
        var added = 0
        let providers = try prepare("SELECT DISTINCT provider FROM vod_active")
        var ids: [UUID] = []
        while sqlite3_step(providers) == SQLITE_ROW {
            if let id = sqlite3_column_text(providers, 0).flatMap({ UUID(uuidString: String(cString: $0)) }) { ids.append(id) }
        }
        sqlite3_finalize(providers)
        var scopes: [String] = []
        let silo = try prepare("SELECT DISTINCT scope FROM unified_silo_active")
        while sqlite3_step(silo) == SQLITE_ROW {
            if let scope = sqlite3_column_text(silo, 0).map({ String(cString: $0) }) { scopes.append(scope) }
        }
        sqlite3_finalize(silo)
        try execute("BEGIN IMMEDIATE")
        do {
            let insert = try prepare("INSERT OR IGNORE INTO unified_source_identity(legacy_key, origin, account) VALUES(?,?,?)")
            defer { sqlite3_finalize(insert) }
            func record(_ key: String, _ origin: String, _ account: String?) throws {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                bind(key, at: 1, in: insert)
                bind(origin, at: 2, in: insert)
                bind(account, at: 3, in: insert)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw XtreamVODError.storage }
                added += Int(sqlite3_changes(sqlite3_db_handle(insert)))
            }
            for id in ids { try record("iptv:" + id.uuidString.lowercased(), "iptv", UnifiedCatalogKeys.iptvAccount(providerID: id)) }
            for scope in scopes { try record("silo-scope:" + scope, "silo", nil) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return added
    }

    /// Binds a Silo mirror scope to its Silo account. A scope keeps the account it was first bound
    /// to: the same scope can only ever belong to one server.
    func bindSiloScope(_ scope: String, to account: String) throws {
        let statement = try prepare("""
            INSERT INTO unified_source_identity(legacy_key, origin, account) VALUES(?,?,?)
            ON CONFLICT(legacy_key) DO UPDATE SET account=excluded.account WHERE unified_source_identity.account IS NULL
            """)
        defer { sqlite3_finalize(statement) }
        bind("silo-scope:" + scope, at: 1, in: statement)
        bind("silo", at: 2, in: statement)
        bind(account, at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw XtreamVODError.storage }
    }

    /// The legacy storage keys that belong to a provider account, sorted.
    func legacySources(account: String) -> [String] {
        guard let statement = try? prepare("SELECT legacy_key FROM unified_source_identity WHERE account=? ORDER BY legacy_key") else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(account, at: 1, in: statement)
        var keys: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let key = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) { keys.append(key) }
        }
        return keys
    }

    // MARK: Snapshots

    /// Adds one page to a snapshot that is not yet visible. Browsing reads only the snapshot
    /// recorded in `unified_provider_active`, so a partial sync is never published.
    func stageProvider(_ records: [UnifiedProviderRecord], account: String, library: String,
                       kind: XtreamVODKind, snapshot: String) throws {
        guard !records.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT INTO unified_provider_items(account,library,kind,snapshot,content_id,title,year,poster,payload,sort_key,match_key,entry_key)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(account,library,kind,snapshot,content_id) DO UPDATE SET
                  title=excluded.title, year=excluded.year, poster=excluded.poster, payload=excluded.payload,
                  sort_key=excluded.sort_key, match_key=excluded.match_key
                """)
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(account, at: 1, in: statement)
                bind(library, at: 2, in: statement)
                bind(kind.rawValue, at: 3, in: statement)
                bind(snapshot, at: 4, in: statement)
                bind(record.contentID, at: 5, in: statement)
                bind(record.title, at: 6, in: statement)
                if let year = record.year { sqlite3_bind_int64(statement, 7, sqlite3_int64(year)) }
                else { sqlite3_bind_null(statement, 7) }
                bind(record.poster, at: 8, in: statement)
                _ = record.payload.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 9, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
                bind(UnifiedCatalogKeys.sortKey(title: record.title, year: record.year), at: 10, in: statement)
                bind(UnifiedCatalogKeys.matchKey(title: record.title, year: record.year), at: 11, in: statement)
                bind(UnifiedCatalogKeys.providerEntryKey(account: account, library: library, contentID: record.contentID),
                     at: 12, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw XtreamVODError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Makes a completed snapshot visible and deletes every other snapshot of that library in the
    /// same transaction.
    func promoteProvider(account: String, library: String, kind: XtreamVODKind, snapshot: String,
                         itemCount: Int, syncedAt: Date) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let activate = try prepare("""
                INSERT OR REPLACE INTO unified_provider_active(account,library,kind,snapshot,synced_at,item_count)
                VALUES(?,?,?,?,?,?)
                """)
            bind(account, at: 1, in: activate)
            bind(library, at: 2, in: activate)
            bind(kind.rawValue, at: 3, in: activate)
            bind(snapshot, at: 4, in: activate)
            sqlite3_bind_double(activate, 5, syncedAt.timeIntervalSince1970)
            sqlite3_bind_int64(activate, 6, sqlite3_int64(itemCount))
            let activated = sqlite3_step(activate)
            sqlite3_finalize(activate)
            guard activated == SQLITE_DONE else { throw XtreamVODError.storage }
            let retire = try prepare("DELETE FROM unified_provider_items WHERE account=? AND library=? AND kind=? AND snapshot<>?")
            bind(account, at: 1, in: retire)
            bind(library, at: 2, in: retire)
            bind(kind.rawValue, at: 3, in: retire)
            bind(snapshot, at: 4, in: retire)
            let retired = sqlite3_step(retire)
            sqlite3_finalize(retire)
            guard retired == SQLITE_DONE else { throw XtreamVODError.storage }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Drops an unfinished snapshot. Never touches the active one.
    func discardProvider(account: String, library: String, kind: XtreamVODKind, snapshot: String) {
        guard let statement = try? prepare("""
            DELETE FROM unified_provider_items WHERE account=? AND library=? AND kind=? AND snapshot=?
              AND NOT EXISTS (SELECT 1 FROM unified_provider_active a WHERE a.account=? AND a.library=?
                AND a.kind=? AND a.snapshot=?)
            """) else { return }
        defer { sqlite3_finalize(statement) }
        for offset in [Int32(0), 4] {
            bind(account, at: 1 + offset, in: statement)
            bind(library, at: 2 + offset, in: statement)
            bind(kind.rawValue, at: 3 + offset, in: statement)
            bind(snapshot, at: 4 + offset, in: statement)
        }
        sqlite3_step(statement)
    }

    /// Removes every snapshot of one library, active included. Used when a first sync that was
    /// publishing while it walked lost its account: everything stored came from that walk.
    func retractProvider(account: String, library: String, kind: XtreamVODKind) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["unified_provider_active", "unified_provider_items"] {
                let statement = try prepare("DELETE FROM \(table) WHERE account=? AND library=? AND kind=?")
                bind(account, at: 1, in: statement)
                bind(library, at: 2, in: statement)
                bind(kind.rawValue, at: 3, in: statement)
                let result = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw XtreamVODError.storage }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// When the last completed sync of a library finished; `.distantPast` while a first sync is
    /// still publishing; nil when nothing was ever published.
    func providerSyncedAt(account: String, library: String, kind: XtreamVODKind) -> Date? {
        guard let statement = try? prepare("""
            SELECT synced_at FROM unified_provider_active WHERE account=? AND library=? AND kind=?
            """) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(account, at: 1, in: statement)
        bind(library, at: 2, in: statement)
        bind(kind.rawValue, at: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    /// Removes everything one account contributed, for when the account is removed. Other
    /// accounts, Silo and IPTV rows are untouched.
    func purgeProvider(account: String) throws {
        for table in ["unified_provider_active", "unified_provider_items"] {
            let statement = try prepare("DELETE FROM \(table) WHERE account=?")
            bind(account, at: 1, in: statement)
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw XtreamVODError.storage }
        }
    }

    /// Libraries an account no longer lists are removed rather than hidden.
    func retainProviderLibraries(account: String, kind: XtreamVODKind, libraries: [String]) throws {
        for table in ["unified_provider_active", "unified_provider_items"] {
            let marks = libraries.isEmpty ? "" : " AND library NOT IN (" + libraries.map { _ in "?" }.joined(separator: ",") + ")"
            let statement = try prepare("DELETE FROM \(table) WHERE account=? AND kind=?\(marks)")
            bind(account, at: 1, in: statement)
            bind(kind.rawValue, at: 2, in: statement)
            for (index, library) in libraries.enumerated() { bind(library, at: Int32(3 + index), in: statement) }
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw XtreamVODError.storage }
        }
    }

    /// Stored provider rows, every account and snapshot, for diagnostics and tests.
    func providerRowCounts() -> (items: Int, active: Int) {
        func count(_ table: String) -> Int {
            guard let statement = try? prepare("SELECT COUNT(*) FROM \(table)") else { return -1 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
        }
        return (count("unified_provider_items"), count("unified_provider_active"))
    }

    // MARK: Search

    /// Titles of the given accounts containing the query, in catalog order, each with its source
    /// identity. Reads only active snapshots, so a title being replaced never appears twice.
    func providerSearch(_ sources: [UnifiedProviderSource], kind: XtreamVODKind?, query: String,
                        limit: Int = 50) -> [UnifiedProviderSearchHit] {
        let needle = UnifiedCatalogKeys.normalizedTitle(query, year: nil)
        let filter = Self.providerSourceFilter(sources, alias: "p")
        guard !needle.isEmpty, let filter else { return [] }
        let kindClause = kind == nil ? "" : " AND p.kind=?3"
        guard let statement = try? prepare("""
            SELECT p.account, p.library, p.content_id, p.kind, p.title, p.year, p.poster, p.payload,
                   p.sort_key, p.match_key, p.entry_key
            FROM unified_provider_items p JOIN unified_provider_active a
              ON a.account=p.account AND a.library=p.library AND a.kind=p.kind AND a.snapshot=p.snapshot
            WHERE instr(p.sort_key, ?1) > 0 AND (\(filter))\(kindClause)
            ORDER BY p.sort_key, p.match_key, p.entry_key LIMIT ?2
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(needle, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(min(max(limit, 1), 200)))
        if let kind { bind(kind.rawValue, at: 3, in: statement) }
        func text(_ index: Int32) -> String? { sqlite3_column_text(statement, index).map { String(cString: $0) } }
        var hits: [UnifiedProviderSearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let account = text(0), let library = text(1), let content = text(2),
                  let hitKind = text(3).flatMap(XtreamVODKind.init(rawValue:)) else { continue }
            let bytes = sqlite3_column_blob(statement, 7)
            let payload = bytes.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 7))) } ?? Data()
            let year = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 5))
            let cursor = UnifiedIndexCursor(sortKey: text(8) ?? "", matchKey: text(9) ?? "", entryKey: text(10) ?? "")
            hits.append(.init(
                kind: hitKind,
                row: .init(cursor: cursor, title: text(4) ?? "Untitled", year: year, poster: text(6),
                           source: .provider(account: account, library: library, contentID: content, payload: payload))))
        }
        return hits
    }

    /// `(p.account='a' AND p.library IN ('x','y')) OR …` for the sources that can show anything,
    /// or nil when none can. Text is quoted with doubled quotes; it is data, never SQL.
    static func providerSourceFilter(_ sources: [UnifiedProviderSource], alias: String) -> String? {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        let clauses: [String] = sources.compactMap { source in
            guard let libraries = source.libraries else { return "\(alias).account=\(quote(source.account))" }
            guard !libraries.isEmpty else { return nil }
            return "(\(alias).account=\(quote(source.account)) AND \(alias).library IN (\(libraries.map(quote).joined(separator: ","))))"
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " OR ")
    }
}

/// A search result from a provider account, with the kind the grid it belongs to.
struct UnifiedProviderSearchHit: Sendable, Equatable {
    let kind: XtreamVODKind
    let row: UnifiedIndexRow
}

// MARK: - Sync

struct UnifiedProviderSyncPage<Cursor> {
    let records: [UnifiedProviderRecord]
    let next: Cursor?
    /// The provider rejected the previous cursor and this is a fresh first page.
    let startsOver: Bool
}

enum UnifiedProviderSyncEngine {
    /// Walks one library of one account into a private snapshot and publishes it only when the walk
    /// finished for an account that is still current. The same lifecycle as the Silo walk: the
    /// previous snapshot stays visible and is replaced in one transaction; a library with nothing
    /// published yet shows its first pages while it walks, stamped `.distantPast` so they count
    /// as stale.
    static func sync<Cursor>(
        store: XtreamVODCatalogStore, account: String, library: String, kind: XtreamVODKind,
        freshness: TimeInterval?, now: @Sendable () -> Date = { Date() },
        isCurrent: @Sendable () async -> Bool,
        onProgress: @Sendable () async -> Void = {},
        first: @Sendable () async throws -> UnifiedProviderSyncPage<Cursor>,
        next: @Sendable (Cursor) async throws -> UnifiedProviderSyncPage<Cursor>
    ) async -> UnifiedSiloSyncOutcome {
        let previous = await store.providerSyncedAt(account: account, library: library, kind: kind)
        if let freshness, let previous, now().timeIntervalSince(previous) < freshness { return .skippedFresh }
        let progressive = previous == nil
        var snapshot = UUID().uuidString
        var seen = Set<String>()
        var restarts = 0
        var pages = 0
        func discard() async {
            await store.discardProvider(account: account, library: library, kind: kind, snapshot: snapshot)
        }
        func retract() async {
            if progressive { try? await store.retractProvider(account: account, library: library, kind: kind) }
            else { await discard() }
        }
        do {
            var page = try await first()
            while true {
                if Task.isCancelled { await discard(); return .cancelled }
                guard await isCurrent() else { await retract(); return .identityChanged }
                if page.startsOver {
                    await discard()
                    restarts += 1
                    guard restarts <= UnifiedSiloSyncEngine.maximumRestarts else { return .failed }
                    snapshot = UUID().uuidString
                    seen.removeAll()
                    pages = 0
                }
                let fresh = page.records.filter { seen.insert($0.contentID).inserted }
                try await store.stageProvider(fresh, account: account, library: library, kind: kind, snapshot: snapshot)
                pages += 1
                if progressive, UnifiedSiloSyncEngine.publishesProgress(afterPage: pages), page.next != nil {
                    try await store.promoteProvider(account: account, library: library, kind: kind, snapshot: snapshot,
                                                    itemCount: seen.count, syncedAt: .distantPast)
                    await onProgress()
                }
                guard let cursor = page.next else { break }
                guard pages < UnifiedSiloSyncEngine.maximumPages else { await discard(); return .failed }
                page = try await next(cursor)
            }
            if Task.isCancelled { await discard(); return .cancelled }
            guard await isCurrent() else { await retract(); return .identityChanged }
            try await store.promoteProvider(account: account, library: library, kind: kind, snapshot: snapshot,
                                            itemCount: seen.count, syncedAt: now())
            return .synced(count: seen.count)
        } catch {
            await discard()
            return error is CancellationError ? .cancelled : .failed
        }
    }

    /// Syncs every library an account lists for one kind. A failure keeps the last snapshot of
    /// every library; an account whose library list cannot be read is left exactly as it was.
    /// Returns whether any part failed.
    static func syncAccount(
        store: XtreamVODCatalogStore, account: String, kind: XtreamVODKind, freshness: TimeInterval?,
        isCurrent: @Sendable () async -> Bool, onProgress: @Sendable () async -> Void = {},
        libraries: @Sendable () async throws -> [String],
        first: @Sendable (String) async throws -> UnifiedProviderSyncPage<String>,
        next: @Sendable (String, String) async throws -> UnifiedProviderSyncPage<String>
    ) async -> Bool {
        let listed: [String]
        do { listed = try await libraries() } catch { return true }
        var failed = false
        for library in listed {
            if Task.isCancelled { return failed }
            let outcome = await sync(
                store: store, account: account, library: library, kind: kind, freshness: freshness,
                isCurrent: isCurrent, onProgress: onProgress,
                first: { try await first(library) }, next: { try await next(library, $0) })
            switch outcome {
            case .failed: failed = true
            case .cancelled, .identityChanged: return failed
            case .synced, .skippedFresh: break
            }
        }
        // An empty list is a transient answer, not a revocation, exactly as for Silo libraries.
        if !listed.isEmpty, !Task.isCancelled {
            try? await store.retainProviderLibraries(account: account, kind: kind, libraries: listed)
        }
        return failed
    }
}
#endif

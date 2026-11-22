import Foundation
import CSQLite

public enum SQLiteStoreError: Error, Sendable { case open(String), execute(String), closed, migrationRegression }
public actor SQLiteWriter {
    private var db: OpaquePointer?
    public init(location: StorageLocation) throws {
        try FileManager.default.createDirectory(at: location.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(location.url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw SQLiteStoreError.open("Could not open database") }
        try Self.exec(db, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS kyro_schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);")
    }
    public func close() { if let db { sqlite3_close(db); self.db = nil } }
    public func execute(_ sql: String) throws { guard let db else { throw SQLiteStoreError.closed }; try Self.exec(db, sql) }
    public func migrate(to version: Int, statements: [String]) throws {
        guard let db else { throw SQLiteStoreError.closed }
        var current: Int32 = 0
        if sqlite3_exec(db, "SELECT 1", nil, nil, nil) != SQLITE_OK { throw SQLiteStoreError.execute("Database unavailable") }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(version),0) FROM kyro_schema_migrations", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW { current = sqlite3_column_int(stmt, 0) }
        sqlite3_finalize(stmt)
        guard Int32(version) >= current else { throw SQLiteStoreError.migrationRegression }
        for (offset, sql) in statements.enumerated() where current + Int32(offset) < Int32(version) {
            try Self.exec(db, "BEGIN IMMEDIATE;\n\(sql);\nINSERT INTO kyro_schema_migrations(version,applied_at) VALUES(\(current + Int32(offset) + 1),CAST(strftime('%s','now') AS INTEGER));\nCOMMIT;")
        }
    }
    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let reason = message.map { String(cString: $0) } ?? "SQLite error"; sqlite3_free(message)
            throw SQLiteStoreError.execute(Redactor.redact(reason))
        }
    }
}

public actor SQLiteReaderPool {
    private let locations: [StorageLocation]
    private var available: [OpaquePointer] = []
    public init(location: StorageLocation, capacity: Int = 3) throws {
        let count = max(1, capacity); locations = Array(repeating: location, count: count)
        for _ in 0..<count {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(location.url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else { throw SQLiteStoreError.open("Could not open reader") }
            sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil); available.append(handle)
        }
    }
    public func close() { available.forEach { sqlite3_close($0) }; available.removeAll() }
    public var readerCount: Int { locations.count }
    public func scalarInt(_ sql: String) throws -> Int64 {
        guard !available.isEmpty else { throw SQLiteStoreError.closed }
        let db = available.removeFirst(); defer { available.append(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLiteStoreError.execute("Invalid query") }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw SQLiteStoreError.execute("Query returned no row") }
        return sqlite3_column_int64(stmt, 0)
    }
}

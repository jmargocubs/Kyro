import Foundation
import CSQLite

public enum SQLiteStoreError: Error, Sendable { case open(String), execute(String), closed, migrationRegression }
public enum SQLiteValue: Sendable, Equatable { case integer(Int64), real(Double), text(String), blob(Data), null }
public actor SQLiteWriter {
    private var db: OpaquePointer?
    public init(location: StorageLocation) throws {
        try FileManager.default.createDirectory(at: location.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(location.url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw SQLiteStoreError.open("Could not open database") }
        try Self.exec(db, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS kyro_schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);")
    }
    public func close() { if let db { sqlite3_close(db); self.db = nil } }
    public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int32 {
        guard let db else { throw SQLiteStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SQLiteStoreError.execute("Could not prepare statement") }
        defer { sqlite3_finalize(statement) }
        try Self.bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(db) }
        return sqlite3_changes(db)
    }
    public func transaction(_ statements: [(String, [SQLiteValue])]) throws {
        guard let db else { throw SQLiteStoreError.closed }
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            for (sql, values) in statements { _ = try execute(sql, bindings: values) }
            try Self.exec(db, "COMMIT")
        } catch { try? Self.exec(db, "ROLLBACK"); throw error }
    }
    public func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        guard let db else { throw SQLiteStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SQLiteStoreError.execute("Could not prepare query") }
        defer { sqlite3_finalize(statement) }
        try Self.bind(bindings, to: statement)
        var rows = [[String: SQLiteValue]]()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Self.error(db) }
            var row = [String: SQLiteValue]()
            for index in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[key] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: row[key] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB: row[key] = .blob(Data(bytes: sqlite3_column_blob(statement, index), count: Int(sqlite3_column_bytes(statement, index))))
                default: row[key] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
    public func schemaVersion() throws -> Int {
        guard let row = try query("SELECT COALESCE(MAX(version),0) AS version FROM kyro_schema_migrations").first, case let .integer(value)? = row["version"] else { return 0 }
        return Int(value)
    }
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
    fileprivate static func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1); let status: Int32
            switch value {
            case .integer(let value): status = sqlite3_bind_int64(statement, index, value)
            case .real(let value): status = sqlite3_bind_double(statement, index, value)
            case .text(let value): status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .blob(let value): status = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw SQLiteStoreError.execute("Could not bind query value") }
        }
    }
    private static func error(_ db: OpaquePointer) -> SQLiteStoreError { .execute(Redactor.redact(String(cString: sqlite3_errmsg(db)))) }
}

public actor SQLiteReaderPool {
    private var available: [OpaquePointer] = []
    public init(location: StorageLocation, capacity: Int = 3) throws {
        let count = max(1, capacity)
        for _ in 0..<count {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(location.url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else { throw SQLiteStoreError.open("Could not open reader") }
            sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil); available.append(handle)
        }
    }
    public func close() { available.forEach { sqlite3_close($0) }; available.removeAll() }
    public var readerCount: Int { available.count }
    public func scalarInt(_ sql: String) throws -> Int64 {
        guard !available.isEmpty else { throw SQLiteStoreError.closed }
        let db = available.removeFirst(); defer { available.append(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLiteStoreError.execute("Invalid query") }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw SQLiteStoreError.execute("Query returned no row") }
        return sqlite3_column_int64(stmt, 0)
    }
    public func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        guard !available.isEmpty else { throw SQLiteStoreError.closed }
        let db = available.removeFirst(); defer { available.append(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SQLiteStoreError.execute("Invalid query") }
        defer { sqlite3_finalize(statement) }
        try SQLiteWriter.bind(bindings, to: statement)
        var rows = [[String: SQLiteValue]]()
        while true {
            let result = sqlite3_step(statement); if result == SQLITE_DONE { break }; guard result == SQLITE_ROW else { throw SQLiteStoreError.execute("Query failed") }
            var row = [String: SQLiteValue]()
            for index in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[key] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: row[key] = .text(String(cString: sqlite3_column_text(statement, index)))
                default: row[key] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
}

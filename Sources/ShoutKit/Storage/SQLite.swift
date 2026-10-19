import Foundation
import SQLite3

/// Minimal thread-safe SQLite wrapper (no third-party dependencies).
public final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public enum Value: Equatable {
        case null, int(Int64), double(Double), text(String)
        public var string: String? { if case .text(let s) = self { return s }; return nil }
        public var int: Int64? {
            switch self { case .int(let i): return i; case .double(let d): return Int64(d); default: return nil }
        }
        public var double: Double? {
            switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
        }
    }
    public typealias Row = [String: Value]

    public struct DBError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public init(path: String) throws {
        // A failed open still allocates the handle (with the reason); `deinit` closes it.
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw DBError(message: "Cannot open database at \(path): \(db == nil ? "out of memory" : lastError)")
        }
        // The busy timeout first, so switching to WAL waits for another connection's lock instead of failing.
        try exec("PRAGMA busy_timeout=3000; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close(db) }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DBError(message: msg)
        }
    }

    /// Throws when a value can't be bound (too many parameters, out of memory): the statement must not run
    /// with that parameter left NULL.
    private func bind(_ stmt: OpaquePointer?, _ params: [Any?]) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case nil: rc = sqlite3_bind_null(stmt, idx)
            case let v as Int: rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: rc = sqlite3_bind_int64(stmt, idx, v)
            case let v as Int32: rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Bool: rc = sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: rc = sqlite3_bind_double(stmt, idx, v)
            case let v as Float: rc = sqlite3_bind_double(stmt, idx, Double(v))
            case let v as Date: rc = sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            case let v as String: rc = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            default: rc = sqlite3_bind_text(stmt, idx, "\(p!)", -1, Self.transient)
            }
            guard rc == SQLITE_OK else { throw DBError(message: "parameter \(idx): \(lastError)") }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: Any?...) throws -> Int64 {
        try run(sql, params: params)
    }

    @discardableResult
    public func run(_ sql: String, params: [Any?]) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError(message: lastError) }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError(message: lastError) }
        return sqlite3_last_insert_rowid(db)
    }

    /// Runs an UPDATE or DELETE and returns how many rows it changed (for compare-and-set writes).
    @discardableResult
    public func update(_ sql: String, _ params: Any?...) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try run(sql, params: params)
        return Int(sqlite3_changes(db))
    }

    public func query(_ sql: String, _ params: Any?...) throws -> [Row] {
        try query(sql, params: params)
    }

    public func query(_ sql: String, params: [Any?]) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError(message: lastError) }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        var rows: [Row] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            var row: Row = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                row[String(cString: sqlite3_column_name(stmt, c))] = Self.value(stmt, c)
            }
            rows.append(row)
            rc = sqlite3_step(stmt)
        }
        // An error part-way (busy, I/O) must not pass for a shorter result.
        guard rc == SQLITE_DONE else { throw DBError(message: lastError) }
        return rows
    }

    private static func value(_ stmt: OpaquePointer?, _ c: Int32) -> Value {
        switch sqlite3_column_type(stmt, c) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(stmt, c))
        case SQLITE_FLOAT: .double(sqlite3_column_double(stmt, c))
        case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(stmt, c)))
        default: .null
        }
    }

    /// The first column of the first row (`.null` when there is no row).
    public func scalar(_ sql: String, _ params: Any?...) throws -> Value {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError(message: lastError) }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return .null }
        guard rc == SQLITE_ROW, sqlite3_column_count(stmt) > 0 else { throw DBError(message: lastError) }
        return Self.value(stmt, 0)
    }

    /// Runs `body` atomically. IMMEDIATE takes the write lock up front (waiting up to the busy timeout), so a
    /// transaction that reads before it writes cannot fail half-way on another connection's lock.
    public func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    /// Throws when it can't be read, so a failed read never passes for a new database.
    public var userVersion: Int {
        get throws { Int(try scalar("PRAGMA user_version").int ?? 0) }
    }

    /// Transactional: inside `transaction` it is rolled back with everything else.
    public func setUserVersion(_ version: Int) throws {
        try exec("PRAGMA user_version = \(version)")
    }
}

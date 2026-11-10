// Minimal SQLite wrapper (ichiran uses PostgreSQL through postmodern; BunsetsuKit uses SQLite).

import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

enum SQLValue: Hashable {
    case null
    case int(Int)
    case real(Double)
    case text(String)

    var int: Int? {
        switch self {
        case .int(let i): return i
        case .real(let d): return Int(d)
        default: return nil
        }
    }

    var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    var bool: Bool? {
        switch self {
        case .int(let i): return i != 0
        default: return nil
        }
    }

    var isNull: Bool { self == .null }
}

protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { var sqlValue: SQLValue { .int(self) } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

typealias Row = [SQLValue]

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDB {
    private(set) var handle: OpaquePointer?
    private var statementCache: [String: OpaquePointer] = [:]
    let path: String
    let readOnly: Bool

    init(path: String, readOnly: Bool = false, create: Bool = false) throws {
        self.path = path
        self.readOnly = readOnly
        var flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        if create { flags |= SQLITE_OPEN_CREATE }
        flags |= SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            handle = nil
            throw DatabaseError(message: "Cannot open database at \(path): \(msg)")
        }
        if readOnly {
            // read pages straight from the file mapping instead of copying them into the page cache
            sqlite3_exec(handle, "PRAGMA mmap_size = 268435456", nil, nil, nil)
        }
    }

    deinit {
        for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
        sqlite3_close(handle)
    }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>? = nil
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            fatalError("SQL error: \(msg) in \(sql)")
        }
    }

    private func statement(_ sql: String) -> OpaquePointer {
        if let s = statementCache[sql] {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            return s
        }
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            fatalError("SQL prepare error: \(errorMessage) in \(sql)")
        }
        // statements with dynamic IN lists are not worth caching forever
        if statementCache.count < 4000 { statementCache[sql] = stmt }
        return stmt
    }

    private func release(_ sql: String, _ stmt: OpaquePointer) {
        if statementCache[sql] == nil {
            sqlite3_finalize(stmt)
        } else {
            sqlite3_reset(stmt)
        }
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLBindable]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p.sqlValue {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, Int64(v))
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            }
        }
    }

    private func column(_ stmt: OpaquePointer, _ i: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .int(Int(sqlite3_column_int64(stmt, i)))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, i)))
        default: return .null
        }
    }

    @discardableResult
    func query(_ sql: String, _ params: [SQLBindable] = []) -> [Row] {
        let stmt = statement(sql)
        defer { release(sql, stmt) }
        bind(stmt, params)
        var rows: [Row] = []
        let n = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var row = Row()
                row.reserveCapacity(Int(n))
                for i in 0..<n { row.append(column(stmt, i)) }
                rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                fatalError("SQL error: \(errorMessage) in \(sql)")
            }
        }
        return rows
    }

    /// Runs a statement and returns the number of changed rows.
    @discardableResult
    func run(_ sql: String, _ params: [SQLBindable] = []) -> Int {
        query(sql, params)
        return Int(sqlite3_changes(handle))
    }

    func column(_ sql: String, _ params: [SQLBindable] = []) -> [SQLValue] {
        query(sql, params).map { $0[0] }
    }

    func single(_ sql: String, _ params: [SQLBindable] = []) -> SQLValue {
        query(sql, params).first?.first ?? .null
    }

    var lastInsertRowID: Int { Int(sqlite3_last_insert_rowid(handle)) }

    func transaction<T>(_ body: () throws -> T) rethrows -> T {
        exec("BEGIN")
        do {
            let r = try body()
            exec("COMMIT")
            return r
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }
}

/// Builds "(?,?,?)" for an IN clause.
func placeholders(_ n: Int) -> String {
    "(" + Array(repeating: "?", count: max(n, 1)).joined(separator: ",") + ")"
}

/// Splits long IN lists to stay below SQLite's variable limit.
func chunked<T>(_ list: [T], size: Int = 900) -> [[T]] {
    stride(from: 0, to: list.count, by: size).map { Array(list[$0..<min($0 + size, list.count)]) }
}

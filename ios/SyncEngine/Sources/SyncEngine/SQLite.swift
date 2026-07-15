import Foundation
import SQLite3

/// Minimal SQLite wrapper — just enough for the mapping store. Not a general ORM.
public final class SQLiteDatabase {
    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public enum SQLiteError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, sql: String)
        case step(String, sql: String)

        public var description: String {
            switch self {
            case .open(let m): return "sqlite open: \(m)"
            case .prepare(let m, let sql): return "sqlite prepare: \(m) [\(sql)]"
            case .step(let m, let sql): return "sqlite step: \(m) [\(sql)]"
            }
        }
    }

    public init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw SQLiteError.open(msg)
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close(db)
    }

    public enum Value {
        case text(String)
        case int(Int64)
        case blob(Data)
        case null
    }

    public func exec(_ sql: String, _ params: [Value] = []) throws {
        _ = try query(sql, params)
    }

    @discardableResult
    public func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .blob(let d):
                d.withUnsafeBytes { buf in
                    _ = sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [[String: Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteError.step(String(cString: sqlite3_errmsg(db)), sql: sql)
            }
            var row: [String: Value] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT: row[name] = .int(Int64(sqlite3_column_double(stmt, col)))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, col)))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, col) {
                        row[name] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, col))))
                    } else {
                        row[name] = .blob(Data())
                    }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }
}

public extension SQLiteDatabase.Value {
    var stringValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }
    var intValue: Int64? {
        if case .int(let n) = self { return n }
        return nil
    }
    var blobValue: Data? {
        if case .blob(let d) = self { return d }
        return nil
    }
}

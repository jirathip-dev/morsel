import Foundation
import SQLite3

// Issue #106 — SQLite plumbing for the local Apple Health store (split to
// stay inside the strict lint budgets).

extension LocalHealthStore {
    // MARK: - SQLite helpers (this file owns its connection)

    func firstString(_ sql: String, _ binds: SQLiteValue...) throws -> String? {
        try query(sql, binds).first?.string("value")
    }

    func runUnsafe(_ sql: String, _ binds: SQLiteValue...) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in binds.enumerated() {
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, Int32(index + 1))
            case let .text(text):
                result = sqlite3_bind_text(statement, Int32(index + 1), text, -1, Self.transient)
            case let .int(number):
                result = sqlite3_bind_int64(statement, Int32(index + 1), number)
            case let .double(number):
                result = sqlite3_bind_double(statement, Int32(index + 1), number)
            case let .blob(data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement, Int32(index + 1), bytes.baseAddress,
                        Int32(data.count), Self.transient
                    )
                }
            }
            guard result == SQLITE_OK else {
                throw LocalStoreError.sqlite(lastErrorMessage)
            }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            if step == SQLITE_ROW { continue }
            throw LocalStoreError.sqlite(lastErrorMessage)
        }
    }

    func query(_ sql: String, _ binds: [SQLiteValue]) throws -> [HealthRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in binds.enumerated() {
            guard bindValue(statement, value, at: index + 1) == SQLITE_OK else {
                throw LocalStoreError.sqlite(lastErrorMessage)
            }
        }
        var rows: [HealthRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                var row = HealthRow()
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    row.storage[name] = columnValue(statement, column: index)
                }
                rows.append(row)
            } else if step == SQLITE_DONE {
                break
            } else {
                throw LocalStoreError.sqlite(lastErrorMessage)
            }
        }
        return rows
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let prepared = statement else {
            throw LocalStoreError.sqlite(lastErrorMessage)
        }
        return prepared
    }

    func bindValue(_ statement: OpaquePointer, _ value: SQLiteValue, at index: Int) -> Int32 {
        switch value {
        case .null:
            return sqlite3_bind_null(statement, Int32(index))
        case let .text(text):
            return sqlite3_bind_text(statement, Int32(index), text, -1, Self.transient)
        case let .int(number):
            return sqlite3_bind_int64(statement, Int32(index), number)
        case let .double(number):
            return sqlite3_bind_double(statement, Int32(index), number)
        case let .blob(data):
            return data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement, Int32(index), bytes.baseAddress,
                    Int32(data.count), Self.transient
                )
            }
        }
    }

    func columnValue(_ statement: OpaquePointer, column: Int32) -> HealthValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, column) else { return .null }
            return .text(String(cString: text))
        default:
            return .null
        }
    }

    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(database))
    }

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func dayKey(_ day: Date) -> String {
        String(day.timeIntervalSince1970)
    }

    static func date(dayKey: String) -> Date? {
        TimeInterval(dayKey).map(Date.init(timeIntervalSince1970:))
    }
}

import Foundation
import SQLite3

// Issue #106 — SQLite plumbing for the account-scoped data store (kept out
// of the store's own file so shipped files stay inside lint budgets).

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension LocalDataStore {
    func run(_ sql: String, _ binds: SQLiteValue...) throws {
        try run(sql, binds)
    }
    func run(_ sql: String, _ binds: [SQLiteValue]) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, binds)
        try drain(statement)
    }

    func inTransaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try runUnsafe("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try runUnsafe("COMMIT")
        } catch {
            try? runUnsafe("ROLLBACK")
            throw error
        }
    }

    func query(_ sql: String, _ binds: SQLiteValue...) throws -> [[String: SQLiteValue]] {
        try query(sql, binds)
    }
    func query(_ sql: String, _ binds: [SQLiteValue]) throws -> [[String: SQLiteValue]] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, binds)
        var rows: [[String: SQLiteValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                let count = sqlite3_column_count(statement)
                var row: [String: SQLiteValue] = [:]
                for index in 0..<count {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    row[name] = value(statement, column: index)
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

    func bind(_ statement: OpaquePointer, _ binds: [SQLiteValue]) throws {
        for (index, value) in binds.enumerated() {
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, Int32(index + 1))
            case let .text(text):
                result = sqlite3_bind_text(statement, Int32(index + 1), text, -1, sqliteTransient)
            case let .int(number):
                result = sqlite3_bind_int64(statement, Int32(index + 1), number)
            case let .double(number):
                result = sqlite3_bind_double(statement, Int32(index + 1), number)
            case let .blob(data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement, Int32(index + 1), bytes.baseAddress,
                        Int32(data.count), sqliteTransient
                    )
                }
            }
            guard result == SQLITE_OK else {
                throw LocalStoreError.sqlite(lastErrorMessage)
            }
        }
    }

    func value(_ statement: OpaquePointer, column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, column))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, column) else { return .null }
            let count = Int(sqlite3_column_bytes(statement, column))
            return .blob(Data(bytes: bytes, count: count))
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

    func drain(_ statement: OpaquePointer) throws {
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            if step == SQLITE_ROW { continue }
            throw LocalStoreError.sqlite(lastErrorMessage)
        }
    }

    func runUnsafe(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try drain(statement)
    }

    static func row(_ values: [String: SQLiteValue]) throws -> QueuedMeal {
        let string = { (key: String) -> String? in
            if case let .text(value)? = values[key] { return value }
            return nil
        }
        let number = { (key: String) -> Double? in
            if case let .double(value)? = values[key] { return value }
            if case let .int(value)? = values[key] { return Double(value) }
            return nil
        }
        guard let idText = string("local_meal_id"), let mealID = UUID(uuidString: idText),
              let mealTypeRaw = string("meal_type"), let mealType = MealType(rawValue: mealTypeRaw),
              let sourceRaw = string("source"), let source = MealSource(rawValue: sourceRaw),
              let stateRaw = string("state"), let state = MealOutboxState(rawValue: stateRaw),
              let eatenAt = number("eaten_at"), let itemsJSON = string("items_json"),
              let createdAt = number("created_at"), let updatedAt = number("updated_at") else {
            throw LocalStoreError.sqlite("malformed outbox row")
        }
        let category = string("last_error_category").flatMap(OutboxErrorCategory.init(rawValue:))
        return QueuedMeal(
            mealID: mealID,
            mealType: mealType,
            eatenAt: Date(timeIntervalSince1970: eatenAt),
            source: source,
            notes: string("notes"),
            items: try Self.items(fromJSON: itemsJSON),
            photo: {
                if case let .blob(data)? = values["photo_data"],
                   let mimeType = string("photo_mime") {
                    return QueuedMealPhoto(data: data, mimeType: mimeType)
                }
                return nil
            }(),
            state: state,
            attempts: Int(number("attempts") ?? 0),
            lastError: string("last_error"),
            lastErrorCategory: category,
            imagePath: string("image_path"),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    static func itemsJSON(_ items: [QueuedMealItem]) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(items) else { return "[]" }
        return text(data)
    }

    static func items(fromJSON json: String) throws -> [QueuedMealItem] {
        let decoder = JSONDecoder()
        guard let data = json.data(using: .utf8),
              let items = try? decoder.decode([QueuedMealItem].self, from: data) else {
            throw LocalStoreError.sqlite("malformed outbox items")
        }
        return items
    }

    static func text(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? ""
    }

    static func data(_ text: String) -> Data? {
        text.data(using: .utf8)
    }
}

import Foundation
import SQLite3

// Issue #106 — account-scoped snapshot cache (Today / History / Goals JSON
// payloads). The cache is written through on every successful remote read
// and served on remote failure so a network/RPC blip never erases the last
// valid snapshot. Lives in the SAME per-account database file as the meal
// outbox (WAL allows multiple connections); isolation by account file.
final class LocalSnapshotCache {
    private let database: OpaquePointer
    private let lock = NSRecursiveLock()
    /// Issue #183 — publication generations: one counter per account+resource+day/range
    /// scope plus one invalidation epoch per account (see the extension at the end).
    private var publicationGenerations: [String: Int] = [:]
    private var publicationInvalidations: [UUID: Int] = [:]
    /// Teardowns clear the whole file, so they supersede every account's reads.
    private var publicationTeardowns = 0

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw LocalStoreError.sqlite(message)
        }
        database = opened
        sqlite3_busy_timeout(database, 2_000)
        do {
            try runUnsafe("PRAGMA journal_mode = WAL")
            try runUnsafe("""
            CREATE TABLE IF NOT EXISTS dashboard_cache(
              day_key TEXT PRIMARY KEY,
              payload TEXT NOT NULL,
              saved_at REAL NOT NULL
            )
            """)
            try runUnsafe("""
            CREATE TABLE IF NOT EXISTS history_cache(
              cache_key TEXT PRIMARY KEY,
              payload TEXT NOT NULL,
              saved_at REAL NOT NULL
            )
            """)
            try runUnsafe("""
            CREATE TABLE IF NOT EXISTS goals_cache(
              user_key TEXT PRIMARY KEY,
              payload TEXT NOT NULL,
              saved_at REAL NOT NULL
            )
            """)
            try runUnsafe("""
            CREATE TABLE IF NOT EXISTS menus_cache(
              user_key TEXT PRIMARY KEY,
              payload TEXT NOT NULL,
              saved_at REAL NOT NULL
            )
            """)
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    // MARK: - Reads

    func loadDashboardCache(dayKey: String) throws -> Data? {
        try firstColumn("SELECT payload FROM dashboard_cache WHERE day_key = ?", .text(dayKey))
            .flatMap { $0.data(using: .utf8) }
    }

    func loadHistoryCache(cacheKey: String) throws -> Data? {
        try firstColumn("SELECT payload FROM history_cache WHERE cache_key = ?", .text(cacheKey))
            .flatMap { $0.data(using: .utf8) }
    }

    func saveGoalsCache(userKey: String, payload: Data, savedAt: Date = Date()) throws {
        try run("""
        INSERT INTO goals_cache(user_key, payload, saved_at) VALUES (?, ?, ?)
        ON CONFLICT(user_key) DO UPDATE SET payload = excluded.payload, saved_at = excluded.saved_at
        """, .text(userKey), .text(Self.text(payload)), .double(savedAt.timeIntervalSince1970))
    }

    func loadGoalsCache(userKey: String) throws -> Data? {
        try firstColumn("SELECT payload FROM goals_cache WHERE user_key = ?", .text(userKey))
            .flatMap { $0.data(using: .utf8) }
    }

    func clearAccountData() throws {
        // Issue #183 — teardown supersedes every read already in flight.
        lock.lock()
        publicationTeardowns += 1
        lock.unlock()
        try run("DELETE FROM dashboard_cache")
        try run("DELETE FROM history_cache")
        try run("DELETE FROM goals_cache")
        try run("DELETE FROM menus_cache")
    }

    // MARK: - Issue #121 one-time local-day re-bucket support

    /// One cached day-keyed row (dashboard or history cache).
    struct DayKeyedCacheRow: Equatable {
        let key: String
        let payload: Data
        let savedAt: Date
    }

    func allDashboardCacheRows() throws -> [DayKeyedCacheRow] {
        try allDayKeyedRows("dashboard_cache", keyColumn: "day_key")
    }

    func allHistoryCacheRows() throws -> [DayKeyedCacheRow] {
        try allDayKeyedRows("history_cache", keyColumn: "cache_key")
    }

    func removeDashboardCache(dayKey: String) throws {
        try run("DELETE FROM dashboard_cache WHERE day_key = ?", .text(dayKey))
    }

    func removeHistoryCache(cacheKey: String) throws {
        try run("DELETE FROM history_cache WHERE cache_key = ?", .text(cacheKey))
    }

    private func allDayKeyedRows(_ table: String, keyColumn: String) throws -> [DayKeyedCacheRow] {
        try select(
            "SELECT \(keyColumn), payload, saved_at FROM \(table) ORDER BY saved_at ASC", []
        ).compactMap { values in
            guard let key = textValue(values[keyColumn]),
                  let savedAt = doubleValue(values["saved_at"]) else {
                return nil
            }
            let payload = textValue(values["payload"]).flatMap { $0.data(using: .utf8) } ?? Data()
            return DayKeyedCacheRow(key: key, payload: payload, savedAt: Date(timeIntervalSince1970: savedAt))
        }
    }

    private func textValue(_ value: SQLiteValue?) -> String? {
        if case let .text(text)? = value { return text }
        return nil
    }

    private func doubleValue(_ value: SQLiteValue?) -> Double? {
        if case let .double(number)? = value { return number }
        if case let .int(number)? = value { return Double(number) }
        return nil
    }

    // MARK: - SQLite helpers

    private func run(_ sql: String, _ binds: SQLiteValue...) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, binds)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            if step == SQLITE_ROW { continue }
            throw LocalStoreError.sqlite(lastErrorMessage)
        }
    }

    private func runUnsafe(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            if step == SQLITE_ROW { continue }
            throw LocalStoreError.sqlite(lastErrorMessage)
        }
    }

    private func firstColumn(_ sql: String, _ binds: SQLiteValue...) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, binds)
        let step = sqlite3_step(statement)
        if step == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
        if step == SQLITE_DONE { return nil }
        throw LocalStoreError.sqlite(lastErrorMessage)
    }

    /// Multi-column select for the cache-migration enumeration.
    private func select(_ sql: String, _ binds: [SQLiteValue]) throws -> [[String: SQLiteValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, binds)
        var rows: [[String: SQLiteValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                var row: [String: SQLiteValue] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    row[name] = columnValue(statement, column: index)
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

    private func columnValue(_ statement: OpaquePointer, column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, column) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, column) else { return .null }
            let count = Int(sqlite3_column_bytes(statement, column))
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let prepared = statement else {
            throw LocalStoreError.sqlite(lastErrorMessage)
        }
        return prepared
    }

    private func bind(_ statement: OpaquePointer, _ binds: [SQLiteValue]) throws {
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
    }

    private var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(database))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? ""
    }
}

// Issue #152 — named-menu snapshot cache (same-file extension keeps the
// LocalSnapshotCache type body inside the lint budget).
extension LocalSnapshotCache {
    func saveMenusCache(userKey: String, payload: Data, savedAt: Date = Date()) throws {
        let encoded = String(bytes: payload, encoding: .utf8) ?? ""
        try run(
            """
            INSERT INTO menus_cache(user_key, payload, saved_at) VALUES (?, ?, ?)
            ON CONFLICT(user_key) DO UPDATE SET payload = excluded.payload, saved_at = excluded.saved_at
            """,
            .text(userKey), .text(encoded), .double(savedAt.timeIntervalSince1970)
        )
    }

    func loadMenusCache(userKey: String) throws -> Data? {
        try firstColumn("SELECT payload FROM menus_cache WHERE user_key = ?", .text(userKey))
            .flatMap { $0.data(using: .utf8) }
    }
}

// Issue #183 — generation-scoped publication: a read's write-through lands
// only while that read is the newest for its own account + resource +
// day-or-range scope and no write has invalidated the account. Ordering is a
// monotone generation, never a comparison of `saved_at` values.
extension LocalSnapshotCache {
    /// One read's claim on one cache scope.
    struct Publication: Hashable {
        let account: UUID
        let scope: String
        let generation: Int
        let invalidation: Int
    }

    /// Begins a read for `scope` (resource + day/range key) and returns the token
    /// it must publish with; every later `begin` for the same scope supersedes it.
    func beginPublication(account: UUID, scope: String) -> Publication {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.publicationKey(account: account, scope: scope)
        let generation = (publicationGenerations[key] ?? 0) + 1
        publicationGenerations[key] = generation
        return Publication(
            account: account, scope: scope, generation: generation,
            invalidation: (publicationInvalidations[account] ?? 0) + publicationTeardowns
        )
    }

    /// True while no newer same-scope read and no invalidation superseded it.
    func isPublicationCurrent(_ publication: Publication) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allows(publication)
    }

    /// Mutation: every read in flight for the account now predates a write.
    func invalidatePublications(account: UUID) {
        lock.lock()
        defer { lock.unlock() }
        publicationInvalidations[account, default: 0] += 1
    }

    /// The generation-scoped write-through: it lands only while `publication` still
    /// owns its scope (`nil` = unconditional); refusing is not an error here.
    @discardableResult
    func saveDashboardCache(
        dayKey: String, payload: Data, savedAt: Date = Date(), publication: Publication? = nil
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard allows(publication) else { return false }
        try run("""
        INSERT INTO dashboard_cache(day_key, payload, saved_at) VALUES (?, ?, ?)
        ON CONFLICT(day_key) DO UPDATE SET payload = excluded.payload, saved_at = excluded.saved_at
        """, .text(dayKey), .text(Self.text(payload)), .double(savedAt.timeIntervalSince1970))
        return true
    }

    @discardableResult
    func saveHistoryCache(
        cacheKey: String, payload: Data, savedAt: Date = Date(), publication: Publication? = nil
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard allows(publication) else { return false }
        try run("""
        INSERT INTO history_cache(cache_key, payload, saved_at) VALUES (?, ?, ?)
        ON CONFLICT(cache_key) DO UPDATE SET payload = excluded.payload, saved_at = excluded.saved_at
        """, .text(cacheKey), .text(Self.text(payload)), .double(savedAt.timeIntervalSince1970))
        return true
    }

    private static func publicationKey(account: UUID, scope: String) -> String {
        "\(account.uuidString)/\(scope)"
    }

    /// `nil` is the unconditional write: no read owns it.
    private func allows(_ publication: Publication?) -> Bool {
        guard let publication else { return true }
        let key = Self.publicationKey(account: publication.account, scope: publication.scope)
        let current = (publicationInvalidations[publication.account] ?? 0) + publicationTeardowns
        return publicationGenerations[key] == publication.generation && current == publication.invalidation
    }
}

/// Issue #183 — a read graph that can be told that a write landed: every read
/// already in flight for that account is superseded. `TodayRefreshOwner` calls
/// this when a write invalidates the pass it is showing; read graphs that never
/// publish to the snapshot cache do not implement it.
protocol ReadPublicationFencing {
    func invalidateReadPublications(userID: UUID)
}

extension LocalFirstDashboardRepository: ReadPublicationFencing {
    func invalidateReadPublications(userID: UUID) {
        snapshotCache.invalidatePublications(account: userID)
    }
}

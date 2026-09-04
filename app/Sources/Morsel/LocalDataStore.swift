import Foundation
import SQLite3

// Issue #106 — account-scoped SQLite local store (system SQLite3; no new
// package). One database file per authenticated account — isolation by
// construction, cleared at logout. Cache + durable outbox only: RLS, the
// security-invoker meal transaction and friendly boundaries stay
// authoritative on the server. Tokens/secrets are NEVER written here.
enum LocalStoreError: LocalizedError, Equatable {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case let .sqlite(message):
            return "The local store could not be read. \\(message)"
        }
    }
}

/// Account-scoped SQLite access (cache + meal outbox), serialized.
final class LocalDataStore {
    let database: OpaquePointer
    let lock = NSRecursiveLock()

    static func storeDirectory(root: URL, accountID: UUID) -> URL {
        root.appendingPathComponent("Morsel", isDirectory: true)
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
    }

    static func storeURL(root: URL, accountID: UUID) -> URL {
        storeDirectory(root: root, accountID: accountID)
            .appendingPathComponent("data.sqlite")
    }

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
            try run("PRAGMA journal_mode = WAL")
            try createSchema()
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    // MARK: - Schema

    private func createSchema() throws {
        try run("""
        CREATE TABLE IF NOT EXISTS meal_outbox(
          local_meal_id TEXT PRIMARY KEY,
          meal_type TEXT NOT NULL,
          eaten_at REAL NOT NULL,
          source TEXT NOT NULL,
          notes TEXT,
          items_json TEXT NOT NULL,
          photo_data BLOB,
          photo_mime TEXT,
          state TEXT NOT NULL DEFAULT 'pending',
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          last_error_category TEXT,
          image_path TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """)
        try run("CREATE INDEX IF NOT EXISTS meal_outbox_state_idx ON meal_outbox(state)")
        try run("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

// MARK: - Meal outbox

    /// Commits meal + items + photo payload in ONE local transaction.
    func enqueueMeal(_ meal: QueuedMeal) throws {
        try inTransaction {
            try run("""
            INSERT INTO meal_outbox(
              local_meal_id, meal_type, eaten_at, source, notes, items_json,
              photo_data, photo_mime, state, attempts, last_error,
              last_error_category, image_path, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            .text(meal.mealID.uuidString),
            .text(meal.mealType.rawValue),
            .double(meal.eatenAt.timeIntervalSince1970),
            .text(meal.source.rawValue),
            meal.notes.map { .text($0) } ?? .null,
            .text(Self.itemsJSON(meal.items)),
            meal.photo.map { .blob($0.data) } ?? .null,
            meal.photo.map { .text($0.mimeType) } ?? .null,
            .text(meal.state.rawValue),
            .int(Int64(meal.attempts)),
            meal.lastError.map { .text($0) } ?? .null,
            meal.lastErrorCategory.map { .text($0.rawValue) } ?? .null,
            meal.imagePath.map { .text($0) } ?? .null,
            .double(meal.createdAt.timeIntervalSince1970),
            .double(meal.updatedAt.timeIntervalSince1970))
        }
    }

    /// Queued rows (pending + needs-attention), oldest first.
    func queuedMeals() throws -> [QueuedMeal] {
        try query("""
        SELECT local_meal_id, meal_type, eaten_at, source, notes, items_json,
               photo_data, photo_mime, state, attempts, last_error,
               last_error_category, image_path, created_at, updated_at
        FROM meal_outbox ORDER BY created_at ASC
        """).map { try Self.row($0) }
    }

    func queuedMeal(mealID: UUID) throws -> QueuedMeal? {
        try query("""
        SELECT local_meal_id, meal_type, eaten_at, source, notes, items_json,
               photo_data, photo_mime, state, attempts, last_error,
               last_error_category, image_path, created_at, updated_at
        FROM meal_outbox WHERE local_meal_id = ?
        """, .text(mealID.uuidString)).first.map { try Self.row($0) }
    }

    /// Records an attempt; permanent refusals → needs-attention (kept).
    func recordMealAttempt(mealID: UUID, error: OutboxErrorCategory, now: Date = Date()) throws {
        let existing = try queuedMeal(mealID: mealID)
        let attempts = (existing?.attempts ?? 0) + 1
        let state: MealOutboxState = error == .auth || error == .validation ? .needsAttention : .pending
        let category = error.rawValue
        try inTransaction {
            try run("""
            UPDATE meal_outbox
            SET state = ?, attempts = ?, last_error = ?, last_error_category = ?,
                image_path = ?, updated_at = ?
            WHERE local_meal_id = ?
            """,
            .text(state.rawValue),
            .int(Int64(attempts)),
            .text(error.friendlyDescription),
            .text(category),
            existing?.imagePath.map { .text($0) } ?? .null,
            .double(now.timeIntervalSince1970),
            .text(mealID.uuidString))
        }
    }

    /// Retains or clears the uploaded photo path across retries.
    func updateMealImagePath(mealID: UUID, path: String?, now: Date = Date()) throws {
        try run("""
        UPDATE meal_outbox SET image_path = ?, updated_at = ? WHERE local_meal_id = ?
        """, path.map { .text($0) } ?? .null, .double(now.timeIntervalSince1970),
        .text(mealID.uuidString))
    }

    /// Returns a needs-attention row to retryable pending (fresh session).
    func retryMeal(mealID: UUID, now: Date = Date()) throws {
        try run("""
        UPDATE meal_outbox SET state = 'pending', last_error = NULL,
               last_error_category = NULL, updated_at = ?
        WHERE local_meal_id = ? AND state = 'needs_attention'
        """, .double(now.timeIntervalSince1970), .text(mealID.uuidString))
    }

    /// Removes a row once the server result is authoritative (or the user
    /// deletes a never-synced pending meal).
    func removeMeal(mealID: UUID) throws {
        try run("DELETE FROM meal_outbox WHERE local_meal_id = ?", .text(mealID.uuidString))
    }

    func updateQueuedMealItems(mealID: UUID, items: [QueuedMealItem], now: Date = Date()) throws {
        try run("""
        UPDATE meal_outbox SET items_json = ?, updated_at = ? WHERE local_meal_id = ?
        """, .text(Self.itemsJSON(items)), .double(now.timeIntervalSince1970),
        .text(mealID.uuidString))
    }

    func clearAccountData() throws {
        try run("DELETE FROM meal_outbox")
        try run("DELETE FROM meta")
    }

    // MARK: - SQLite helpers
}

/// SQLite bind values shared by the local stores (one per-account database
/// file; LocalDataStore + LocalHealthStore use the same vocabulary).
enum SQLiteValue {
    case null
    case text(String)
    case int(Int64)
    case double(Double)
    case blob(Data)
}

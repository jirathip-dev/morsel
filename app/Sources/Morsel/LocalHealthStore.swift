import Foundation
import SQLite3

// Issue #106 — local-first Apple Health persistence for the TWO supported
// types (bodyMass, activeEnergyBurned). Samples land in the account-scoped
// SQLite store BEFORE any remote work; a durable background pass uploads
// them through the authenticated idempotent upserts (weight_logs and
// energy_burned_logs conflict on user+measured_at / user+burned_at). Each
// type keeps its own last-successful watermark so a denied or failing type
// never forces a full-history rescan of the other.
final class LocalHealthStore: WeightLogStore {
    let database: OpaquePointer
    let lock = NSRecursiveLock()
    /// Issue #121 — energy day rows bucket on the DEVICE'S LOCAL day.
    private let calendar = Calendar.autoupdatingCurrent

    private enum Key {
        static let bodyMassAnchor = "health.anchor.bodyMass"
        static let energyAnchor = "health.anchor.activeEnergyBurned"
        static let lastSync = "health.last_upload_success"
        static let lastWeightUpload = "health.last_weight_upload_success"
        static let lastEnergyUpload = "health.last_energy_upload_success"
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
            try runUnsafe("PRAGMA journal_mode = WAL")
            try runUnsafe("""
            CREATE TABLE IF NOT EXISTS weight_samples(
              measured_at REAL PRIMARY KEY,
              kg REAL NOT NULL,
              uploaded INTEGER NOT NULL DEFAULT 0
            )
            """)
            try runUnsafe("""
            CREATE TABLE IF NOT EXISTS energy_days(
              day_key TEXT PRIMARY KEY,
              total REAL NOT NULL,
              uploaded_total REAL,
              upload_burned_at REAL
            )
            """)
            // Issue #121 one-time re-bucket: legacy files carry the 3-column
            // shape; add the upload-instant column in place (new files get it
            // from the CREATE above). upload_burned_at keeps the ORIGINAL
            // (pre-re-bucket) day-start instant a row was uploaded under, so
            // corrected totals upsert over the legacy remote row instead of
            // inserting a duplicate beside it.
            do {
                try runUnsafe("ALTER TABLE energy_days ADD COLUMN upload_burned_at REAL")
            } catch {
                // Column already present (fresh or previously migrated file).
            }
            try runUnsafe("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    // MARK: - WeightLogStore (local-first writes)

    /// Dedupe rule: one row per measurement time — a later sample for the
    /// same time replaces the earlier value; identical re-imports keep the
    /// uploaded flag (no useless re-upload), changed values go dirty.
    func upsert(_ logs: [WeightLog]) async throws {
        try lock.lock(); defer { lock.unlock() }
        for log in logs where log.kilograms.isFinite && log.kilograms > 0 {
            try runUnsafe("""
            INSERT INTO weight_samples(measured_at, kg, uploaded)
            VALUES (?, ?, 0)
            ON CONFLICT(measured_at) DO UPDATE SET
              kg = excluded.kg,
              uploaded = CASE
                WHEN weight_samples.kg = excluded.kg THEN weight_samples.uploaded
                ELSE 0 END
            """, .double(log.measuredAt.timeIntervalSince1970), .double(log.kilograms))
        }
    }

    /// Daily active-energy totals (importer already aggregated + deduped per
    /// LOCAL day). A changed total for an already-uploaded day goes dirty so
    /// the durable pass re-pushes the corrected authoritative day row; the
    /// re-push keeps the row's original upload instant (upload_burned_at) so
    /// it replaces the legacy remote row rather than duplicating it.
    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws {
        try lock.lock(); defer { lock.unlock() }
        for log in logs where log.activeKilocalories.isFinite && log.activeKilocalories > 0 {
            let day = calendar.startOfDay(for: log.burnedAt)
            try runUnsafe("""
            INSERT INTO energy_days(day_key, total, uploaded_total)
            VALUES (?, ?, NULL)
            ON CONFLICT(day_key) DO UPDATE SET
              total = excluded.total,
              uploaded_total = CASE
                WHEN energy_days.uploaded_total = energy_days.total
                 AND excluded.total = energy_days.total
                THEN energy_days.uploaded_total
                ELSE NULL END
            """, .text(Self.dayKey(day)), .double(log.activeKilocalories))
        }
    }

    /// All body-mass rows still awaiting an authenticated remote upsert.
    func unsyncedWeightSamples(limit: Int = 500) throws -> [WeightLog] {
        try query("""
        SELECT measured_at, kg FROM weight_samples
        WHERE uploaded = 0 ORDER BY measured_at ASC LIMIT ?
        """, [.int(Int64(limit))]).compactMap { row -> WeightLog? in
            guard let measuredAt = row.double("measured_at"),
                  let kilograms = row.double("kg") else {
                return nil
            }
            return WeightLog(measuredAt: Date(timeIntervalSince1970: measuredAt), kilograms: kilograms)
        }
    }

    /// Newest stored body-mass sample (synced or still dirty) — the live
    /// weight the computed goal path uses when it is newer than the remote
    /// row (issue #113 amendment A local overlay).
    func newestWeightSample() throws -> WeightLog? {
        lock.lock(); defer { lock.unlock() }
        return try query("""
        SELECT measured_at, kg FROM weight_samples
        ORDER BY measured_at DESC LIMIT 1
        """, []).compactMap { row -> WeightLog? in
            guard let measuredAt = row.double("measured_at"),
                  let kilograms = row.double("kg") else {
                return nil
            }
            return WeightLog(measuredAt: Date(timeIntervalSince1970: measuredAt), kilograms: kilograms)
        }.first
    }

    func markWeightSynced(measuredAt: Date) throws {
        try runUnsafe("""
        UPDATE weight_samples SET uploaded = 1 WHERE measured_at = ?
        """, .double(measuredAt.timeIntervalSince1970))
    }

    /// Days whose aggregate changed since the last successful remote push.
    /// The returned burned-at instant is the row's UPLOAD instant: the local
    /// day start for rows created after the local-day re-bucket, or the row's
    /// original pre-re-bucket day-start instant when one was retained — so a
    /// re-push replaces the legacy remote row (same conflict key) instead of
    /// inserting a second row for the same local day.
    func dirtyEnergyDays(limit: Int = 60) throws -> [EnergyBurnedLog] {
        try query("""
        SELECT day_key, total, upload_burned_at FROM energy_days
        WHERE uploaded_total IS NULL OR uploaded_total <> total
        ORDER BY day_key ASC LIMIT ?
        """, [.int(Int64(limit))]).compactMap { row -> EnergyBurnedLog? in
            guard let dayKey = row.string("day_key"),
                  let day = Self.date(dayKey: dayKey),
                  let total = row.double("total") else {
                return nil
            }
            let uploadInstant = row.double("upload_burned_at").map {
                Date(timeIntervalSince1970: $0)
            } ?? day
            return EnergyBurnedLog(burnedAt: uploadInstant, activeKilocalories: total)
        }
    }

    func markEnergyDaySynced(day: Date) throws {
        try runUnsafe("""
        UPDATE energy_days SET uploaded_total = total WHERE day_key = ?
        """, .text(Self.dayKey(calendar.startOfDay(for: day))))
    }

    // MARK: - Issue #121 one-time local-day re-bucket

    /// Meta key that records the one-shot local-day key migration ran.
    private static let localDayMigrationKey = "migration.local-day-keys.v1"

    /// True once the account file's day keys were re-bucketed to LOCAL days.
    func hasLocalDayKeyMigrationRun() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (try? firstString(
            "SELECT value FROM meta WHERE key = ?", .text(Self.localDayMigrationKey)
        )) != nil
    }

    func markLocalDayKeyMigrationRun() {
        lock.lock(); defer { lock.unlock() }
        try? runUnsafe("""
        INSERT INTO meta(key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, .text(Self.localDayMigrationKey), .text("1"))
    }

    /// One-shot re-bucket of energy day rows written under UTC day starts:
    /// each row's day_key becomes the LOCAL day that contains its stored
    /// instant, and its ORIGINAL key instant is retained as upload_burned_at
    /// so the row keeps upserting over the same remote row it always did
    /// (no duplicate remote rows for one local day). Rows that are already
    /// on a local-day key (e.g. UTC-zone installs) are left untouched.
    func migrateEnergyDayKeysToLocalDays() throws {
        lock.lock(); defer { lock.unlock() }
        let rows = try query(
            "SELECT day_key, upload_burned_at FROM energy_days", []
        )
        for row in rows {
            guard let oldKey = row.string("day_key"),
                  let day = Self.date(dayKey: oldKey) else {
                continue
            }
            let newKey = Self.dayKey(calendar.startOfDay(for: day))
            guard newKey != oldKey else { continue }
            try runUnsafe("""
            UPDATE energy_days
            SET day_key = ?,
                upload_burned_at = COALESCE(upload_burned_at, ?)
            WHERE day_key = ?
            """, .text(newKey), .double(day.timeIntervalSince1970), .text(oldKey))
        }
    }

    /// True when locally stored rows are still awaiting an authenticated
    /// remote upsert (calm `pending` status).
    func hasPendingUploads() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let weights = try query(
            "SELECT measured_at FROM weight_samples WHERE uploaded = 0 LIMIT 1", []
        )
        if !weights.isEmpty { return true }
        let days = try query(
            "SELECT day_key FROM energy_days WHERE uploaded_total IS NULL OR uploaded_total <> total LIMIT 1",
            []
        )
        return !days.isEmpty
    }

    // MARK: - Watermarks (last-successful import anchors)

    func bodyMassAnchor() throws -> Date? { try anchor(Key.bodyMassAnchor) }
    func setBodyMassAnchor(_ date: Date) throws { try setAnchor(date, Key.bodyMassAnchor) }
    func energyAnchor() throws -> Date? { try anchor(Key.energyAnchor) }
    func setEnergyAnchor(_ date: Date) throws { try setAnchor(date, Key.energyAnchor) }

    func lastSuccessfulUpload() throws -> Date? { try anchor(Key.lastSync) }
    func setLastSuccessfulUpload(_ date: Date) throws { try setAnchor(date, Key.lastSync) }

    // Issue #112 — per-type last-upload marks: the engine writes each mark
    // with the SAME timestamp as the last successful upload, but only when
    // ≥1 row of THAT type uploaded in the pass, so the calm status can name
    // exactly the types that truly synced (never a bare weight claim).

    func lastWeightUpload() throws -> Date? { try anchor(Key.lastWeightUpload) }
    func setLastWeightUpload(_ date: Date) throws { try setAnchor(date, Key.lastWeightUpload) }
    func lastEnergyUpload() throws -> Date? { try anchor(Key.lastEnergyUpload) }
    func setLastEnergyUpload(_ date: Date) throws { try setAnchor(date, Key.lastEnergyUpload) }

    /// True when at least one body-mass row exists locally (synced or still
    /// dirty) — the calm no-data state must never claim "no weight data"
    /// while rows exist.
    func hasWeightSamples() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try !query("SELECT measured_at FROM weight_samples LIMIT 1", []).isEmpty
    }

    private func anchor(_ key: String) throws -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let text = try firstString("SELECT value FROM meta WHERE key = ?", .text(key)),
              let interval = TimeInterval(text) else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    private func setAnchor(_ date: Date, _ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        try runUnsafe("""
        INSERT INTO meta(key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, .text(key), .text(String(date.timeIntervalSince1970)))
    }
}

/// One SQLite result row for the health store helpers.
struct HealthRow {
    var storage: [String: HealthValue] = [:]

    func string(_ key: String) -> String? {
        if case let .text(value)? = storage[key] { return value }
        return nil
    }

    func double(_ key: String) -> Double? {
        if case let .double(value)? = storage[key] { return value }
        if case let .int(value)? = storage[key] { return Double(value) }
        return nil
    }
}

/// SQLite column values for the health store's result rows.
enum HealthValue {
    case null
    case text(String)
    case int(Int64)
    case double(Double)
}

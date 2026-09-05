import XCTest
@testable import Morsel

// Issue #121 — (d) ONE-TIME local-day cache re-bucket (AC4). Rows cached
// under UTC day keys (dashboard snapshots, history windows, local energy day
// rows) migrate to LOCAL-day keys on first launch, re-derived from the
// instants each row already stores, with NO data loss and NO duplicates, and
// the migration runs exactly once (flag in the account file's meta).
// Simulator zone MUST be +07 (host default; SIMCTL_CHILD_TZ=Asia/Bangkok).
@MainActor
final class LocalDayMigrationTests: XCTestCase {
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-local-day-migration-tests-(UUID().uuidString)", isDirectory: true)

    private var bangkok: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? TimeZone.current
        return calendar
    }

    private var databaseURL: URL {
        LocalDataStore.storeURL(root: directory, accountID: account)
    }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func iso(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
            ?? Date(timeIntervalSince1970: 0)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        return calendar
    }

    /// The legacy day-key format: String(UTC-day-start.timeIntervalSince1970).
    private func legacyUTCKey(containing instant: Date) -> String {
        String(utcCalendar.startOfDay(for: instant).timeIntervalSince1970)
    }

    /// The new local-day-key format: String(local-day-start.timeIntervalSince1970).
    private func localKey(containing instant: Date) -> String {
        String(bangkok.startOfDay(for: instant).timeIntervalSince1970)
    }

    /// 2026-08-31 23:30 +07 = 16:30Z — UTC day Aug 31, local day Sep 1.
    private var lateDinnerAug31: Date { iso("2026-08-31T16:30:00Z") }

    private func makeStores() throws -> (LocalSnapshotCache, LocalHealthStore) {
        (
            try LocalSnapshotCache(databaseURL: databaseURL),
            try LocalHealthStore(databaseURL: databaseURL)
        )
    }

    private func encodedDashboardSnapshot(date: Date) throws -> Data {
        try JSONEncoder().encode(
            DashboardSnapshot(
                date: date,
                meals: [MealRecord(
                    mealLogID: UUID(),
                    mealType: .dinner,
                    eatenAt: lateDinnerAug31,
                    source: .photoVision,
                    items: []
                )],
                goal: nil
            )
        )
    }

    func testDashboardCacheRowsMigrateToLocalDayKeysWithoutLoss() async throws {
        let (cache, health) = try makeStores()
        // Legacy row: cached under the UTC day key of the fetch date, with the
        // payload's own date = that UTC day start (the old repository shape).
        let utcFetchDate = utcCalendar.startOfDay(for: iso("2026-09-01T02:00:00Z"))
        let oldKey = String(utcFetchDate.timeIntervalSince1970)
        let payload = try encodedDashboardSnapshot(date: utcFetchDate)
        try cache.saveDashboardCache(dayKey: oldKey, payload: payload)

        try LocalDayMigration.runIfNeeded(cache: cache, health: health)

        // The row must now live under the LOCAL-day key (Sep 1 +07) with the
        // IDENTICAL payload; the old key must be gone.
        let migrated = try XCTUnwrap(try cache.loadDashboardCache(dayKey: localKey(containing: utcFetchDate)))
        XCTAssertEqual(migrated, payload, "re-bucket must move the payload, never rewrite it")
        XCTAssertNil(try cache.loadDashboardCache(dayKey: oldKey), "the legacy key must not survive")
        XCTAssertEqual(try cache.allDashboardCacheRows().count, 1, "one row in, one row out")
        XCTAssertTrue(health.hasLocalDayKeyMigrationRun())
    }

    func testHistoryCacheRowsMigrateToLocalDayKeys() async throws {
        let (cache, health) = try makeStores()
        let utcEnd = utcCalendar.startOfDay(for: iso("2026-09-01T02:00:00Z"))
        let oldKey = "\(String(utcEnd.timeIntervalSince1970))-7"
        let payload = Data("history-window".utf8)
        try cache.saveHistoryCache(cacheKey: oldKey, payload: payload)

        try LocalDayMigration.runIfNeeded(cache: cache, health: health)

        let migrated = try XCTUnwrap(
            try cache.loadHistoryCache(cacheKey: "\(localKey(containing: utcEnd))-7")
        )
        XCTAssertEqual(migrated, payload)
        XCTAssertNil(try cache.loadHistoryCache(cacheKey: oldKey))
    }

    func testEnergyDayRowsMigrateToLocalKeysKeepingUploadStateAndInstant() async throws {
        let (_, health) = try makeStores()
        // Legacy rows written by the pre-change app: key = UTC day start.
        let utcDayStart = utcCalendar.startOfDay(for: iso("2026-09-01T02:00:00Z"))
        let nextDay = utcCalendar.date(byAdding: .day, value: 1, to: utcDayStart)
            ?? utcDayStart.addingTimeInterval(86_400)
        let oldKey = String(utcDayStart.timeIntervalSince1970)
        let nextKey = String(nextDay.timeIntervalSince1970)
        try health.runUnsafe(
            "INSERT INTO energy_days(day_key, total, uploaded_total) VALUES (?, ?, ?)",
            .text(oldKey), .double(500), .double(500)
        )
        try health.runUnsafe(
            "INSERT INTO energy_days(day_key, total, uploaded_total) VALUES (?, ?, NULL)",
            .text(nextKey), .double(300)
        )

        try LocalDayMigration.runIfNeeded(
            cache: try LocalSnapshotCache(databaseURL: databaseURL), health: health
        )

        let rows = try health.query(
            "SELECT day_key, total, uploaded_total, upload_burned_at FROM energy_days ORDER BY day_key", []
        )
        XCTAssertEqual(rows.count, 2, "re-bucket must not lose rows")
        // UTC Sep 1 00:00 = 07:00 +07 Sep 1 → LOCAL day Sep 1.
        let migratedKey = localKey(containing: utcDayStart)
        let migrated = try XCTUnwrap(rows.first { $0.string("day_key") == migratedKey })
        XCTAssertEqual(migrated.double("total"), 500)
        XCTAssertEqual(migrated.double("uploaded_total"), 500, "a synced legacy row stays synced")
        XCTAssertEqual(
            migrated.double("upload_burned_at"),
            utcDayStart.timeIntervalSince1970,
            "the original upload instant is retained so re-pushes replace the legacy remote row"
        )
        // The next UTC day re-keys to the NEXT local day (still dirty).
        let nextLocalDay = localKey(containing: utcDayStart.addingTimeInterval(86_400))
        let migratedDirty = try XCTUnwrap(
            rows.first { $0.string("day_key") == nextLocalDay }
        )
        XCTAssertEqual(migratedDirty.double("total"), 300)
        XCTAssertNil(migratedDirty.double("uploaded_total"), "a never-uploaded legacy row stays dirty")
        let expectedRetained = utcDayStart.addingTimeInterval(86_400).timeIntervalSince1970
        XCTAssertEqual(migratedDirty.double("upload_burned_at"), expectedRetained)

        // Dirty row uploads at its RETAINED legacy instant (single remote row).
        let dirty = try health.dirtyEnergyDays()
        XCTAssertEqual(dirty.count, 1)
        XCTAssertEqual(dirty.first?.burnedAt, utcDayStart.addingTimeInterval(86_400))

        // markEnergyDaySynced(day: the upload instant) clears the re-keyed row.
        try health.markEnergyDaySynced(day: utcDayStart.addingTimeInterval(86_400))
        XCTAssertTrue(try health.dirtyEnergyDays().isEmpty)
        XCTAssertFalse(try health.hasPendingUploads())
    }

    func testMigrationRunsExactlyOnce() async throws {
        let (cache, health) = try makeStores()
        let utcFetchDate = utcCalendar.startOfDay(for: iso("2026-09-01T02:00:00Z"))
        let oldKey = String(utcFetchDate.timeIntervalSince1970)
        let payload = try encodedDashboardSnapshot(date: utcFetchDate)
        try cache.saveDashboardCache(dayKey: oldKey, payload: payload)
        try health.runUnsafe(
            "INSERT INTO energy_days(day_key, total, uploaded_total) VALUES (?, ?, NULL)",
            .text(oldKey), .double(100)
        )

        try LocalDayMigration.runIfNeeded(cache: cache, health: health)
        let afterFirst = try cache.allDashboardCacheRows().count
        let rowsAfterFirst = try health.query("SELECT day_key FROM energy_days", []).count

        // Second launch: flag set → nothing moves again (idempotent).
        try LocalDayMigration.runIfNeeded(cache: cache, health: health)
        XCTAssertEqual(try cache.allDashboardCacheRows().count, afterFirst)
        XCTAssertEqual(try health.query("SELECT day_key FROM energy_days", []).count, rowsAfterFirst)
        XCTAssertEqual(
            try health.query("SELECT day_key FROM energy_days", []).first?.string("day_key"),
            localKey(containing: utcFetchDate)
        )
    }
}

// Issue #121 — device-zone guard for the profiles.timezone write.
final class DeviceTimezoneSyncTests: XCTestCase {
    func testWritableIANAZoneGuardMatchesTheDatabaseCheck() {
        XCTAssertTrue(DeviceTimezoneSync.isWritableIANAZone("Asia/Bangkok"))
        XCTAssertTrue(DeviceTimezoneSync.isWritableIANAZone("America/Argentina/Buenos_Aires"))
        XCTAssertTrue(DeviceTimezoneSync.isWritableIANAZone("Etc/GMT+7"))
        XCTAssertTrue(DeviceTimezoneSync.isWritableIANAZone("UTC"))
        // The guard mirrors the profiles_timezone_check shape: any '/' name
        // passes (authoritative IANA validation is the server's job; the app
        // only ever sees canonical Foundation identifiers).
        XCTAssertTrue(DeviceTimezoneSync.isWritableIANAZone("Asia/Bangkok/Extra"))
        XCTAssertFalse(DeviceTimezoneSync.isWritableIANAZone("GMT"))
        XCTAssertFalse(DeviceTimezoneSync.isWritableIANAZone("Local"))
        XCTAssertFalse(DeviceTimezoneSync.isWritableIANAZone(""))
    }
}

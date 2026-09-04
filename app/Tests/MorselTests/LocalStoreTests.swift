import XCTest
@testable import Morsel

// Issue #106 — account-scoped SQLite store semantics: durable single-row
// meal commit (items JSON + photo BLOB in one transaction), relaunch
// persistence, account isolation (separate files → no cross-account leak),
// cache write-through/read-back, and health-sample dedupe + watermarks.
final class LocalStoreTests: XCTestCase {
    // New XCTestCase instance per test method: UUID-scoped identities + scratch
    // directory are unique per test without implicitly unwrapped optionals.
    private let accountA = UUID()
    private let accountB = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-store-tests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(for account: UUID) throws -> LocalDataStore {
        try LocalDataStore(
            databaseURL: LocalDataStore.storeURL(root: directory, accountID: account)
        )
    }

    private func cache(for account: UUID) throws -> LocalSnapshotCache {
        try LocalSnapshotCache(
            databaseURL: LocalDataStore.storeURL(root: directory, accountID: account)
        )
    }

    private func health(for account: UUID) throws -> LocalHealthStore {
        try LocalHealthStore(databaseURL: LocalDataStore.storeURL(root: directory, accountID: account))
    }

    private func queuedMeal() -> QueuedMeal {
        QueuedMealFactory.make(
            draft: MealDraft(
                mealType: .lunch,
                eatenAt: Date(timeIntervalSince1970: 1_000),
                notes: "quick",
                items: [MealItemDraft(name: "oats", quantity: 1, unit: .serving,
                                      caloriesKcal: 220, proteinG: 8)]
            ),
            photo: FoodImageUpload(data: Data([0xAA, 0xBB, 0xCC]), mimeType: "image/jpeg"),
            mealID: UUID(),
            now: Date(timeIntervalSince1970: 2_000)
        )
    }

    func testEnqueueCommitsMealItemsAndPhotoInOneRow() async throws {
        let store = try store(for: accountA)
        let meal = queuedMeal()

        try store.enqueueMeal(meal)

        let rows = try store.queuedMeals()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.mealID, meal.mealID)
        XCTAssertEqual(rows.first?.state, .pending)
        XCTAssertEqual(rows.first?.items.count, 1)
        XCTAssertEqual(rows.first?.items.first?.name, "oats")
        XCTAssertEqual(rows.first?.photo?.data, Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(rows.first?.mealRecord.syncState, .pending)
    }

    func testRelaunchReopensTheSameDurableRows() async throws {
        let url = LocalDataStore.storeURL(root: directory, accountID: accountA)
        let meal = queuedMeal()
        try LocalDataStore(databaseURL: url).enqueueMeal(meal)

        // Process/restart recovery: a NEW store instance over the same file
        // still sees the queued meal + photo.
        let reopened = try LocalDataStore(databaseURL: url)
        let rows = try reopened.queuedMeals()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.mealID, meal.mealID)
        XCTAssertEqual(rows.first?.photo?.mimeType, "image/jpeg")
    }

    func testAccountIsolationAndClear() async throws {
        try store(for: accountA).enqueueMeal(queuedMeal())
        try cache(for: accountA).saveDashboardCache(
            dayKey: "1", payload: Data("snapshot-A".utf8)
        )

        // Account B's separate file never sees A's rows.
        let storeB = try store(for: accountB)
        XCTAssertTrue(try storeB.queuedMeals().isEmpty)
        XCTAssertNil(try cache(for: accountB).loadDashboardCache(dayKey: "1"))

        // Logout clears A completely.
        try store(for: accountA).clearAccountData()
        XCTAssertTrue(try store(for: accountA).queuedMeals().isEmpty)
    }

    func testAttemptBookkeepingAndNeedsAttentionPreservesPayload() async throws {
        let store = try store(for: accountA)
        let meal = queuedMeal()
        try store.enqueueMeal(meal)

        try store.recordMealAttempt(mealID: meal.mealID, error: .validation, now: Date())
        let row = try XCTUnwrap(store.queuedMeal(mealID: meal.mealID))
        XCTAssertEqual(row.state, .needsAttention)
        XCTAssertEqual(row.attempts, 1)
        XCTAssertEqual(row.lastErrorCategory, .validation)
        XCTAssertEqual(row.lastError, OutboxErrorCategory.validation.friendlyDescription)
        XCTAssertEqual(row.photo?.data, meal.photo?.data, "recoverable data must survive refusal")

        try store.retryMeal(mealID: meal.mealID)
        let retried = try XCTUnwrap(store.queuedMeal(mealID: meal.mealID))
        XCTAssertEqual(retried.state, .pending)
        XCTAssertNil(retried.lastError)
    }

    func testQueuedMealEditMutatesDurableDraft() async throws {
        let store = try store(for: accountA)
        let meal = queuedMeal()
        try store.enqueueMeal(meal)
        let itemID = try XCTUnwrap(meal.items.first?.itemID)

        var items = meal.items
        items[0] = QueuedMealItem(
            itemID: itemID, name: "oats + berries", quantity: 2, unit: "serving",
            caloriesKcal: 300, proteinG: 8, carbsG: 50, fatG: 5, fiberG: 6,
            sugarG: 12, confidence: 1, notes: nil
        )
        try store.updateQueuedMealItems(mealID: meal.mealID, items: items)

        let row = try XCTUnwrap(store.queuedMeal(mealID: meal.mealID))
        XCTAssertEqual(row.items.count, 1)
        XCTAssertEqual(row.items.first?.name, "oats + berries")
        XCTAssertEqual(row.items.first?.itemID, itemID, "stable client item id")
    }

    func testSnapshotCacheRoundTripAndClear() async throws {
        let cache = try cache(for: accountA)
        try cache.saveDashboardCache(dayKey: "d1", payload: Data("payload".utf8))
        XCTAssertEqual(try cache.loadDashboardCache(dayKey: "d1"), Data("payload".utf8))
        XCTAssertNil(try cache.loadDashboardCache(dayKey: "missing"))

        try cache.clearAccountData()
        XCTAssertNil(try cache.loadDashboardCache(dayKey: "d1"))
    }

    func testWeightSampleDedupeAndUploadFlagRules() async throws {
        let health = try health(for: accountA)
        let date = Date(timeIntervalSince1970: 5_000)
        try await health.upsert([WeightLog(measuredAt: date, kilograms: 80)])
        try await health.upsert([WeightLog(measuredAt: date, kilograms: 81)])

        XCTAssertEqual(try health.unsyncedWeightSamples(), [WeightLog(measuredAt: date, kilograms: 81)])
        try health.markWeightSynced(measuredAt: date)
        XCTAssertTrue(try health.unsyncedWeightSamples().isEmpty)

        // Identical re-import keeps the synced flag; a changed value goes
        // dirty again so the durable pass re-pushes it.
        try await health.upsert([WeightLog(measuredAt: date, kilograms: 81)])
        XCTAssertTrue(try health.unsyncedWeightSamples().isEmpty)
        try await health.upsert([WeightLog(measuredAt: date, kilograms: 79)])
        XCTAssertEqual(try health.unsyncedWeightSamples(), [WeightLog(measuredAt: date, kilograms: 79)])
    }

    func testEnergyDayTotalsDirtyOnlyWhenChanged() async throws {
        let health = try health(for: accountA)
        let day = Date(timeIntervalSince1970: 10_000)
        let later = Date(timeIntervalSince1970: 10_000 + 86_400)

        try await health.upsertEnergyBurned([EnergyBurnedLog(burnedAt: day, activeKilocalories: 300)])
        try await health.upsertEnergyBurned([EnergyBurnedLog(burnedAt: day, activeKilocalories: 420)])

        XCTAssertEqual(try health.dirtyEnergyDays().count, 1)
        XCTAssertEqual(try health.dirtyEnergyDays().first?.activeKilocalories, 420)
        try health.markEnergyDaySynced(day: day)
        XCTAssertTrue(try health.dirtyEnergyDays().isEmpty)

        // Same total re-import stays clean; growth goes dirty.
        try await health.upsertEnergyBurned([EnergyBurnedLog(burnedAt: day, activeKilocalories: 420)])
        XCTAssertTrue(try health.dirtyEnergyDays().isEmpty)
        try await health.upsertEnergyBurned([EnergyBurnedLog(burnedAt: later, activeKilocalories: 100)])
        XCTAssertEqual(try health.dirtyEnergyDays().count, 1)
    }

    func testWatermarksAndPendingDetection() async throws {
        let health = try health(for: accountA)
        XCTAssertNil(try health.bodyMassAnchor())
        let anchor = Date(timeIntervalSince1970: 50_000)
        try health.setBodyMassAnchor(anchor)
        XCTAssertEqual(try health.bodyMassAnchor(), anchor)
        XCTAssertFalse(try health.hasPendingUploads())

        try await health.upsert([WeightLog(measuredAt: Date(), kilograms: 70)])
        XCTAssertTrue(try health.hasPendingUploads())
        try health.setLastSuccessfulUpload(Date())
        XCTAssertNotNil(try health.lastSuccessfulUpload())
    }

    func testInvalidWeightAndEnergyRowsAreRejectedAtTheStore() async throws {
        let health = try health(for: accountA)
        let date = Date(timeIntervalSince1970: 5_000)
        try await health.upsert([
            WeightLog(measuredAt: date, kilograms: 0),
            WeightLog(measuredAt: date, kilograms: .infinity),
            WeightLog(measuredAt: date.addingTimeInterval(1), kilograms: -4)
        ])
        XCTAssertTrue(try health.unsyncedWeightSamples().isEmpty)

        try await health.upsertEnergyBurned([
            EnergyBurnedLog(burnedAt: date, activeKilocalories: 0),
            EnergyBurnedLog(burnedAt: date, activeKilocalories: .nan)
        ])
        XCTAssertTrue(try health.dirtyEnergyDays().isEmpty)
    }
}

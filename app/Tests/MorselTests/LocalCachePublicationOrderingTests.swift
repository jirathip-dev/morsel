import SQLite3
import XCTest
@testable import Morsel

// Issue #183 — generation-scoped cache publication. Every witness drives the
// SHIPPED local-first facade over a real per-account SQLite file: reads are
// held by continuation and released in a chosen order, and the published entry
// is read back through a NEWLY OPENED reader (the warm restart) instead of a
// double that could re-implement the ordering under test. Synthetic values only.

/// Scripted remote: one step per read, consumed in call order per key. A step
/// may park until the test releases it, and may fail with a transport error —
/// the parked payload is returned even after cancellation, exactly like a
/// remote that ignores it.
actor CacheOrderingRemote: DashboardRepository {
    struct Step {
        let value: Double
        let parks: Bool
        let error: Error?
    }

    private var remaining: [String: [Step]] = [:]
    private var consumed: [String: Int] = [:]
    private var parked: [String: CheckedContinuation<Void, Error>] = [:]

    /// The repository's own day key: the scripted steps are consumed by exactly
    /// the reads under test, and the test's tokens are built from the same key.
    static func key(_ date: Date) -> String { LocalFirstDashboardRepository.dayKey(date) }

    func script(_ key: String, value: Double, parks: Bool = false, error: Error? = nil) {
        remaining[key, default: []].append(Step(value: value, parks: parks, error: error))
    }

    func isParked(_ token: String) -> Bool { parked[token] != nil }

    func release(_ token: String) {
        parked.removeValue(forKey: token)?.resume()
    }

    func releaseAll() {
        let pending = parked.values
        parked.removeAll()
        for gate in pending { gate.resume() }
    }

    private func take(_ key: String) -> (Step, String) {
        var steps = remaining[key] ?? []
        let step = steps.isEmpty ? Step(value: 100, parks: false, error: nil) : steps.removeFirst()
        remaining[key] = steps
        let index = consumed[key] ?? 0
        consumed[key] = index + 1
        return (step, "\(key)#\(index)")
    }

    private func read(_ date: Date) async throws -> Double {
        let (step, token) = take(Self.key(date))
        if step.parks {
            try await withCheckedThrowingContinuation { (gate: CheckedContinuation<Void, Error>) in
                parked[token] = gate
            }
        }
        if let error = step.error { throw error }
        return step.value
    }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        CacheOrderingFixture.snapshot(date: date, marker: try await read(date))
    }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        HistoryOverview(days: [], goal: nil, weightTrend: [])
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID { UUID() }
    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        throw MorselError.configurationMissing
    }
}

enum CacheOrderingFixture {
    static func snapshot(date: Date, marker: Double) -> DashboardSnapshot {
        DashboardSnapshot(date: DashboardMath.startOfLocalDay(date), meals: [MealRecord(
            mealLogID: UUID(), mealType: .lunch, eatenAt: date, source: .manual, imagePath: nil,
            items: [MealItem(itemID: UUID(), name: "synthetic bowl \(marker)", quantity: 1, unit: .serving,
                             caloriesKcal: marker, proteinG: 1, carbsG: 2, fatG: 3,
                             fiberG: nil, sugarG: nil, confidence: nil, notes: nil, source: .manual)]
        )], goal: nil)
    }
}

extension DashboardSnapshot {
    /// The synthetic payload identity these witnesses compare (never real content).
    var syntheticMarker: Double? { meals.first?.items.first?.caloriesKcal }
}

@MainActor
class CachePublicationTestCase: XCTestCase {
    let account = UUID()
    let otherAccount = UUID()
    /// 2026-06-24 (fixed local reference day) and a fixed injected clock.
    let reference = Date(timeIntervalSince1970: 1_782_000_000)
    let clock = Date(timeIntervalSince1970: 1_781_000_000)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cache-publication-\(UUID())")
    let remote = CacheOrderingRemote()

    var dayKey: String { LocalFirstDashboardRepository.dayKey(reference) }
    var tomorrowKey: String { LocalFirstDashboardRepository.dayKey(reference.addingTimeInterval(86_400)) }

    override func tearDown() async throws {
        await remote.releaseAll()
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func storeURL(_ accountID: UUID? = nil) -> URL {
        LocalDataStore.storeURL(root: directory, accountID: accountID ?? account)
    }

    func makeRepository(accountID: UUID? = nil) throws -> LocalFirstDashboardRepository {
        let url = storeURL(accountID)
        return LocalFirstDashboardRepository(
            remote: remote,
            store: try LocalDataStore(databaseURL: url),
            snapshotCache: try LocalSnapshotCache(databaseURL: url),
            dateProvider: { self.clock }
        )
    }

    /// A NEWLY OPENED reader over the same account file (the warm restart).
    func reopenedCache(accountID: UUID? = nil) throws -> LocalSnapshotCache {
        try LocalSnapshotCache(databaseURL: storeURL(accountID))
    }

    func storedMarker(_ repository: LocalFirstDashboardRepository, key: String) throws -> Double? {
        guard let payload = try repository.snapshotCache.loadDashboardCache(dayKey: key) else { return nil }
        return try LocalFirstDashboardRepository.decode(DashboardSnapshot.self, payload).syntheticMarker
    }

    func waitParked(_ token: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await remote.isParked(token)), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let parked = await remote.isParked(token)
        XCTAssertTrue(parked, "scripted read never parked: \(token)", file: file, line: line)
        if !parked { await remote.releaseAll() }
    }

    func expectCancellation(
        _ task: Task<DashboardSnapshot, Error>, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            let late = try await task.value
            XCTFail("a superseded read reported \(late.syntheticMarker ?? -1) as fresh data",
                    file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError,
                          "supersession is cancellation, got \(error)", file: file, line: line)
        }
    }
}

@MainActor
final class CachePublicationOrderingTests: CachePublicationTestCase {
    func testReversedCompletionPublishesOnlyTheNewerReadAndSurvivesWarmRestart() async throws {
        let repository = try makeRepository()
        await remote.script(dayKey, value: 200, parks: true)
        await remote.script(dayKey, value: 900, parks: true)
        let older = Task { try await repository.loadToday(userID: account, date: reference) }
        await waitParked("\(dayKey)#0")
        let newer = Task { try await repository.loadToday(userID: account, date: reference) }
        await waitParked("\(dayKey)#1")

        await remote.release("\(dayKey)#1")
        let newest = try await newer.value
        XCTAssertEqual(newest.syntheticMarker, 900)
        XCTAssertEqual(newest.readProvenance?.isCached, false)

        await remote.release("\(dayKey)#0")
        await expectCancellation(older)

        let restarted = try makeRepository()
        let painted = try await restarted.cachedToday(userID: account, date: reference)
        XCTAssertEqual(painted?.syntheticMarker, 900, "the warm restart serves the newer read")
        XCTAssertEqual(painted?.readProvenance?.isCached, true,
                       "an obsolete payload is never presented as a fresh one")
        XCTAssertEqual(try storedMarker(restarted, key: dayKey), 900)
    }

    func testMutationInvalidationCannotPublishAnInFlightRead() async throws {
        let repository = try makeRepository()
        await remote.script(dayKey, value: 500)
        _ = try await repository.loadToday(userID: account, date: reference)
        XCTAssertEqual(try storedMarker(repository, key: dayKey), 500)

        await remote.script(dayKey, value: 640, parks: true)
        let inFlight = Task { try await repository.loadToday(userID: account, date: reference) }
        await waitParked("\(dayKey)#1")
        _ = try await repository.logMeal(
            userID: account, draft: FirstPaintFixture.draft(eatenAt: reference), photo: nil
        )
        await remote.release("\(dayKey)#1")
        await expectCancellation(inFlight)

        XCTAssertEqual(try storedMarker(repository, key: dayKey), 500,
                       "a read superseded by a mutation never writes the cache")
    }

    func testRefreshOwnerInvalidationCannotPublishTheInvalidatedPass() async throws {
        let repository = try makeRepository()
        let owner = TodayRefreshOwner(repository: repository, userID: account)
        await remote.script(dayKey, value: 900, parks: true)
        await remote.script(dayKey, value: 0, error: URLError(.notConnectedToInternet))
        var events: [TodayRefreshOwner.Event] = []
        let flight = owner.start(
            date: reference, needsCache: false, invalidating: false, superseding: false
        ) { events.append($0) }
        await waitParked("\(dayKey)#0")

        let invalidated = owner.start(
            date: reference, needsCache: true, invalidating: true, superseding: false
        ) { events.append($0) }
        XCTAssertTrue(invalidated === flight, "the invalidation reuses the in-flight pass")

        await remote.release("\(dayKey)#0")
        await owner.wait(for: flight)

        XCTAssertFalse(events.contains { event in
            if case .loaded(let snapshot) = event { return snapshot.syntheticMarker == 900 }
            return false
        }, "the invalidated pass's payload is never published")
        XCTAssertNil(try storedMarker(repository, key: dayKey),
                     "an invalidated pass cannot write the cache")
        let painted = try await repository.cachedToday(userID: account, date: reference)
        XCTAssertNil(painted)
    }

    func testEqualTimestampsCannotBypassOrdering() async throws {
        let repository = try makeRepository()
        await remote.script(dayKey, value: 200, parks: true)
        await remote.script(dayKey, value: 950, parks: true)
        let older = Task { try await repository.loadToday(userID: account, date: reference) }
        await waitParked("\(dayKey)#0")
        let newer = Task { try await repository.loadToday(userID: account, date: reference) }
        await waitParked("\(dayKey)#1")

        await remote.release("\(dayKey)#1")
        _ = try await newer.value
        await remote.release("\(dayKey)#0")
        await expectCancellation(older)

        let rows = try reopenedCache().allDashboardCacheRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.savedAt, clock, "both reads stamp the same instant")
        XCTAssertEqual(try storedMarker(repository, key: dayKey), 950)

        // A newer generation still publishes under that same instant: the
        // ordering is a generation, never a comparison of `saved_at` values.
        await remote.script(dayKey, value: 990)
        _ = try await repository.loadToday(userID: account, date: reference)
        XCTAssertEqual(try storedMarker(repository, key: dayKey), 990)
    }
}

@MainActor
final class CachePublicationFenceTests: CachePublicationTestCase {
    func testAccountTeardownFencesInFlightWritesAndServesLaterReads() async throws {
        let repository = try makeRepository()
        await remote.script(dayKey, value: 640, parks: true)
        let inFlight = Task { try await repository.loadToday(userID: account, date: reference) }
        await waitParked("\(dayKey)#0")

        try repository.snapshotCache.clearAccountData()
        await remote.release("\(dayKey)#0")
        await expectCancellation(inFlight)
        XCTAssertTrue(try repository.snapshotCache.allDashboardCacheRows().isEmpty,
                      "a torn-down account's in-flight read repopulates nothing")
        let tornDown = try await repository.cachedToday(userID: account, date: reference)
        XCTAssertNil(tornDown)

        await remote.script(dayKey, value: 880)
        _ = try await repository.loadToday(userID: account, date: reference)
        XCTAssertEqual(try storedMarker(repository, key: dayKey), 880,
                       "the teardown is a fence, not a permanent stop")
    }

    func testCancellationIsCancellationAndOfflineKeepsTheCachedDay() async throws {
        let repository = try makeRepository()
        await remote.script(dayKey, value: 500)
        _ = try await repository.loadToday(userID: account, date: reference)

        await remote.script(dayKey, value: 640, parks: true)
        let cancelled = Task { try await repository.loadToday(userID: account, date: reference) }
        await waitParked("\(dayKey)#1")
        cancelled.cancel()
        await remote.release("\(dayKey)#1")
        await expectCancellation(cancelled)
        XCTAssertEqual(try storedMarker(repository, key: dayKey), 500,
                       "a cancelled read never overwrites the cache")

        await remote.script(dayKey, value: 0, error: URLError(.notConnectedToInternet))
        let offline = try await repository.loadToday(userID: account, date: reference)
        XCTAssertEqual(offline.syntheticMarker, 500, "a genuine offline failure preserves the cached day")
        XCTAssertEqual(offline.readProvenance?.isCached, true)
        XCTAssertNotNil(offline.readProvenance?.loadedAt)

        let cold = try makeRepository(accountID: otherAccount)
        await remote.script(dayKey, value: 0, error: URLError(.timedOut))
        do {
            _ = try await cold.loadToday(userID: otherAccount, date: reference)
            XCTFail("an offline read with nothing cached is never reported as success")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testIndependentDaysAndAccountsAreNotBlockedByAHeldRead() async throws {
        let repository = try makeRepository()
        await remote.script(dayKey, value: 200, parks: true)
        let held = Task { try await repository.loadToday(userID: account, date: reference) }
        await waitParked("\(dayKey)#0")

        await remote.script(tomorrowKey, value: 700)
        let otherDay = try await repository.loadToday(
            userID: account, date: reference.addingTimeInterval(86_400)
        )
        XCTAssertEqual(otherDay.syntheticMarker, 700, "an independent day is not blocked")

        await remote.script(dayKey, value: 800)
        let otherAccountDay = try await repository.loadToday(userID: otherAccount, date: reference)
        XCTAssertEqual(otherAccountDay.syntheticMarker, 800, "an independent account is not blocked")

        await remote.release("\(dayKey)#0")
        let released = try await held.value
        XCTAssertEqual(released.syntheticMarker, 200, "the held read still publishes its own key")
        XCTAssertEqual(try storedMarker(repository, key: dayKey), 200)
    }

    func testCacheWriteFailureStillReturnsTheFreshRemoteRead() async throws {
        let repository = try makeRepository()
        await remote.script(dayKey, value: 500)
        _ = try await repository.loadToday(userID: account, date: reference)
        try dropDashboardCacheTable()

        await remote.script(dayKey, value: 900)
        let fresh = try await repository.loadToday(userID: account, date: reference)
        XCTAssertEqual(fresh.syntheticMarker, 900,
                       "a cache write fault never turns a successful read into an older answer")
        XCTAssertEqual(fresh.readProvenance?.isCached, false,
                       "the read really was fresh; a cache fault is not cached provenance")
    }

    /// A real SQLite fault on the cache write: the table is gone.
    private func dropDashboardCacheTable() throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL().path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = handle else {
            if let handle { sqlite3_close(handle) }
            XCTFail("could not open the account database for the write-failure witness")
            return
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "DROP TABLE dashboard_cache", nil, nil, nil), SQLITE_OK)
    }
}

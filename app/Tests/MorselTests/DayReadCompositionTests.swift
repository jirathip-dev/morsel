import Supabase
import XCTest
@testable import Morsel

@MainActor
final class DayReadCompositionTests: XCTestCase {
    private let account = UUID(uuidString: "47474747-4747-4747-8747-474747474747") ?? UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-258-composition-\(UUID().uuidString)", isDirectory: true)
    private let referenceInstant = ISO8601DateFormatter().date(from: "2026-09-05T04:00:00Z") ?? Date()

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        StubTransport.reset()
    }

    override func tearDownWithError() throws {
        StubTransport.release()
        StubTransport.reset()
        try FileManager.default.removeItem(at: directory)
    }

    func testFailedRefreshThroughLocalFirstKeepsSuccessfulTimeAndRetryRecovers() async throws {
        let repository = try await makeRepository()
        var now = referenceInstant
        let model = DashboardViewModel(repository: repository, userID: account, dateProvider: { now })
        await model.load()
        XCTAssertEqual(model.snapshot?.meals.count, 1)
        XCTAssertFalse(model.isShowingCachedDay)
        let successfulTime = try XCTUnwrap(model.lastLoadedAt)

        now = now.addingTimeInterval(7_200)
        failDayRead()
        await model.load()
        XCTAssertEqual(model.snapshot?.meals.count, 1, "the real facade serves its populated SQLite cache")
        XCTAssertTrue(model.isShowingCachedDay, "cache fallback must be visible through the real facade")
        XCTAssertEqual(model.snapshot?.readProvenance?.outcome, .failed, "the concluded failure is announced")
        XCTAssertEqual(model.lastLoadedAt, successfulTime, "failed refresh must not stamp success")

        // Recreate BOTH facade and view model: the timestamp belongs to the saved day, not VM memory.
        let restarted = DashboardViewModel(
            repository: try await makeRepository(), userID: account, dateProvider: { now }
        )
        failDayRead()
        await restarted.load()
        XCTAssertTrue(restarted.isShowingCachedDay)
        XCTAssertEqual(restarted.lastLoadedAt, successfulTime)
        XCTAssertEqual(restarted.snapshot?.meals.count, 1)

        StubTransport.respond("meal_logs", .init(body: mealLogs))
        await model.load()
        XCTAssertFalse(model.isShowingCachedDay, "Try again uses this same load path")
        XCTAssertEqual(model.snapshot?.readProvenance?.outcome, .fresh)
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.lastLoadedAt)
    }

    func testLegacyCacheHasNoInventedSuccessTimeAndEmptyCacheStillErrors() async throws {
        let repository = try await makeRepository()
        failDayRead()
        let model = DashboardViewModel(
            repository: repository, userID: account, dateProvider: { self.referenceInstant }
        )
        await model.load()
        XCTAssertNil(model.snapshot, "read error is not an empty successful day")
        XCTAssertFalse(model.isShowingCachedDay)
        XCTAssertNil(model.lastLoadedAt)
        XCTAssertNotNil(model.errorMessage)

        let day = DashboardMath.startOfLocalDay(referenceInstant)
        let meal = MealRecord(mealLogID: UUID(), mealType: .dinner, eatenAt: day, source: .manual, items: [])
        let snapshot = DashboardSnapshot(date: day, meals: [meal], goal: nil)
        try repository.snapshotCache.saveDashboardCache(
            dayKey: LocalFirstDashboardRepository.dayKey(day), payload: try JSONEncoder().encode(snapshot)
        )
        await model.load()
        XCTAssertEqual(model.snapshot?.meals.count, 1)
        XCTAssertTrue(model.isShowingCachedDay)
        XCTAssertEqual(model.snapshot?.readProvenance?.outcome, .failed, "the failed refresh is announced")
        XCTAssertNil(model.lastLoadedAt, "a legacy cache without provenance must not invent a time")
    }

    /// Issue #303 — a healthy load must never show the cached notice. The
    /// cached pre-paint is on screen while the fresh read is PARKED in flight,
    /// so the whole in-flight window is observable in state (no rendered
    /// frame, no sleep): the notice flag must be false throughout, and the
    /// successful refresh must keep it false.
    func testHealthyLoadNeverShowsTheCachedNoticeThroughTheInFlightWindow() async throws {
        let repository = try await makeRepository()
        var now = referenceInstant
        let seeded = DashboardViewModel(repository: repository, userID: account, dateProvider: { now })
        await seeded.load()
        XCTAssertEqual(seeded.snapshot?.meals.count, 1, "the first load seeds the cache")

        // Restart over the same cache with the fresh read parked: the cached
        // pre-paint paints and its refresh stays in flight behind it.
        now = now.addingTimeInterval(60)
        let restarted = DashboardViewModel(
            repository: try await makeRepository(), userID: account, dateProvider: { now }
        )
        StubTransport.respond("meal_logs", .init(body: mealLogs, hold: true))
        let load = Task { await restarted.load() }
        await waitFor("the cached pre-paint is on screen with the refresh parked") {
            restarted.snapshot?.readProvenance?.isCached == true
        }
        XCTAssertFalse(
            restarted.isShowingCachedDay,
            "a cached copy with its refresh still in flight must not announce a failure"
        )
        XCTAssertEqual(restarted.snapshot?.readProvenance?.isCached, true, "the parked paint is the cached copy")

        StubTransport.release("meal_logs")
        await load.value

        XCTAssertFalse(restarted.isShowingCachedDay, "the successful refresh keeps the notice away")
        XCTAssertEqual(restarted.snapshot?.meals.count, 1)
        XCTAssertEqual(restarted.snapshot?.readProvenance?.isCached, false, "the settled day is the fresh read")
    }

    /// Issue #303 AC4 — the in-flight/failed distinction is STATE, not timing:
    /// the same cached paint reports `pending` while its refresh is parked and
    /// `failed` once that refresh concludes unsuccessfully, with the last
    /// successful load time still named.
    func testCachedDayDistinguishesPendingRefreshFromConcludedFailure() async throws {
        let repository = try await makeRepository()
        var now = referenceInstant
        let seeded = DashboardViewModel(repository: repository, userID: account, dateProvider: { now })
        await seeded.load()
        let successfulTime = try XCTUnwrap(seeded.lastLoadedAt)

        now = now.addingTimeInterval(7_200)
        let restarted = DashboardViewModel(
            repository: try await makeRepository(), userID: account, dateProvider: { now }
        )
        // The fresh read parks and then FAILS, so both states are observable.
        StubTransport.respond(
            "meal_logs", .init(status: 500, body: "{\"message\":\"permission denied\"}", hold: true)
        )
        let load = Task { await restarted.load() }
        await waitFor("the cached pre-paint is on screen with the refresh parked") {
            restarted.snapshot?.readProvenance?.isCached == true
        }
        XCTAssertTrue(restarted.isRefreshingCachedDay, "cached-with-pending-refresh")
        XCTAssertFalse(restarted.isShowingCachedDay, "the in-flight window stays silent")
        XCTAssertEqual(restarted.snapshot?.readProvenance?.outcome, .pending)

        StubTransport.release("meal_logs")
        await load.value

        XCTAssertTrue(restarted.isShowingCachedDay, "cached-after-failure is announced")
        XCTAssertFalse(restarted.isRefreshingCachedDay)
        XCTAssertEqual(restarted.snapshot?.readProvenance?.outcome, .failed)
        XCTAssertEqual(restarted.lastLoadedAt, successfulTime, "the notice names the last successful load")
        XCTAssertEqual(restarted.snapshot?.meals.count, 1, "the last good day stays on screen")
    }

    /// Issue #303 — a cache payload written before the outcome existed still
    /// decodes, and it can never invent a concluded failure.
    func testLegacyProvenanceWithoutAnOutcomeDecodesAsPending() throws {
        let day = DashboardMath.startOfLocalDay(referenceInstant)
        let snapshot = DashboardSnapshot(
            date: day, meals: [],
            goal: nil, readProvenance: DayReadProvenance(isCached: false, loadedAt: referenceInstant)
        )
        var encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        var provenance = try XCTUnwrap(encoded["readProvenance"] as? [String: Any])
        provenance.removeValue(forKey: "outcome")
        encoded["readProvenance"] = provenance
        let decoded = try JSONDecoder().decode(
            DashboardSnapshot.self, from: JSONSerialization.data(withJSONObject: encoded)
        )
        XCTAssertEqual(decoded.readProvenance?.outcome, .pending)
        XCTAssertEqual(decoded.readProvenance?.loadedAt, referenceInstant, "the legacy success time survives")
        XCTAssertFalse(decoded.cachedCopy.readProvenance?.outcome == .failed)
    }

    private func failDayRead() {
        StubTransport.respond("meal_logs", .init(status: 500, body: "{\"message\":\"permission denied\"}"))
    }

    /// Bounded state wait for the in-flight window: never a fixed sleep — it
    /// pumps until the state holds (or the deadline expires and fails).
    private func waitFor(_ message: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), message)
    }

    private var mealLogs: String {
        """
        [{"id":"48484848-4848-4848-8848-484848484848","eaten_at":"2026-09-05T03:30:00Z",\
        "meal_type":"lunch","source":"manual","image_path":null}]
        """
    }

    private func makeRepository() async throws -> LocalFirstDashboardRepository {
        StubTransport.respond("meal_logs", .init(body: mealLogs))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        configuration.urlCache = nil
        let client = SupabaseClient(
            supabaseURL: try XCTUnwrap(URL(string: "https://day-composition.supabase.test")),
            supabaseKey: "stub-anon-key",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: StubSessionStorage(userID: account, expiresAt: Date().addingTimeInterval(3_600)),
                    storageKey: "sb-stub-auth-token", autoRefreshToken: false
                ),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
        _ = try await client.auth.session
        let database = LocalDataStore.storeURL(root: directory, accountID: account)
        return LocalFirstDashboardRepository(
            remote: SupabaseDashboardRepository(client: client),
            store: try LocalDataStore(databaseURL: database),
            snapshotCache: try LocalSnapshotCache(databaseURL: database)
        )
    }
}

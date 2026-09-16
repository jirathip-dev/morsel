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
        XCTAssertNil(model.lastLoadedAt, "a legacy cache without provenance must not invent a time")
    }

    private func failDayRead() {
        StubTransport.respond("meal_logs", .init(status: 500, body: "{\"message\":\"permission denied\"}"))
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

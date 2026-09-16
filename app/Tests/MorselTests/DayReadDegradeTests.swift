import Supabase
import XCTest
@testable import Morsel

// Issue #258 — the app-side half of the day read. `SupabaseDashboardRepository
// .loadToday` used to propagate a `meal_items` failure, so the local-first
// facade served the cached day and the Today screen painted it as current:
// a failed read was indistinguishable from "those meals don't exist".
//
// These tests drive the REAL read path through the controlled transport and
// assert the two honest outcomes:
// - the read DEGRADES: every meal still returns, flagged `itemsRead`
//   `.incomplete`, and one unreadable row flags only the meal that owns it;
// - a FAILED refresh keeps the cached day on screen but marks it stale with
//   the last successful load time, and a retry clears the mark.

@MainActor
final class DayReadDegradeTests: XCTestCase {
    private let account = UUID(uuidString: "44444444-4444-4444-8444-444444444444") ?? UUID()
    private let lunchID = "55555555-5555-4555-8555-555555555555"
    private let dinnerID = "66666666-6666-4666-8666-666666666666"
    private let referenceInstant = ISO8601DateFormatter().date(from: "2026-09-05T04:00:00Z") ?? Date()

    override func setUp() {
        super.setUp()
        StubTransport.reset()
    }

    override func tearDown() {
        StubTransport.release()
        StubTransport.reset()
        super.tearDown()
    }

    // MARK: - The read degrades (AC1/AC2)

    func testFailingItemReadDegradesTheDayInsteadOfAbortingIt() async throws {
        StubTransport.respond("meal_logs", .init(body: mealLogsBody()))
        StubTransport.respond("meal_items", .init(status: 500, body: "{\"message\":\"permission denied\"}"))

        let snapshot = try await makeRepository().loadToday(userID: account, date: referenceInstant)

        XCTAssertEqual(snapshot.meals.map(\.mealLogID.uuidString), [lunchID, dinnerID])
        XCTAssertEqual(snapshot.meals.compactMap(\.itemsRead), [.incomplete, .incomplete])
        XCTAssertTrue(snapshot.meals.allSatisfy(\.items.isEmpty))
    }

    func testOneUnreadableItemRowFlagsOnlyItsOwnMeal() async throws {
        StubTransport.respond("meal_logs", .init(body: mealLogsBody()))
        StubTransport.respond("meal_items", .init(body: itemRowsBody([
            ItemRow(id: "77777777-7777-4777-8777-777777777777", meal: lunchID, name: "jasmine rice"),
            ItemRow(id: "88888888-8888-4888-8888-888888888888", meal: dinnerID, unit: "furlongs",
                    name: "mystery stew"),
            ItemRow(id: "99999999-9999-4999-8999-999999999999", meal: dinnerID, name: "salad")
        ])))

        let snapshot = try await makeRepository().loadToday(userID: account, date: referenceInstant)

        XCTAssertEqual(snapshot.meals.compactMap(\.itemsRead), [.complete, .incomplete])
        XCTAssertEqual(snapshot.meals.first?.items.map(\.name), ["jasmine rice"])
        // The readable row of the degraded meal survives; only the bad row is lost.
        XCTAssertEqual(snapshot.meals.last?.items.map(\.name), ["salad"])
    }

    func testUnattributableItemFlagsEveryMealWithoutLosingReadableRows() async throws {
        StubTransport.respond("meal_logs", .init(body: mealLogsBody()))
        StubTransport.respond("meal_items", .init(body: itemRowsBody([
            ItemRow(id: "77777777-7777-4777-8777-777777777777", meal: lunchID, name: "jasmine rice"),
            ItemRow(id: "88888888-8888-4888-8888-888888888888", meal: UUID().uuidString, name: "unknown meal"),
            ItemRow(id: "99999999-9999-4999-8999-999999999999", meal: dinnerID, name: "salad")
        ])))
        let snapshot = try await makeRepository().loadToday(userID: account, date: referenceInstant)
        XCTAssertEqual(snapshot.meals.compactMap(\.itemsRead), [.incomplete, .incomplete])
        XCTAssertEqual(snapshot.meals.map { $0.items.map(\.name) }, [["jasmine rice"], ["salad"]])
    }

    func testHealthyReadMarksEveryMealComplete() async throws {
        StubTransport.respond("meal_logs", .init(body: mealLogsBody()))
        StubTransport.respond("meal_items", .init(body: itemRowsBody([
            ItemRow(id: "77777777-7777-4777-8777-777777777777", meal: lunchID, name: "jasmine rice"),
            ItemRow(id: "99999999-9999-4999-8999-999999999999", meal: dinnerID, name: "salad")
        ])))

        let snapshot = try await makeRepository().loadToday(userID: account, date: referenceInstant)

        XCTAssertEqual(snapshot.meals.compactMap(\.itemsRead), [.complete, .complete])
        XCTAssertEqual(snapshot.meals.map { $0.items.count }, [1, 1])
    }

    func testCachedSnapshotsKeepTheMarkerAndOldCachesStillDecode() throws {
        let meal = MealRecord(
            mealLogID: try XCTUnwrap(UUID(uuidString: dinnerID)),
            mealType: .dinner,
            eatenAt: referenceInstant,
            source: .manual,
            items: [],
            itemsRead: .incomplete
        )
        let snapshot = DashboardSnapshot(date: referenceInstant, meals: [meal], goal: nil)
        let roundTripped = try JSONDecoder().decode(
            DashboardSnapshot.self, from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(roundTripped, snapshot, "the cached copy keeps the completeness marker")

        // A cache written before #258 carries no marker key at all.
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        var meals = try XCTUnwrap(encoded["meals"] as? [[String: Any]])
        meals[0].removeValue(forKey: "itemsRead")
        var legacy = encoded
        legacy["meals"] = meals
        let decoded = try JSONDecoder().decode(
            DashboardSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertNil(decoded.meals.first?.itemsRead, "an old cached day decodes as unknown, not complete")
    }

    // MARK: - A failed refresh is not presented as current (AC3)

    func testFailedRefreshLabelsTheCachedDayAndRetryClearsIt() async throws {
        let clock = referenceInstant
        let repository = FlippableDayRepository(snapshot: daySnapshot())
        var now = clock
        let viewModel = DashboardViewModel(
            repository: repository, userID: account, dateProvider: { now }
        )

        // The cached day is painted first and the fresh read fails: the day
        // stays visible, labelled cached, with no successful load to name yet.
        repository.fails = true
        await viewModel.load()
        XCTAssertEqual(viewModel.snapshot?.meals.count, 1, "the cached day is still shown")
        XCTAssertTrue(viewModel.isShowingCachedDay)
        XCTAssertNil(viewModel.lastLoadedAt)
        XCTAssertNotNil(viewModel.errorMessage)

        // A successful refresh is current again and stamps its time.
        repository.fails = false
        now = clock.addingTimeInterval(3_600)
        await viewModel.load()
        XCTAssertFalse(viewModel.isShowingCachedDay)
        XCTAssertEqual(viewModel.lastLoadedAt, now)
        XCTAssertNil(viewModel.errorMessage)

        // A later failure keeps the values but marks them cached with the
        // last successful time — the user can see the day is not current.
        repository.fails = true
        await viewModel.load()
        XCTAssertEqual(viewModel.snapshot?.meals.count, 1)
        XCTAssertTrue(viewModel.isShowingCachedDay)
        XCTAssertEqual(viewModel.lastLoadedAt, now)

        // The retry affordance recovers the current state.
        repository.fails = false
        await viewModel.load()
        XCTAssertFalse(viewModel.isShowingCachedDay)
    }

    func testDegradedReadReportsTheIncompleteMealCountForTheNotice() async throws {
        StubTransport.respond("meal_logs", .init(body: mealLogsBody()))
        StubTransport.respond("meal_items", .init(status: 500, body: "{\"message\":\"permission denied\"}"))
        let viewModel = DashboardViewModel(
            repository: try await makeRepository(), userID: account, dateProvider: { self.referenceInstant }
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.incompleteMealCount, 2, "the notice counts the unread meals")
        XCTAssertFalse(viewModel.isShowingCachedDay, "a degraded read is not a cached day")
    }

    // MARK: - Fixtures

    private func daySnapshot() -> DashboardSnapshot {
        let meal = MealRecord(
            mealLogID: UUID(),
            mealType: .dinner,
            eatenAt: referenceInstant,
            source: .manual,
            items: [
                MealItem(
                    itemID: UUID(), name: "salad", quantity: 1, unit: .serving,
                    caloriesKcal: 180, proteinG: 6, carbsG: 12, fatG: 9,
                    fiberG: nil, sugarG: nil, confidence: nil, notes: nil
                )
            ]
        )
        return DashboardSnapshot(date: DashboardMath.startOfLocalDay(referenceInstant), meals: [meal], goal: nil)
    }

    private func mealLogsBody() -> String {
        """
        [{"id":"\(lunchID)","eaten_at":"2026-09-05T03:30:00Z","meal_type":"lunch",\
        "source":"manual","image_path":null},
        {"id":"\(dinnerID)","eaten_at":"2026-09-05T12:00:00Z","meal_type":"dinner",\
        "source":"manual","image_path":null}]
        """
    }

    /// One stubbed `meal_items` row; `unit` is the mis-typed field a corrupt
    /// row carries.
    private struct ItemRow {
        let id: String
        let meal: String
        var unit = "serving"
        let name: String
    }

    private func itemRowsBody(_ rows: [ItemRow]) -> String {
        let objects = rows.map { row in
            """
            {"id":"\(row.id)","meal_log_id":"\(row.meal)","name":"\(row.name)","quantity":1,\
            "unit":"\(row.unit)","calories_kcal":220,"protein_g":null,"carbs_g":null,"fat_g":null,\
            "fiber_g":null,"sugar_g":null,"barcode":null,"food_ref_id":null,"confidence":null,\
            "source_notes":null,"menu_group_id":null,"menu_name":null,"artwork_id":null}
            """
        }
        return "[" + objects.joined(separator: ",") + "]"
    }

    private func makeRepository() async throws -> SupabaseDashboardRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        configuration.urlCache = nil
        let client = SupabaseClient(
            supabaseURL: try XCTUnwrap(URL(string: "https://day-read.supabase.test")),
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
        return SupabaseDashboardRepository(client: client)
    }
}

/// The AC3 fixture: a day read that can be flipped to fail AFTER a successful
/// load, with the last good day still available as the cached copy.
private final class FlippableDayRepository: DashboardRepository {
    private let snapshot: DashboardSnapshot
    var fails = false

    init(snapshot: DashboardSnapshot) {
        self.snapshot = snapshot
    }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        guard !fails else {
            throw MorselError.requestFailed(503, "day read unavailable")
        }
        return snapshot
    }

    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        throw MorselError.requestFailed(503, "day read unavailable")
    }

    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? {
        snapshot
    }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        throw MorselError.requestFailed(503, "day read unavailable")
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        throw MorselError.requestFailed(503, "goals read unavailable")
    }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
}

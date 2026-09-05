import XCTest
@testable import Morsel

// Issue #121 — APP day-boundary discrimination tests (AC4). Days must be the
// USER'S LOCAL days, not UTC days. Every fixture instant is an absolute UTC
// instant with its Asia/Bangkok (+07) wall meaning in comments; expected
// instants are computed against an explicit Asia/Bangkok calendar so the
// tests discriminate UTC-vs-local bucketing. The simulator/device zone MUST
// be +07 (this host's default; evidence runs add SIMCTL_CHILD_TZ=Asia/Bangkok):
// with a UTC device zone the code under test cannot tell local days from UTC
// days and these assertions fail loudly instead of silently passing.
@MainActor
final class LocalDayBucketTests: XCTestCase {
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-local-day-tests-\(UUID().uuidString)", isDirectory: true)

    /// Explicit Asia/Bangkok (+07) calendar used ONLY to compute expected
    /// instants — the code under test resolves its own device calendar.
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

    /// ISO-8601 instant helper (fractional-tolerant, like MorselDate).
    private func iso(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
            ?? Date(timeIntervalSince1970: 0)
    }

    private func bangkokStartOfDay(_ date: Date) -> Date {
        bangkok.startOfDay(for: date)
    }

    // MARK: - Fixture instants (UTC instants; +07 wall time in comments)

    /// 2026-09-01 00:30 +07 = 2026-08-31 17:30Z — a meal AFTER the +07
    /// midnight: UTC bucketing puts it on Aug 31, local on Sep 1.
    private var justAfterSep1Midnight: Date { iso("2026-08-31T17:30:00Z") }
    /// 2026-09-01 06:30 +07 = 2026-08-31 23:30Z — the early-morning case UTC
    /// bucketing puts on Aug 31 (a "06:30" breakfast under Monday's date).
    private var earlyBreakfastSep1: Date { iso("2026-08-31T23:30:00Z") }
    /// 2026-08-31 23:30 +07 = 2026-08-31 16:30Z — a LATE dinner that is fully
    /// inside the local Aug 31 day and must stay there under local bucketing.
    private var lateDinnerAug31: Date { iso("2026-08-31T16:30:00Z") }
    /// 2026-09-01 11:00 +07 = 04:00Z — mid-morning instant on Sep 1.
    private var sep1LateMorning: Date { iso("2026-09-01T04:00:00Z") }
    /// 2026-08-31 11:00 +07 = 04:00Z — mid-morning instant on Aug 31.
    private var aug31LateMorning: Date { iso("2026-08-31T04:00:00Z") }
    /// 2026-09-05 11:00 +07 = 04:00Z — History "today" for the 7-day window.
    private var sep5LateMorning: Date { iso("2026-09-05T04:00:00Z") }

    private func queuedMeal(eatenAt: Date, name: String, type: MealType) -> QueuedMeal {
        QueuedMealFactory.make(
            draft: MealDraft(
                mealType: type,
                eatenAt: eatenAt,
                notes: nil,
                items: [MealItemDraft(name: name, quantity: 1, unit: .serving,
                                      caloriesKcal: 300, proteinG: 6)]
            ),
            photo: nil,
            mealID: UUID(),
            now: eatenAt
        )
    }

    // MARK: - (a) Today: meals around the +07 midnight land on LOCAL day rows

    func testMealJustAfterPlus07MidnightLandsOnSep1RowNotAug31() async throws {
        let store = try LocalDataStore(databaseURL: databaseURL)
        let cache = try LocalSnapshotCache(databaseURL: databaseURL)
        try store.enqueueMeal(queuedMeal(eatenAt: justAfterSep1Midnight, name: "late noodles", type: .dinner))
        let remote = MockDashboardRepository(
            snapshot: DashboardSnapshot(date: sep1LateMorning, meals: [], goal: nil)
        )
        let repository = LocalFirstDashboardRepository(remote: remote, store: store, snapshotCache: cache)

        // Sep 1 in +07: 00:30 +07 Sep 1 belongs to the Sep 1 row.
        let sep1 = try await repository.loadToday(userID: account, date: sep1LateMorning)
        XCTAssertEqual(sep1.meals.count, 1, "00:30 +07 Sep 1 must land on the Sep 1 row")
        XCTAssertEqual(sep1.meals.first?.eatenAt, justAfterSep1Midnight)

        // Aug 31 in +07: the same meal is Sep 1 local — never an Aug 31 row.
        let aug31 = try await repository.loadToday(userID: account, date: aug31LateMorning)
        XCTAssertTrue(aug31.meals.isEmpty, "00:30 +07 Sep 1 must NOT land on the Aug 31 row")
    }

    func testEarlyBreakfastPlus07LandsOnSep1RowNotAug31() async throws {
        let store = try LocalDataStore(databaseURL: databaseURL)
        let cache = try LocalSnapshotCache(databaseURL: databaseURL)
        try store.enqueueMeal(queuedMeal(eatenAt: earlyBreakfastSep1, name: "morning rice", type: .breakfast))
        let remote = MockDashboardRepository(
            snapshot: DashboardSnapshot(date: sep1LateMorning, meals: [], goal: nil)
        )
        let repository = LocalFirstDashboardRepository(remote: remote, store: store, snapshotCache: cache)

        let sep1 = try await repository.loadToday(userID: account, date: sep1LateMorning)
        XCTAssertEqual(sep1.meals.count, 1, "a 06:30 +07 Sep 1 breakfast must land on the Sep 1 row")
        XCTAssertEqual(sep1.meals.first?.eatenAt, earlyBreakfastSep1)
    }

    func testLateDinnerFullyInsideAug31LocalDayStaysOnAug31() async throws {
        let store = try LocalDataStore(databaseURL: databaseURL)
        let cache = try LocalSnapshotCache(databaseURL: databaseURL)
        try store.enqueueMeal(queuedMeal(eatenAt: lateDinnerAug31, name: "late noodles", type: .dinner))
        let remote = MockDashboardRepository(
            snapshot: DashboardSnapshot(date: sep1LateMorning, meals: [], goal: nil)
        )
        let repository = LocalFirstDashboardRepository(remote: remote, store: store, snapshotCache: cache)

        // 23:30 +07 Aug 31 is INSIDE the local Aug 31 day → stays on Aug 31.
        let aug31 = try await repository.loadToday(userID: account, date: aug31LateMorning)
        XCTAssertEqual(aug31.meals.count, 1)
        let sep1 = try await repository.loadToday(userID: account, date: sep1LateMorning)
        XCTAssertTrue(sep1.meals.isEmpty)
    }

    // MARK: - (b) History: completed-day math + 7-day windows use local days

    func testHistoryCompletedDaysTreatBoundaryInstantsAsLocalDays() {
        // Both instants are Sep 1 00:30 +07 and 10:30 +07 — ONE local day.
        let days = [
            HistoryDay(date: justAfterSep1Midnight, eatenKcal: 500, logged: true),
            HistoryDay(date: iso("2026-09-01T03:30:00Z"), eatenKcal: 300, logged: true)
        ]
        // Sep 1 11:00 +07 — both rows are TODAY (not completed).
        XCTAssertEqual(DashboardMath.daysLogged(days, today: sep1LateMorning), 0)
        XCTAssertEqual(DashboardMath.completedLoggedDays(days, today: sep1LateMorning).count, 0)
        // The one local day (Sep 1) is logged, so the streak ends today at 1.
        XCTAssertEqual(DashboardMath.loggingStreak(days, today: sep1LateMorning), 1)
        XCTAssertNil(DashboardMath.averageKcal(days, today: sep1LateMorning))
    }

    func testHistoryViewModelWindowIsSevenLocalDays() async throws {
        // Seed rows at LOCAL (Bangkok) day starts for Sep 5 .. Aug 30 and ask
        // for the 7-day window ending Sep 5 11:00 +07 (04:00Z).
        let todayLocalStart = bangkokStartOfDay(sep5LateMorning)
        let localStarts = (0...6).compactMap { offset -> Date in
            bangkok.date(byAdding: .day, value: -offset, to: todayLocalStart) ?? todayLocalStart
        }
        let rows = localStarts.map { start in
            HistoryDay(date: start, eatenKcal: 1_000, logged: true)
        }
        let repository = MockDashboardRepository(
            snapshot: DashboardSnapshot(date: sep5LateMorning, meals: [], goal: nil)
        )
        repository.seed(history: HistoryOverview(days: rows, goal: nil, weightTrend: []))

        let fixedToday = sep5LateMorning
        let viewModel = HistoryViewModel(
            repository: repository,
            userID: account,
            dateProvider: { fixedToday }
        )
        await viewModel.load()

        XCTAssertEqual(viewModel.chartDays.count, 7)
        XCTAssertEqual(
            viewModel.chartDays.map(\.date), localStarts,
            "the 7-day History window must be the seven LOCAL days ending today"
        )
    }

    // MARK: - (c) Energy: the local day row is today's row

    func testEnergyLogJustAfterPlus07MidnightBucketsToLocalSep1Row() async throws {
        let health = try LocalHealthStore(databaseURL: databaseURL)

        // The importer hands the store a per-day aggregate; the store must
        // bucket the burned instant onto the LOCAL day row.
        try await health.upsertEnergyBurned([
            EnergyBurnedLog(burnedAt: justAfterSep1Midnight, activeKilocalories: 420)
        ])

        let expected = bangkokStartOfDay(justAfterSep1Midnight) // Sep 1 00:00 +07
        let dirty = try health.dirtyEnergyDays()
        XCTAssertEqual(dirty.count, 1)
        XCTAssertEqual(
            dirty.first?.burnedAt, expected,
            "00:30 +07 energy must land on the Sep 1 local-day row"
        )
        XCTAssertEqual(dirty.first?.activeKilocalories, 420)
    }

    func testDirtyLocalEnergyDayFeedsTodaySnapshot() async throws {
        let health = try LocalHealthStore(databaseURL: databaseURL)
        try await health.upsertEnergyBurned([
            EnergyBurnedLog(burnedAt: justAfterSep1Midnight, activeKilocalories: 420)
        ])
        let remote = MockDashboardRepository(
            snapshot: DashboardSnapshot(
                date: sep1LateMorning, meals: [], goal: nil, activeEnergyBurned: 0
            )
        )
        let repository = LocalFirstDashboardRepository(
            remote: remote,
            store: try LocalDataStore(databaseURL: databaseURL),
            snapshotCache: try LocalSnapshotCache(databaseURL: databaseURL),
            healthStore: health
        )

        let snapshot = try await repository.loadToday(userID: account, date: sep1LateMorning)

        XCTAssertEqual(
            snapshot.activeEnergyBurned, 420,
            "the local Sep 1 dirty energy row must feed the Sep 1 'today' total"
        )
    }
}

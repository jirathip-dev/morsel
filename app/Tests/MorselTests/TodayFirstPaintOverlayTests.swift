import XCTest
@testable import Morsel

// Issue #181 — AC1/AC2: the cached Today first paint must carry the SAME
// durable overlays an authoritative refresh does (each queued meal exactly
// once, with its real pending/needs-attention state), and a queued-only
// startup with no dashboard cache must still paint its rows without inventing
// a goal or any remote value. Every case restarts the store/repository/model
// over the same SQLite file and blocks the network.
@MainActor
final class TodayFirstPaintOverlayTests: XCTestCase {
    private let stores = FirstPaintStores()
    /// 2026-09-05T00:00:00Z: the device-local day under test starts at
    /// 2026-09-04T17:00:00Z under the fleet's Asia/Bangkok (+07) zone.
    private let reference = Date(timeIntervalSince1970: 1_788_566_400)

    private var day: Date { DashboardMath.startOfLocalDay(reference) }
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3_600) }

    private func blockedRemote() -> FirstPaintRemote {
        let remote = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        remote.isBlocked = true
        return remote
    }

    override func setUpWithError() throws {
        try stores.createRoot()
    }

    override func tearDownWithError() throws {
        stores.removeRoot()
    }

    func testRelaunchFirstPaintMergesQueuedMealsOnceWithTheirTrueState() async throws {
        let queued = try await stores.queuedFirstPaintDay(day: day, reference: reference)
        let remoteMealID = try XCTUnwrap(queued.remoteMealID)
        let model = DashboardViewModel(
            repository: queued.repository, userID: stores.account, dateProvider: { self.reference }
        )
        let recorder = FirstPaintRecorder(model: model)
        await model.load()
        recorder.stop()

        let firstPaint = try XCTUnwrap(recorder.paints.first, "the restarted model must paint the cached day")
        XCTAssertEqual(firstPaint.meals.count, 3, "one synced row plus BOTH queued rows")
        XCTAssertEqual(firstPaint.meals.filter { $0.mealLogID == queued.photoMealID }.count, 1)
        XCTAssertEqual(firstPaint.meals.filter { $0.mealLogID == queued.refusedMealID }.count, 1)
        XCTAssertEqual(firstPaint.meals.filter { $0.mealLogID == remoteMealID }.count, 1)

        let photoRow = firstPaint.meals.first { $0.mealLogID == queued.photoMealID }
        let refusedRow = firstPaint.meals.first { $0.mealLogID == queued.refusedMealID }
        XCTAssertEqual(photoRow?.syncState, .pending)
        XCTAssertEqual(photoRow?.syncState.rowCopy ?? "", "pending sync")
        XCTAssertEqual(refusedRow?.syncState, .needsAttention)
        XCTAssertEqual(refusedRow?.syncState.rowCopy ?? "", "needs attention")
        XCTAssertEqual(photoRow?.imagePath, queued.photoPath,
                       "the deterministic queued photo path paints immediately")
        XCTAssertEqual(firstPaint.readProvenance?.isCached, true, "a queued overlay paint is a cached paint")

        XCTAssertEqual(model.snapshot?.meals.count, 3, "the blocked refresh keeps the rows and never duplicates")
        XCTAssertNotNil(model.lastLoadedAt, "the cached day keeps its own authoritative read time")
        XCTAssertTrue(queued.remote.isBlocked, "the day was read with every remote call blocked")
        XCTAssertEqual(queued.remote.dayReads, 1, "the blocked read ran and the painted rows still held")
        XCTAssertEqual(try queued.instances.store.queuedMeals().count, 2, "a paint never releases the outbox")
    }

    func testFirstPublishedPaintIsTheCachedDayAlreadyCarryingQueuedRows() async throws {
        let queued = try await stores.queuedFirstPaintDay(day: day, reference: reference)
        let owner = TodayRefreshOwner(repository: queued.repository, userID: stores.account)
        var events: [TodayRefreshOwner.Event] = []
        let flight = owner.start(
            date: day, needsCache: true, invalidating: false, superseding: false
        ) { events.append($0) }
        await owner.wait(for: flight)

        let first = try XCTUnwrap(events.first)
        let painted = try XCTUnwrap(
            FirstPaintFixture.cachedPaint(first), "the FIRST published paint must be the cached day"
        )
        XCTAssertEqual(painted.meals.count, 3, "the cached paint already carries both queued rows")
        XCTAssertEqual(painted.readProvenance?.isCached, true)
        XCTAssertEqual(Set(painted.meals.map(\.mealLogID)),
                       [queued.photoMealID, queued.refusedMealID, try XCTUnwrap(queued.remoteMealID)])
        XCTAssertEqual(queued.remote.dayReads, 1, "the only remote read was blocked and the paint held")
        XCTAssertTrue(queued.remote.isBlocked)
    }

    func testQueuedOnlyStartupWithoutDashboardCachePaintsRowsWithoutFabricatedValues() async throws {
        let queued = try await stores.queuedFirstPaintDay(
            day: day, reference: reference, cachedDay: false
        )
        XCTAssertNil(queued.remoteMealID, "no authoritative read ever seeded this day")
        let model = DashboardViewModel(
            repository: queued.repository, userID: stores.account, dateProvider: { self.reference }
        )
        await model.load()

        let painted = try XCTUnwrap(model.snapshot, "a queued-only startup paints its rows instead of nothing")
        XCTAssertEqual(painted.date, day)
        XCTAssertEqual(Set(painted.meals.map(\.mealLogID)), [queued.photoMealID, queued.refusedMealID])
        XCTAssertEqual(painted.meals.first { $0.mealLogID == queued.photoMealID }?.syncState, .pending)
        XCTAssertEqual(painted.meals.first { $0.mealLogID == queued.refusedMealID }?.syncState,
                       .needsAttention)
        XCTAssertNil(painted.goal, "no cached day means no goal: never a fabricated target")
        XCTAssertTrue(painted.weightTrend.isEmpty, "no local Health rows and no remote read: an empty trend")
        XCTAssertEqual(painted.activeEnergyBurned, 0, "no dirty local day and no remote read: no invented burn")
        XCTAssertTrue(model.isShowingCachedDay)
        XCTAssertNil(model.lastLoadedAt, "a local-only paint stamps no success time")
        XCTAssertEqual(queued.remote.dayReads, 1)
    }

    func testQueuedOnlyStartupPaintsOnlyTheSelectedDaysOwnRows() async throws {
        let mine = try stores.instances()
        let theirs = try stores.instances(for: stores.otherAccount)
        let myRepository = stores.makeRepository(remote: blockedRemote(), instances: mine)
        let theirRepository = stores.makeRepository(remote: blockedRemote(), instances: theirs)
        let todayID = try await myRepository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(9)), photo: nil
        )
        _ = try await myRepository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(-2)), photo: nil
        )
        _ = try await theirRepository.logMeal(
            userID: stores.otherAccount, draft: FirstPaintFixture.draft(eatenAt: at(9)), photo: nil
        )

        let model = DashboardViewModel(
            repository: stores.makeRepository(remote: blockedRemote(), instances: try stores.instances()),
            userID: stores.account, dateProvider: { self.reference }
        )
        await model.load()

        let painted = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(painted.date, day)
        XCTAssertEqual(painted.meals.map(\.mealLogID), [todayID],
                       "only the selected device-local day's queued row paints: never another day or account")
    }
}

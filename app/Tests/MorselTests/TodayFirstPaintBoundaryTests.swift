import XCTest
@testable import Morsel

// Issue #181 — AC3/AC4/AC5: the cached first paint applies the EXISTING local
// Health rules (whole-second identity, trailing 30-day window, dirty-day max)
// to unsynced rows only, a later authoritative read reconciles queued rows by
// identity without duplicating them, and every boundary is the DEVICE-local
// day. Zone precondition: this host runs Asia/Bangkok (+07), like
// LocalDayBucketTests; evidence runs set SIMCTL_CHILD_TZ=Asia/Bangkok.
@MainActor
final class TodayFirstPaintBoundaryTests: XCTestCase {
    private let stores = FirstPaintStores()
    /// 2026-09-05T00:00:00Z: the device-local day under test starts at
    /// 2026-09-04T17:00:00Z under +07.
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

    func testFirstPaintAppliesTheWeightWindowAndWholeSecondDedupRules() async throws {
        let opened = try stores.instances()
        let wholeSecond = at(-2 * 24).timeIntervalSince1970
        let inWindow = at(-4 * 24 + 9)
        let outsideWindow = at(-40 * 24 + 9)
        // The remote row lost its fraction in the ISO round-trip; the local
        // Health sample keeps sub-second time inside the SAME whole second.
        let server = FirstPaintRemote(snapshot: DashboardSnapshot(
            date: day, meals: [FirstPaintFixture.meal(id: UUID(), at: at(8))], goal: nil,
            weightTrend: [WeightTrendPoint(date: Date(timeIntervalSince1970: wholeSecond), kilograms: 80)]
        ))
        _ = try await stores.makeRepository(remote: server, instances: opened)
            .loadToday(userID: stores.account, date: reference)
        try await opened.health.upsert([
            WeightLog(measuredAt: inWindow, kilograms: 79.5),
            WeightLog(measuredAt: Date(timeIntervalSince1970: wholeSecond + 0.4), kilograms: 81.25),
            WeightLog(measuredAt: outsideWindow, kilograms: 92)
        ])

        let merged = try await stores
            .makeRepository(remote: blockedRemote(), instances: try stores.instances())
            .cachedToday(userID: stores.account, date: reference)
        let painted = try XCTUnwrap(merged, "the first paint merges the unsynced Health rows")

        let trend = painted.weightTrend
        XCTAssertEqual(trend.count, 2, "one point per whole second inside the trailing window")
        XCTAssertTrue(trend.contains { $0.kilograms == 79.5 }, "the in-window unsynced sample paints")
        XCTAssertEqual(
            trend.first { $0.date.timeIntervalSince1970.rounded() == wholeSecond.rounded() }?.kilograms,
            81.25, "the newer local sample replaces the remote point at the same whole second"
        )
        XCTAssertFalse(trend.contains { $0.kilograms == 92 },
                       "a sample outside the trailing 30-day window never paints")
    }

    func testFirstPaintEnergyKeepsTheLargerDirtyLocalTotalForTheSelectedDayOnly() async throws {
        let opened = try stores.instances()
        let tomorrow = day.addingTimeInterval(86_400)
        let server = FirstPaintRemote(snapshot: DashboardSnapshot(
            date: day, meals: [], goal: nil, activeEnergyBurned: 200
        ))
        _ = try await stores.makeRepository(remote: server, instances: opened)
            .loadToday(userID: stores.account, date: reference)
        server.snapshot = DashboardSnapshot(date: tomorrow, meals: [], goal: nil, activeEnergyBurned: 300)
        _ = try await stores.makeRepository(remote: server, instances: opened)
            .loadToday(userID: stores.account, date: tomorrow)
        try await opened.health.upsertEnergyBurned([
            EnergyBurnedLog(burnedAt: day, activeKilocalories: 480),
            EnergyBurnedLog(burnedAt: tomorrow, activeKilocalories: 150),
            EnergyBurnedLog(burnedAt: day.addingTimeInterval(-86_400), activeKilocalories: 900)
        ])

        let repository = stores.makeRepository(remote: blockedRemote(), instances: try stores.instances())
        let selectedPaint = try await repository.cachedToday(userID: stores.account, date: reference)
        let selected = try XCTUnwrap(selectedPaint)
        XCTAssertEqual(selected.activeEnergyBurned, 480,
                       "the dirty local day total is fresher than the last remote total")
        let nextDayPaint = try await repository.cachedToday(userID: stores.account, date: tomorrow)
        let nextDay = try XCTUnwrap(nextDayPaint)
        XCTAssertEqual(nextDay.activeEnergyBurned, 300,
                       "a dirty row below the authoritative total never lowers it")
    }

    func testAuthoritativeRefreshReconcilesByIdentityAndKeepsQueuedPhotoUntilReadback() async throws {
        let queued = try await stores.queuedFirstPaintDay(day: day, reference: reference)
        let model = DashboardViewModel(
            repository: queued.repository, userID: stores.account, dateProvider: { self.reference }
        )
        let recorder = FirstPaintRecorder(model: model)
        await model.load()
        recorder.stop()

        let firstPaint = try XCTUnwrap(recorder.paints.first)
        XCTAssertEqual(firstPaint.meals.first { $0.mealLogID == queued.photoMealID }?.imagePath,
                       queued.photoPath, "the first paint already serves the queued photo row")
        let firstPaintBytes = try await queued.repository.loadMealImage(
            userID: stores.account, path: queued.photoPath
        )
        XCTAssertEqual(firstPaintBytes, queued.photoBytes, "the queued photo bytes serve the first paint")

        // The later authoritative read returns the SAME client id (the server
        // takes it as the primary key) plus another meal.
        let secondMealID = UUID()
        queued.remote.isBlocked = false
        queued.remote.snapshot = DashboardSnapshot(date: day, meals: [
            FirstPaintFixture.meal(id: queued.photoMealID, at: at(12), name: "server copy",
                                   imagePath: queued.photoPath),
            FirstPaintFixture.meal(id: secondMealID, at: at(13))
        ], goal: nil)
        let refreshed = try await queued.repository.loadToday(userID: stores.account, date: reference)

        XCTAssertEqual(refreshed.meals.filter { $0.mealLogID == queued.photoMealID }.count, 1,
                       "identity reconciliation never duplicates a queued row")
        XCTAssertEqual(refreshed.meals.first { $0.mealLogID == queued.photoMealID }?.syncState, .synced)
        XCTAssertTrue(refreshed.meals.contains { $0.mealLogID == secondMealID })
        XCTAssertEqual(refreshed.meals.count, 3,
                       "two authoritative rows plus the still-queued refused row, never a duplicate")
        let servedWhileQueued = try await queued.repository.loadMealImage(
            userID: stores.account, path: queued.photoPath
        )
        XCTAssertEqual(servedWhileQueued, queued.photoBytes,
                       "the queued bytes keep serving until reconciliation is durable")

        // The successful readback releases the queued row; the path resolves remotely.
        let writer = CommittingMealWriter()
        let engine = LocalSyncEngine(
            userID: stores.account, store: queued.instances.store, mealRemote: writer
        )
        await engine.runPass()
        XCTAssertNil(try queued.instances.store.queuedMeal(mealID: queued.photoMealID),
                     "the authoritative readback releases the queued row")
        let committedPhoto = writer.committed[queued.photoMealID]?.photo?.data ?? Data()
        XCTAssertEqual(committedPhoto, queued.photoBytes)
        let servedAfterReadback = try await queued.repository.loadMealImage(
            userID: stores.account, path: queued.photoPath
        )
        XCTAssertEqual(servedAfterReadback, queued.remote.remoteImage)
    }

    func testFirstPaintFollowsTheDeviceLocalDayAcrossMidnight() async throws {
        XCTAssertEqual(TimeZone.current.secondsFromGMT(), 7 * 3_600,
                       "run with SIMCTL_CHILD_TZ=Asia/Bangkok: this witness proves local-day bucketing")

        // 2026-09-04T23:30:00Z is 06:30 on the device-local Sep 5 (a UTC read
        // would still call it Sep 4), and 16:59:00Z is 23:59 on Sep 4.
        let utcEvening = Date(timeIntervalSince1970: 1_788_564_600)
        let localDay = DashboardMath.startOfLocalDay(utcEvening)
        XCTAssertEqual(localDay, Date(timeIntervalSince1970: 1_788_541_200), "Sep 5 starts at 17:00Z (+07)")

        let opened = try stores.instances()
        let repository = stores.makeRepository(remote: blockedRemote(), instances: opened)
        let morningID = try await repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: localDay + 6.5 * 3_600),
            photo: nil
        )
        let tonightID = try await repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: localDay + 23.5 * 3_600),
            photo: nil
        )
        let lastNightID = try await repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: localDay - 60), photo: nil
        )

        let restarted = stores.makeRepository(remote: blockedRemote(), instances: try stores.instances())
        let secondOfSep5Paint = try await restarted.cachedToday(userID: stores.account, date: utcEvening)
        let secondOfSep5 = try XCTUnwrap(secondOfSep5Paint)
        XCTAssertEqual(Set(secondOfSep5.meals.map(\.mealLogID)), [morningID, tonightID],
                       "both rows are on the device-local Sep 5: the first paint uses local midnight")
        let previousDayPaint = try await restarted.cachedToday(
            userID: stores.account, date: localDay.addingTimeInterval(-86_400)
        )
        let secondOfSep4 = try XCTUnwrap(previousDayPaint)
        XCTAssertEqual(secondOfSep4.meals.map(\.mealLogID), [lastNightID])
        let nextDayPaint = try await restarted.cachedToday(
            userID: stores.account, date: localDay.addingTimeInterval(86_400)
        )
        XCTAssertNil(nextDayPaint, "a day with no cache and no queued rows paints nothing")
    }
}

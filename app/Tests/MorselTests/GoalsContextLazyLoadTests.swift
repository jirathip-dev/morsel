import XCTest
@testable import Morsel

// Issue #184 — Goals must open WITHOUT the full Today dashboard read: no meal
// photos, no active energy, no 30-day weight trend and no goal row are needed
// to obtain today's calorie total. These tests drive the PRODUCTION
// GoalsEditorViewModel through `GoalsPageRequestSpy` (recording every call,
// with the full read failing loudly) plus parked continuations for the
// held-storage, delayed, midnight-crossing, superseded, cancelled and failing
// cases. A missing total stays pending; it is never presented as a known zero.

class GoalsContextLazyLoadCase: XCTestCase {
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        ) ?? Date(timeIntervalSince1970: 0)
    }

    func manualGoal(updatedAt: Date? = nil) -> StoredDashboardGoal {
        StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70,
            source: .manual, updatedAt: updatedAt
        )
    }

    /// Bounded polling on the main actor: yields until `condition` holds or the
    /// deadline passes. The parked reads never complete on their own, so any
    /// state observed while they are parked is pre-release.
    func waitFor(seconds: TimeInterval = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            await Task.yield()
        }
        return true
    }

    /// Await the model's in-flight narrow read: every late-read assertion is
    /// then deterministic (no sleeps).
    @MainActor
    func settleDayTotal(of viewModel: GoalsEditorViewModel) async throws {
        let task = try XCTUnwrap(viewModel.dayTotalTask, "the narrow day read must have been started")
        await task.value
    }
}

final class GoalsContextLazyLoadTests: GoalsContextLazyLoadCase {
    @MainActor
    private func viewModel(
        spy: GoalsPageRequestSpy, now: @escaping () -> Date = { Date() }
    ) -> GoalsEditorViewModel {
        GoalsEditorViewModel(repository: spy, userID: UUID(), now: now)
    }

    // MARK: - (a) opening Goals is a narrow read, never the full dashboard

    @MainActor
    func testOpeningGoalsReadsTheNarrowLocalDayTotalAndNoFullDashboard() async throws {
        let spy = GoalsPageRequestSpy()
        spy.storedGoal = manualGoal()
        spy.dayTotals = [993]
        let viewModel = viewModel(spy: spy)

        await viewModel.load()
        try await settleDayTotal(of: viewModel)

        XCTAssertEqual(spy.fullDashboardReads, 0, "opening Goals must not run the full Today read")
        XCTAssertFalse(spy.calls.contains("loadToday"), "no full photo/energy/trend/dashboard reload")
        XCTAssertEqual(
            Set(spy.calls).sorted(), ["cachedGoals", "cachedToday", "loadGoalsContext"],
            "exactly the cached first paint + the narrow total + the context"
        )
        XCTAssertEqual(viewModel.calories, "2000.0", "the cached targets still paint")
        XCTAssertEqual(viewModel.sources["calories"], .manual)
        XCTAssertNil(viewModel.errorMessage)

        XCTAssertEqual(viewModel.todayCalories, 993)
        XCTAssertEqual(
            viewModel.whatChangesText,
            "Today: \(MorselFormat.number(993)) eaten · "
                + "\(GoalsEditorViewModel.calorieConsequence(goal: 2_000, eaten: 993))"
        )
    }

    // MARK: - (b) a held local read never gates the page

    @MainActor
    func testHeldLocalReadStillPaintsTargetsAndProfileWithTheTotalPending() async throws {
        let spy = GoalsPageRequestSpy()
        // A current manual row (written after the profile) keeps its own
        // numbers; the profile supplies the read-only provenance line.
        spy.storedGoal = manualGoal(updatedAt: date(2026, 9, 5, 10, 0))
        spy.contextProfile = DashboardProfile(
            sex: .male, ageYears: 30, heightCm: 167, weightKg: 63,
            activityLevel: .active, dietGoal: .lose, goalWeightKg: nil,
            updatedAt: date(2026, 9, 5, 9, 0)
        )
        spy.dayTotals = [1_200]
        spy.holdsStorage = true
        let viewModel = viewModel(spy: spy)

        await viewModel.load()

        let parked = await waitFor { spy.parkedOnStorage }
        XCTAssertTrue(parked, "the narrow read really is parked")
        XCTAssertEqual(viewModel.calories, "2000.0", "held storage cannot stop the targets")
        XCTAssertNotNil(viewModel.profileLine, "held storage cannot stop the profile line")
        XCTAssertNil(viewModel.todayCalories, "a missing total is pending, never a known zero")
        XCTAssertTrue(viewModel.whatChangesText.contains("total pending"))
        XCTAssertFalse(viewModel.whatChangesText.contains("0 eaten"))

        spy.releaseStorage()
        try await settleDayTotal(of: viewModel)
        XCTAssertEqual(viewModel.todayCalories, 1_200, "the late total lands once storage answers")
        XCTAssertTrue(viewModel.whatChangesText.contains("\(MorselFormat.number(1_200)) eaten"))
    }

    // MARK: - (c) late totals: current account/local day only

    @MainActor
    func testDayTotalArrivingAfterMidnightIsDropped() async throws {
        let spy = GoalsPageRequestSpy()
        spy.storedGoal = manualGoal()
        spy.dayTotals = [900]
        spy.holdsStorage = true
        var clock = date(2026, 9, 5, 23, 50)
        let viewModel = viewModel(spy: spy, now: { clock })

        await viewModel.load()
        let parked = await waitFor { spy.parkedOnStorage }
        XCTAssertTrue(parked)

        clock = date(2026, 9, 6, 0, 10)
        spy.releaseStorage()
        try await settleDayTotal(of: viewModel)

        XCTAssertNil(viewModel.todayCalories, "yesterday's total must not paint on the new local day")
        XCTAssertTrue(viewModel.whatChangesText.contains("total pending"))
    }

    @MainActor
    func testSupersededLoadCannotPaintItsStaleTotal() async throws {
        let spy = GoalsPageRequestSpy()
        spy.storedGoal = manualGoal()
        spy.dayTotals = [111, 222]
        spy.holdsStorage = true
        let viewModel = viewModel(spy: spy)

        await viewModel.load()
        let stale = try XCTUnwrap(viewModel.dayTotalTask)
        let parked = await waitFor { spy.parkedOnStorage }
        XCTAssertTrue(parked)

        spy.holdsStorage = false
        await viewModel.load()
        try await settleDayTotal(of: viewModel)
        XCTAssertEqual(viewModel.todayCalories, 222, "the current load's total wins")

        spy.releaseStorage()
        await stale.value
        XCTAssertEqual(viewModel.todayCalories, 222, "a superseded read must not paint over it")
    }

    @MainActor
    func testCancelledLoadNeverPaintsItsLateTotal() async throws {
        let spy = GoalsPageRequestSpy()
        spy.storedGoal = manualGoal()
        spy.dayTotals = [500]
        spy.holdsStorage = true
        spy.holdsContext = true
        let viewModel = viewModel(spy: spy)

        let load = Task { await viewModel.load() }
        let parked = await waitFor { spy.parkedOnStorage && spy.parkedOnContext }
        XCTAssertTrue(parked, "both reads are parked")

        load.cancel()
        spy.releaseContext()
        await load.value
        let late = try XCTUnwrap(viewModel.dayTotalTask)
        XCTAssertEqual(viewModel.calories, "2000.0", "the fetched targets still appear")

        spy.releaseStorage()
        await late.value
        XCTAssertNil(viewModel.todayCalories, "a cancelled load must not leave a late paint")
    }

    @MainActor
    func testUnreadableDayTotalLeavesTheLinePendingAndGoalsEditable() async throws {
        let spy = GoalsPageRequestSpy()
        spy.storedGoal = manualGoal()
        spy.dayTotalError = MorselError.requestFailed(500, "local day cache unreadable")
        let viewModel = viewModel(spy: spy)

        await viewModel.load()
        try await settleDayTotal(of: viewModel)

        XCTAssertNil(viewModel.todayCalories)
        XCTAssertNil(viewModel.errorMessage, "a day-total failure is not a page error")
        XCTAssertTrue(viewModel.whatChangesText.contains("total pending"))

        viewModel.edit("calories", value: "2100")
        let didSave = await viewModel.save()
        XCTAssertTrue(didSave, "goals editing stays available")
        XCTAssertEqual(spy.savedGoal?.calorieTargetKcal, 2_100)
    }

    // MARK: - (d) the late total touches nothing else

    @MainActor
    func testLateTotalLeavesTheSupersededManualOutcomeUntouched() async throws {
        let spy = GoalsPageRequestSpy()
        spy.storedGoal = manualGoal(updatedAt: date(2026, 9, 5, 7, 0))
        let profile = DashboardProfile(
            sex: .male, ageYears: 30, heightCm: 167, weightKg: 63,
            activityLevel: .active, dietGoal: .lose, goalWeightKg: nil,
            updatedAt: date(2026, 9, 5, 9, 0)
        )
        spy.contextProfile = profile
        spy.contextLatestWeight = SyncedWeightSample(kilograms: 61.5, measuredAt: date(2026, 9, 5, 6, 0))
        spy.dayTotals = [412]
        spy.holdsStorage = true
        let viewModel = viewModel(spy: spy)

        await viewModel.load()
        let computed = DashboardMath.computedGoal(for: profile, latestWeightKg: 61.5)
        let targets = GoalsEditorViewModel.displayValue(computed.calorieTargetKcal)
        XCTAssertEqual(viewModel.calories, targets)
        XCTAssertEqual(viewModel.sources["calories"], .computed)
        XCTAssertEqual(viewModel.selectedDirection, .cut)
        XCTAssertNotNil(viewModel.supersededNote)

        spy.releaseStorage()
        try await settleDayTotal(of: viewModel)

        XCTAssertEqual(viewModel.todayCalories, 412)
        XCTAssertEqual(viewModel.calories, targets, "a late total only touches the consequence line")
        XCTAssertEqual(viewModel.sources["calories"], .computed)
        XCTAssertEqual(viewModel.selectedDirection, .cut)
        XCTAssertNotNil(viewModel.supersededNote)
    }
}

final class GoalsContextLazyLoadRealPathTests: GoalsContextLazyLoadCase {
    @MainActor
    func testRealLocalFirstRepositoryServesTheCachedDayTotalWithNoAddedFullRead() async throws {
        let userID = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morsel-goals-184-\(userID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = LocalDataStore.storeURL(root: directory, accountID: userID)

        let spy = GoalsPageRequestSpy()
        spy.storedGoal = manualGoal()
        let reference = date(2026, 9, 5, 12, 0)
        spy.seededToday = DashboardSnapshot(
            date: reference, meals: [GoalsPageRequestSpy.meal(calories: 500, at: reference)], goal: nil
        )
        let repository = LocalFirstDashboardRepository(
            remote: spy, store: try LocalDataStore(databaseURL: url),
            snapshotCache: try LocalSnapshotCache(databaseURL: url)
        )
        // Seed the day snapshot through the REAL local-first read (one full read).
        _ = try await repository.loadToday(userID: userID, date: reference)
        XCTAssertEqual(spy.fullDashboardReads, 1)

        let viewModel = GoalsEditorViewModel(repository: repository, userID: userID, now: { reference })
        await viewModel.load()
        try await settleDayTotal(of: viewModel)

        XCTAssertEqual(spy.fullDashboardReads, 1, "opening Goals must not add a full Today read")
        XCTAssertEqual(viewModel.calories, "2000.0", "the fetched targets appear")
        XCTAssertEqual(viewModel.todayCalories, 500, "the narrow read is the cached local day total")
    }
}

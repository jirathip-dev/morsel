import XCTest
@testable import Morsel

// Issue #123 — Goals page polish (empty-then-filled flash + derived
// direction chip). This file uses ONLY pre-#123 APIs on purpose: it is the
// RED set at the pristine base c512b0f (same file compiles there, the
// asserts fail against the base behavior) and GREEN at the lane head.
//
// 1. Local-first first paint: with a cached stored goal row the fields are
//    non-empty and `fieldError` is nil for all four immediately after
//    load() starts — before the (fake, delayed) remote resolves. Exercised
//    through the REAL LocalFirstDashboardRepository + SQLite snapshot
//    cache, so the production cache-paint layer is what paints.
// 2. Validation only after edit: pristine empty fields report no error
//    (first load in flight, or a load that found nothing); after
//    edit("calories", "") the error appears.
// 3. The filled chip is derived from the profile diet goal when the
//    effective goal is computed (lose→cut / maintain→maintain / gain→bulk).

private final class GoalsPolishRemote: DashboardRepository {
    let stored: StoredDashboardGoal?
    let snapshot: DashboardSnapshot
    /// When set, the remote reads block until releaseRemote() — a fake
    /// delayed continuation for observing the pre-reconcile state.
    var blockRemote = false
    private var loadTodayGate: CheckedContinuation<Void, Never>?
    private var contextGate: CheckedContinuation<Void, Never>?

    init(stored: StoredDashboardGoal?, snapshot: DashboardSnapshot) {
        self.stored = stored
        self.snapshot = snapshot
    }

    func releaseRemote() {
        blockRemote = false
        loadTodayGate?.resume()
        contextGate?.resume()
        loadTodayGate = nil
        contextGate = nil
    }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        if blockRemote {
            await withCheckedContinuation { continuation in
                loadTodayGate = continuation
            }
        }
        return snapshot
    }

    func loadGoalsContext(userID: UUID) async throws -> GoalsPageContext {
        if blockRemote {
            await withCheckedContinuation { continuation in
                contextGate = continuation
            }
        }
        return GoalsPageContext(stored: stored, profile: nil, latestWeight: nil, profileRowRead: true)
    }

    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { stored }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        HistoryOverview(days: [], goal: nil)
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}

    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        UUID()
    }

    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }

    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        DashboardGoal(calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .computed)
    }
}

final class GoalsPolishTests: XCTestCase {
    private func storeDirectory(for userID: UUID) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morsel-goals-polish-\\(userID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStores(
        root: URL, accountID: UUID
    ) throws -> (store: LocalDataStore, cache: LocalSnapshotCache) {
        let url = LocalDataStore.storeURL(root: root, accountID: accountID)
        return (try LocalDataStore(databaseURL: url), try LocalSnapshotCache(databaseURL: url))
    }

    private func emptySnapshot() -> DashboardSnapshot {
        DashboardSnapshot(date: Date(), meals: [], goal: nil)
    }

    /// Bounded polling on the main actor: yields until `condition` holds or
    /// the deadline passes (returns false). The delayed remote never
    /// completes on its own, so any state observed here is pre-reconcile.
    private func waitFor(
        seconds: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            await Task.yield()
        }
        return true
    }

    // MARK: - (a) cached goal paints before the remote resolves

    @MainActor
    func testCachedGoalPaintsAllFourFieldsBeforeRemoteResolves() async throws {
        let userID = UUID()
        let directory = try storeDirectory(for: userID)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = try makeStores(root: directory, accountID: userID)

        let cachedRow = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .computed
        )
        let remoteRow = StoredDashboardGoal(
            calorieTargetKcal: 2_100, proteinG: 160, carbsG: 210, fatG: 70, source: .computed
        )

        // Seed the goals cache through the REAL local-first read (a remote
        // success writes the snapshot cache)…
        let seeder = LocalFirstDashboardRepository(
            remote: GoalsPolishRemote(stored: cachedRow, snapshot: emptySnapshot()),
            store: stores.store,
            snapshotCache: stores.cache
        )
        _ = try await seeder.loadGoalsContext(userID: userID)

        // …then load through a remote that is still in flight.
        let blocked = GoalsPolishRemote(stored: remoteRow, snapshot: emptySnapshot())
        blocked.blockRemote = true
        let repository = LocalFirstDashboardRepository(
            remote: blocked, store: stores.store, snapshotCache: stores.cache
        )
        let viewModel = GoalsEditorViewModel(repository: repository, userID: userID)
        let loadTask = Task { await viewModel.load() }

        let painted = await waitFor { viewModel.calories == "2000.0" }
        XCTAssertTrue(painted, "cached goal must paint while the remote round-trip is in flight")
        XCTAssertEqual(viewModel.calories, "2000.0")
        XCTAssertEqual(viewModel.protein, "150.0")
        XCTAssertEqual(viewModel.carbs, "200.0")
        XCTAssertEqual(viewModel.fat, "70.0")
        XCTAssertNil(viewModel.fieldError("calories"), "no red error on the pristine painted value")
        XCTAssertNil(viewModel.fieldError("protein"))
        XCTAssertNil(viewModel.fieldError("carbs"))
        XCTAssertNil(viewModel.fieldError("fat"))
        XCTAssertTrue(viewModel.isLoading, "the remote refresh is still in flight")

        blocked.releaseRemote()
        await loadTask.value

        // The remote refresh reconciles to the newer row.
        XCTAssertEqual(viewModel.calories, "2100.0")
        XCTAssertEqual(viewModel.protein, "160.0")
        XCTAssertEqual(viewModel.carbs, "210.0")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testFirstLoadWithoutCacheStaysCalmWhileRemoteIsInFlight() async throws {
        let userID = UUID()
        let directory = try storeDirectory(for: userID)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = try makeStores(root: directory, accountID: userID)

        let blocked = GoalsPolishRemote(stored: nil, snapshot: emptySnapshot())
        blocked.blockRemote = true
        let repository = LocalFirstDashboardRepository(
            remote: blocked, store: stores.store, snapshotCache: stores.cache
        )
        let viewModel = GoalsEditorViewModel(repository: repository, userID: userID)
        let loadTask = Task { await viewModel.load() }

        _ = await waitFor { viewModel.isLoading }
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.calories.isEmpty, "no cache yet — nothing to paint")
        XCTAssertNil(viewModel.fieldError("calories"), "never a red error on untouched empty fields")
        XCTAssertNil(viewModel.fieldError("protein"))
        XCTAssertNil(viewModel.fieldError("carbs"))
        XCTAssertNil(viewModel.fieldError("fat"))

        blocked.releaseRemote()
        await loadTask.value

        // The remote found no goal row: the pristine empty state stays calm.
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.calories.isEmpty)
        XCTAssertNil(viewModel.fieldError("calories"))
        XCTAssertNil(viewModel.fieldError("protein"))
        XCTAssertNil(viewModel.fieldError("carbs"))
        XCTAssertNil(viewModel.fieldError("fat"))
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: - (b) validation only after edit

    @MainActor
    func testPristineEmptyFieldsReportNoErrorUntilEdited() {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let viewModel = GoalsEditorViewModel(repository: repository, userID: UUID())

        XCTAssertNil(viewModel.fieldError("calories"))
        XCTAssertNil(viewModel.fieldError("protein"))
        XCTAssertNil(viewModel.fieldError("carbs"))
        XCTAssertNil(viewModel.fieldError("fat"))
        XCTAssertFalse(viewModel.isValid)

        viewModel.edit("calories", value: "")
        XCTAssertEqual(viewModel.fieldError("calories"), "Enter a number of 0 or more.")
        XCTAssertNil(viewModel.fieldError("protein"), "untouched fields stay calm")

        viewModel.edit("calories", value: "2000")
        XCTAssertNil(viewModel.fieldError("calories"))
    }

    @MainActor
    func testLoadThatFindsNothingKeepsPristineFieldsCalm() async {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let viewModel = GoalsEditorViewModel(repository: repository, userID: UUID())

        await viewModel.load()

        XCTAssertTrue(viewModel.calories.isEmpty)
        XCTAssertNil(viewModel.fieldError("calories"), "no stored goal is not an error")
        XCTAssertNil(viewModel.fieldError("protein"))
        XCTAssertNil(viewModel.fieldError("carbs"))
        XCTAssertNil(viewModel.fieldError("fat"))
    }

    // MARK: - (c) selected direction derived from the profile diet goal

    @MainActor
    func testComputedEffectiveGoalDerivesTheProfileDirectionChip() async {
        let cases: [(ProfileDietGoal, GoalDirection)] = [
            (.lose, .cut),
            (.maintain, .maintain),
            (.gain, .bulk)
        ]
        for (dietGoal, expected) in cases {
            let repository = MockDashboardRepository(snapshot: emptySnapshot())
            let profile = DashboardProfile(
                sex: .male, ageYears: 30, heightCm: 167, weightKg: 63,
                activityLevel: .active, dietGoal: dietGoal, goalWeightKg: nil
            )
            repository.seedGoalsContext(profile: profile, latestWeight: nil)
            repository.seedStoredGoal(StoredDashboardGoal(
                calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .computed
            ))
            let viewModel = GoalsEditorViewModel(repository: repository, userID: UUID())

            await viewModel.load()

            XCTAssertEqual(
                viewModel.selectedDirection, expected,
                "a computed goal for dietGoal \\(dietGoal.rawValue) must fill \\(expected.rawValue)"
            )
            XCTAssertEqual(viewModel.sources["calories"], .computed)
        }
    }
}

import XCTest
@testable import Morsel

// Issue #136 — History freeze regression: rapid tab switches cancel and
// re-fire `.task(id:)` ledger reads. A cancelled read that does NOT promptly
// surface CancellationError (the SQLite/Supabase read path) used to leave
// `isLoading` stuck while `guard !isLoading` refused every newer load — the
// permanent 'Reading the ledger…' freeze. These tests drive that exact race
// through a repository whose first read blocks forever (raw continuations
// ignore task cancellation, like a non-cooperative local read), then assert
// a newer load supersedes it and the loading flag clears.
//
// RED at the pristine base (guard-gated `load()`): the superseding load
// returns immediately, `isLoading` stays true past the 2 s contract, and the
// overview never arrives. GREEN at the fix: the newer load completes and the
// loading flag clears within the deadline.

@MainActor
final class HistoryFreezeRegressionTests: XCTestCase {
    private let account = UUID()
    private let fixedToday = Date(timeIntervalSince1970: 1_770_000_000)

    /// Blocks its FIRST `loadHistory` (and first `loadToday`) on a raw
    /// continuation that ignores task cancellation until explicitly released
    /// — mimicking a local-ledger read that does not surface CancellationError
    /// when its SwiftUI `.task` is cancelled by a tab switch. Every later call
    /// returns instantly so a superseding read can complete.
    private final class GatedHistoryRepository: DashboardRepository, @unchecked Sendable {
        private(set) var historyCallCount = 0
        private(set) var todayCallCount = 0
        private var historyGate: CheckedContinuation<Void, Never>?
        private var todayGate: CheckedContinuation<Void, Never>?
        private let overview: HistoryOverview
        private let snapshots: [Date: DashboardSnapshot]

        init(overview: HistoryOverview, snapshots: [Date: DashboardSnapshot] = [:]) {
            self.overview = overview
            self.snapshots = snapshots
        }

        func releaseHistoryGate() {
            historyGate?.resume()
            historyGate = nil
        }

        func releaseTodayGate() {
            todayGate?.resume()
            todayGate = nil
        }

        func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
            historyCallCount += 1
            if historyCallCount == 1 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    historyGate = continuation
                }
            }
            return overview
        }

        func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
            todayCallCount += 1
            if todayCallCount == 1 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    todayGate = continuation
                }
            }
            guard let snapshot = snapshots[DashboardMath.startOfLocalDay(date)] else {
                throw MorselError.invalidData("No seeded snapshot for the requested day.")
            }
            return snapshot
        }

        func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? { nil }
        func cachedHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview? { nil }
        func cachedGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
        func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
        func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
        func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
        func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID { UUID() }
        func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
        func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
        func loadGoalsContext(userID: UUID) async throws -> GoalsPageContext {
            GoalsPageContext(stored: nil, profile: nil, latestWeight: nil, profileRowRead: false)
        }
        func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
            DashboardGoal(
                calorieTargetKcal: 2_000, proteinG: 100, carbsG: 200, fatG: 70,
                source: .computed
            )
        }
        func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
        func localMealRecord(userID: UUID, localMealID: UUID) async throws -> MealRecord? { nil }
    }

    private func seededDay(_ date: Date) -> HistoryDay {
        HistoryDay(date: DashboardMath.startOfLocalDay(date), eatenKcal: 900, logged: true)
    }

    private func seededSnapshot(date: Date, name: String = "Rice") -> DashboardSnapshot {
        DashboardSnapshot(
            date: DashboardMath.startOfLocalDay(date),
            meals: [MealRecord(
                mealLogID: UUID(), mealType: .lunch, eatenAt: date, source: .manual,
                imagePath: nil, items: [MealItem(
                    itemID: UUID(), name: name, quantity: 1, unit: .serving,
                    caloriesKcal: 900, proteinG: 10, carbsG: 40, fatG: 5,
                    fiberG: nil, sugarG: nil, confidence: 1.0, notes: nil, source: .manual
                )]
            )],
            goal: nil
        )
    }

    /// Waits (bounded) for a condition, yielding the main executor.
    private func waitUntil(
        timeout: TimeInterval = 3, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    // MARK: - The reported freeze: cancelled read never blocks a newer load

    func testCancelledLedgerReadIsSupersededWithinTwoSeconds() async throws {
        let day = seededDay(fixedToday)
        let repo = GatedHistoryRepository(
            overview: HistoryOverview(days: [day], goal: nil, weightTrend: [])
        )
        defer { repo.releaseHistoryGate() }
        let viewModel = HistoryViewModel(
            repository: repo, userID: account, dateProvider: { self.fixedToday }
        )

        // First tab entry starts a ledger read that blocks and ignores
        // cancellation (the non-cooperative local read from the bug report).
        let firstEntry = Task { await viewModel.load() }
        let firstReadStarted = await waitUntil({ repo.historyCallCount == 1 })
        XCTAssertTrue(firstReadStarted, "first read must start")
        XCTAssertTrue(viewModel.isLoading)

        // Rapid tab switch: SwiftUI cancels the first .task and re-fires.
        firstEntry.cancel()
        // The fresh load must SUPERSEDE the stuck read, not gate on it.
        await viewModel.load()

        // Contract: never left loading for more than 2 s after the switch.
        let cleared = await waitUntil(timeout: 2, { !viewModel.isLoading })
        XCTAssertTrue(
            cleared,
            "A cancelled/stuck ledger read must not leave History loading past 2 s"
        )
        XCTAssertEqual(viewModel.overview?.days, [day], "the newer load must publish its overview")
        XCTAssertEqual(repo.historyCallCount, 2, "the superseding read must actually run")
    }

    func testTenFastTabSwitchesNeverStickOnLoadingState() async throws {
        let day = seededDay(fixedToday)
        let repo = GatedHistoryRepository(
            overview: HistoryOverview(days: [day], goal: nil, weightTrend: [])
        )
        defer { repo.releaseHistoryGate() }
        let viewModel = HistoryViewModel(
            repository: repo, userID: account, dateProvider: { self.fixedToday }
        )

        let stuckFirstEntry = Task { await viewModel.load() }
        let firstReadStarted = await waitUntil({ repo.historyCallCount == 1 })
        XCTAssertTrue(firstReadStarted, "first read must start")
        stuckFirstEntry.cancel()

        // 10+ fast switches: every entry fires a fresh load. Each new load
        // must run to completion; none may return early on the stuck read.
        for _ in 0..<10 {
            await viewModel.load()
        }

        XCTAssertFalse(viewModel.isLoading, "loading must clear after the switch storm")
        XCTAssertNotNil(viewModel.overview, "the latest entry must publish the ledger")
        XCTAssertEqual(
            repo.historyCallCount, 11,
            "every fast-switch entry must run its own superseding read (the blocked first + 10)"
        )
    }

    // MARK: - Day drill-down: a stale read must not republish a newer day

    func testStaleDayReadCannotOverwriteNewerDaySelection() async throws {
        let olderDate = fixedToday.addingTimeInterval(-86_400 * 2)
        let newerDate = fixedToday.addingTimeInterval(-86_400)
        let repo = GatedHistoryRepository(
            overview: HistoryOverview(days: [], goal: nil, weightTrend: []),
            snapshots: [
                DashboardMath.startOfLocalDay(olderDate): seededSnapshot(date: olderDate, name: "Old"),
                DashboardMath.startOfLocalDay(newerDate): seededSnapshot(date: newerDate, name: "New")
            ]
        )
        defer { repo.releaseTodayGate() }
        let viewModel = HistoryViewModel(
            repository: repo, userID: account, dateProvider: { self.fixedToday }
        )

        // Open the OLDER day: its read blocks (cancelled/switched away).
        let olderSelection = Task {
            await viewModel.select(seededDay(olderDate))
        }
        let olderReadStarted = await waitUntil({ repo.todayCallCount == 1 })
        XCTAssertTrue(olderReadStarted, "older day read must start")
        XCTAssertTrue(viewModel.isExpandedLoading)

        // User moves on to the NEWER day while the old read is still draining.
        await viewModel.select(seededDay(newerDate))
        XCTAssertEqual(viewModel.expandedDay, DashboardMath.startOfLocalDay(newerDate))

        // The stuck older read finally returns — it must NOT overwrite the
        // newer day's snapshot, and loading must have cleared.
        repo.releaseTodayGate()
        await olderSelection.value

        XCTAssertEqual(
            viewModel.daySnapshot?.meals.first?.items.first?.name, "New",
            "a stale day read must not republish over the newer selection"
        )
        XCTAssertFalse(viewModel.isExpandedLoading, "day loading must clear after the stale read")
        XCTAssertNil(viewModel.expandedError)
    }

    func testCollapseSupersedesInFlightDayRead() async throws {
        let date = fixedToday.addingTimeInterval(-86_400)
        let repo = GatedHistoryRepository(
            overview: HistoryOverview(days: [], goal: nil, weightTrend: []),
            snapshots: [DashboardMath.startOfLocalDay(date): seededSnapshot(date: date)]
        )
        defer { repo.releaseTodayGate() }
        let viewModel = HistoryViewModel(
            repository: repo, userID: account, dateProvider: { self.fixedToday }
        )

        let opening = Task { await viewModel.select(seededDay(date)) }
        let dayReadStarted = await waitUntil({ repo.todayCallCount == 1 })
        XCTAssertTrue(dayReadStarted, "day read must start")

        // Collapse while the read is still in flight.
        await viewModel.select(seededDay(date))
        XCTAssertNil(viewModel.expandedDay)
        XCTAssertFalse(viewModel.isExpandedLoading, "collapse must clear the loading flag")

        repo.releaseTodayGate()
        await opening.value

        XCTAssertNil(viewModel.daySnapshot, "a collapsed day must stay collapsed")
        XCTAssertFalse(viewModel.isExpandedLoading)
    }
}

import XCTest
@testable import Morsel

// Issue #190 base probe — the Goals-save witness with the BASE shell wiring.
// Dropped into the base tree for the RED leg (`/tmp/morsel-190-base`, base
// `origin/staging` 83010c8) together with app/Tests/MorselTests/
// WriteAckRegressionTests.swift. Identical composition and assertions to
// `WriteAckGoalsTests` (the head suite), except `onSaved` is the base shell
// wiring `{ await viewModel.invalidateDay() }` — which IS the audited
// mechanism: the save awaited the full dashboard reload. At the head the
// shipped wiring is `{ viewModel.invalidateDayAfterConfirmedGoals() }`.
// Uses only entry points present at the base, so the base red is behavioural.

final class GoalsWiringBaseProbeTests: XCTestCase {
    @MainActor
    final class DayHarness {
        var readDates: [Date] = []
        private var parked: [Int: CheckedContinuation<DashboardSnapshot, Error>] = [:]
        private var draining = false

        func read(date: Date) async throws -> DashboardSnapshot {
            if draining { return DashboardSnapshot(date: date, meals: [], goal: nil) }
            return try await withCheckedThrowingContinuation { continuation in
                parked[readDates.count] = continuation
                readDates.append(date)
            }
        }

        func drain() {
            draining = true
            let waiting = parked
            parked.removeAll()
            for (index, continuation) in waiting {
                continuation.resume(returning: DashboardSnapshot(date: readDates[index], meals: [], goal: nil))
            }
        }
    }

    struct DayRepository: DashboardRepository {
        let harness: DayHarness
        func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot { try await harness.read(date: date) }
        func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? { nil }
        func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
        func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
        func attachMealPhoto(userID: UUID, itemID: UUID, photo: FoodImageUpload) async throws {}
        func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
        func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID { UUID() }
        func localMealRecord(userID: UUID, localMealID: UUID) async throws -> MealRecord? { nil }
        func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
            HistoryOverview(days: [], goal: nil, weightTrend: [])
        }
        func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
        func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
        func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
        func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
            throw MorselError.configurationMissing
        }
    }

    @MainActor
    func testGoalsSaveFinishesWithoutWaitingForTheDashboardRead() async {
        let harness = DayHarness()
        let account = UUID()
        let date = DashboardMath.startOfLocalDay(Date(timeIntervalSince1970: 1_789_300_800))
        let day = DashboardViewModel(repository: DayRepository(harness: harness), userID: account,
                                     dateProvider: { date })
        // The BASE shell wiring (MorselApp `onSaved`).
        let model = GoalsEditorViewModel(repository: DayRepository(harness: harness), userID: account,
                                        now: { date }, onSaved: { await day.invalidateDay() })
        model.calories = "2200.0"
        model.protein = "160.0"
        model.carbs = "210.0"
        model.fat = "75.0"

        var saved: Bool?
        let save = Task { saved = await model.save() }
        let deadline = ContinuousClock.now + .seconds(3)
        while saved == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        harness.drain()

        XCTAssertNotNil(saved, "the acknowledged Goals save must finish on its own write")
        XCTAssertEqual(saved, true)
        XCTAssertFalse(model.isSaving, "the Save control must leave its saving state")
        XCTAssertTrue(day.isLoading, "the invalidated day read is admitted, never awaited")
        save.cancel()
    }
}

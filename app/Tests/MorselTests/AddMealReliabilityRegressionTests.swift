import XCTest
@testable import Morsel

// Issue #106 AC3 — the reported "Add meal does not save" failure mode:
// the remote write SUCCEEDS but the follow-up full reload fails, and the
// network-first ViewModel reports the save as failed ("The meal could not
// be saved") — inviting a duplicate retry of an already-committed meal.
// Production shape: AddMealView → viewModel.addMeal → repository.logMeal
// (durable local commit at head) → immediate success decision, WITHOUT a
// second blocking loadToday deciding local success.
@MainActor
final class AddMealReliabilityRegressionTests: XCTestCase {
    private func mealDraft() -> MealDraft {
        MealDraft(
            mealType: .lunch,
            eatenAt: Date(timeIntervalSince1970: 100),
            notes: nil,
            items: [MealItemDraft(name: "oats", quantity: 1, unit: .serving,
                                  caloriesKcal: 220, proteinG: 8, carbsG: 40,
                                  fatG: 4, fiberG: 5, sugarG: 1, confidence: 1)]
        )
    }

    /// The old failure mode: repository.logMeal commits successfully, but the
    /// immediate second loadToday throws (network/RPC blip after commit).
    /// The save must still be reported successful — the write is durable and
    /// the UI may leave Add Meal — never "could not be saved".
    func testSuccessfulWriteWithFailedReloadIsNotReportedAsNotSaved() async {
        let repository = CommittingButUnreloadableRepository()
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())

        let didSave = await viewModel.addMeal(draft: mealDraft(), photo: nil)

        XCTAssertTrue(
            didSave,
            "A committed meal must not be reported as not saved when the follow-up reload fails."
        )
        XCTAssertNil(
            viewModel.errorMessage,
            "A successful write must not surface an error message that claims the save failed."
        )
        XCTAssertEqual(repository.committedDrafts.count, 1)
    }
}

/// Remote write succeeds (meal committed); every reload attempt fails —
/// the post-write reload-error variant of the reported bug.
private final class CommittingButUnreloadableRepository: DashboardRepository {
    private(set) var committedDrafts: [MealDraft] = []

    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        committedDrafts.append(draft)
        return UUID()
    }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        throw MorselError.requestFailed(503, "reload unavailable")
    }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        throw MorselError.requestFailed(503, "reload unavailable")
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        throw MorselError.requestFailed(503, "reload unavailable")
    }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
}

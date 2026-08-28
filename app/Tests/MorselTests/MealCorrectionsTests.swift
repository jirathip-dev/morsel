import XCTest
@testable import Morsel

final class MealCorrectionsTests: XCTestCase {
    @MainActor
    func testUpdateChangesPortionAndMacrosAndRecordsManualEditProvenance() async throws {
        let meal = meal(
            mealID: UUID(),
            items: [item(name: "Rice", quantity: 1, calories: 220, protein: 4, carbs: 48, fat: 1, confidence: 0.7)]
        )
        let repository = MockDashboardRepository(snapshot: snapshot(meals: [meal]))
        let userID = UUID()
        let update = MealItemUpdate(
            itemID: meal.items[0].itemID,
            quantity: 2,
            caloriesKcal: 440,
            proteinG: 8,
            carbsG: 96,
            fatG: 2
        )

        try await repository.updateMealItem(userID: userID, update: update)
        let updated = try await repository.loadToday(userID: userID, date: meal.eatenAt)
        let item = try XCTUnwrap(updated.meals.first?.items.first)

        XCTAssertEqual(item.quantity, 2)
        XCTAssertEqual(item.caloriesKcal, 440)
        XCTAssertEqual(item.proteinG, 8)
        XCTAssertEqual(item.carbsG, 96)
        XCTAssertEqual(item.fatG, 2)
        XCTAssertEqual(item.confidence, 0.7)
        XCTAssertEqual(item.notes, MealSource.manualEdit.rawValue)
        XCTAssertEqual(item.provenance, .manualEdit)
        XCTAssertTrue(DashboardMath.confidenceBadge(for: item.confidence).needsReview)
        XCTAssertFalse(item.needsReview)
    }

    func testManualEditPayloadUsesSourceNotesWithoutConfidenceWrite() throws {
        let update = MealItemUpdate(itemID: UUID(), caloriesKcal: 300)
        let data = try JSONEncoder().encode(MealItemUpdatePayload(update: update))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["source_notes"] as? String, MealSource.manualEdit.rawValue)
        XCTAssertNil(payload["confidence"])
        XCTAssertEqual(payload["calories_kcal"] as? Double, 300)
    }

    @MainActor
    func testUntouchedConfidentAgentItemKeepsAgentProvenance() async throws {
        let meal = meal(
            mealID: UUID(),
            items: [item(name: "Rice", quantity: 1, calories: 220, protein: 4, carbs: 48, fat: 1, confidence: 1.0)]
        )
        let repository = MockDashboardRepository(snapshot: snapshot(meals: [meal]))

        let loaded = try await repository.loadToday(userID: UUID(), date: meal.eatenAt)
        let item = try XCTUnwrap(loaded.meals.first?.items.first)

        XCTAssertEqual(item.provenance, .photoVision)
        XCTAssertFalse(DashboardMath.confidenceBadge(for: item.confidence).needsReview)
    }

    @MainActor
    func testViewModelUpdateRefreshesTotalsAndClearsNeedsReview() async throws {
        let meal = meal(
            mealID: UUID(),
            items: [item(name: "Rice", quantity: 1, calories: 220, protein: 4, carbs: 48, fat: 1, confidence: 0.7)]
        )
        let repository = MockDashboardRepository(snapshot: snapshot(meals: [meal]))
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())
        await viewModel.load()
        XCTAssertEqual(viewModel.reviewItems.map(\.itemID), [meal.items[0].itemID])
        let update = MealItemUpdate(itemID: meal.items[0].itemID, caloriesKcal: 440)

        let didUpdate = await viewModel.updateMealItem(update)

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(viewModel.totals.caloriesKcal, 440)
        XCTAssertTrue(viewModel.reviewItems.isEmpty)
        XCTAssertEqual(viewModel.snapshot?.meals.first?.items.first?.provenance, .manualEdit)
    }

    @MainActor
    func testDeleteRemovesMealAndRefreshesTotals() async throws {
        let deletedMeal = meal(
            mealID: UUID(),
            items: [item(name: "Rice", quantity: 1, calories: 220, protein: 4, carbs: 48, fat: 1)]
        )
        let retainedMeal = meal(
            mealID: UUID(),
            items: [item(name: "Chicken", quantity: 1, calories: 200, protein: 38, carbs: 0, fat: 5)]
        )
        let repository = MockDashboardRepository(snapshot: snapshot(meals: [deletedMeal, retainedMeal]))
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())
        await viewModel.load()

        let didDelete = await viewModel.deleteMeal(deletedMeal.mealLogID)

        XCTAssertTrue(didDelete)
        XCTAssertEqual(viewModel.snapshot?.meals.map(\.mealLogID), [retainedMeal.mealLogID])
        XCTAssertEqual(viewModel.totals.caloriesKcal, 200)
    }

    @MainActor
    func testMissingItemReportsErrorWithoutChangingState() async throws {
        let meal = meal(
            mealID: UUID(),
            items: [item(name: "Rice", quantity: 1, calories: 220, protein: 4, carbs: 48, fat: 1)]
        )
        let repository = MockDashboardRepository(snapshot: snapshot(meals: [meal]))
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())
        await viewModel.load()
        let before = viewModel.snapshot
        let update = MealItemUpdate(itemID: UUID(), caloriesKcal: 440)

        let didUpdate = await viewModel.updateMealItem(update)

        XCTAssertFalse(didUpdate)
        XCTAssertEqual(viewModel.snapshot, before)
        XCTAssertEqual(viewModel.errorMessage, "The meal item could not be updated.")
    }

    private func snapshot(meals: [MealRecord]) -> DashboardSnapshot {
        DashboardSnapshot(
            date: Date(timeIntervalSince1970: 0),
            meals: meals,
            goal: DashboardGoal(
                calorieTargetKcal: 2_000,
                proteinG: 150,
                carbsG: 200,
                fatG: 70,
                source: .computed
            )
        )
    }

    private func meal(mealID: UUID, items: [MealItem]) -> MealRecord {
        MealRecord(
            mealLogID: mealID,
            mealType: .lunch,
            eatenAt: Date(timeIntervalSince1970: 0),
            source: .photoVision,
            items: items
        )
    }

    private func item(
        name: String,
        quantity: Double,
        calories: Double?,
        protein: Double?,
        carbs: Double?,
        fat: Double?,
        confidence: Double? = 0.9
    ) -> MealItem {
        MealItem(
            itemID: UUID(),
            name: name,
            quantity: quantity,
            unit: .serving,
            caloriesKcal: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fiberG: nil,
            sugarG: nil,
            confidence: confidence,
            notes: nil,
            source: .photoVision
        )
    }
}

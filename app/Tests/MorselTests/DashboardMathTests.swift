import XCTest
@testable import Morsel

final class DashboardMathTests: XCTestCase {
    func testTotalsSumNutritionAndTreatMissingMacrosAsZero() {
        let meals = [
            meal(
                source: .photoVision,
                items: [
                    item(name: "Rice", calories: 220, protein: 4, carbs: 48, fat: nil),
                    item(name: "Chicken", calories: 200, protein: 38, carbs: nil, fat: 5)
                ]
            ),
            meal(
                source: .manual,
                items: [item(name: "Coffee", calories: 40, protein: 1, carbs: 4, fat: 2)]
            )
        ]

        XCTAssertEqual(
            DashboardMath.totals(for: meals),
            DashboardTotals(caloriesKcal: 460, proteinG: 43, carbsG: 52, fatG: 7)
        )
    }

    @MainActor
    func testMockRepositoryReturnsSuppliedSnapshotWithoutNetwork() async throws {
        let expected = DashboardSnapshot(
            date: Date(timeIntervalSince1970: 0),
            meals: [],
            goal: nil
        )
        let repository = MockDashboardRepository(snapshot: expected)

        let actual = try await repository.loadToday(
            userID: UUID(),
            accessToken: "test-token",
            date: expected.date
        )

        XCTAssertEqual(actual, expected)
    }

    func testConfidenceBadgeMarksMissingAndBelowThresholdForReview() {
        XCTAssertEqual(DashboardMath.confidenceBadge(for: 0.90), .high)
        XCTAssertEqual(DashboardMath.confidenceBadge(for: 0.80), .high)
        XCTAssertEqual(DashboardMath.confidenceBadge(for: 0.79), .low)
        XCTAssertEqual(DashboardMath.confidenceBadge(for: nil), .missing)
        XCTAssertTrue(DashboardMath.confidenceBadge(for: 0.70).needsReview)
        XCTAssertTrue(DashboardMath.confidenceBadge(for: nil).needsReview)
        XCTAssertFalse(DashboardMath.confidenceBadge(for: 0.90).needsReview)
    }

    func testGoalStatusUsesAccentEnergyAndOverStates() {
        XCTAssertEqual(DashboardMath.goalStatus(eaten: 1_000, goal: 2_000), .onTrack)
        XCTAssertEqual(DashboardMath.goalStatus(eaten: 1_700, goal: 2_000), .nearGoal)
        XCTAssertEqual(DashboardMath.goalStatus(eaten: 2_001, goal: 2_000), .over)
        XCTAssertEqual(DashboardMath.goalStatus(eaten: 1_000, goal: nil), .unavailable)
    }

    private func meal(source: MealSource, items: [MealItem]) -> MealRecord {
        MealRecord(
            mealLogID: UUID(),
            mealType: .lunch,
            eatenAt: Date(timeIntervalSince1970: 0),
            source: source,
            items: items
        )
    }

    private func item(
        name: String,
        calories: Double?,
        protein: Double?,
        carbs: Double?,
        fat: Double?
    ) -> MealItem {
        MealItem(
            itemID: UUID(),
            name: name,
            quantity: 1,
            unit: .serving,
            caloriesKcal: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fiberG: nil,
            sugarG: nil,
            confidence: 0.9,
            notes: nil
        )
    }
}

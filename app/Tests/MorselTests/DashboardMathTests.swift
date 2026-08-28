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
            date: expected.date
        )

        XCTAssertEqual(actual, expected)
    }

    @MainActor
    func testMockRepositoryPersistsReviewAcrossReload() async throws {
        let reviewedItem = item(
            name: "Shared plate",
            calories: 300,
            protein: 12,
            carbs: 30,
            fat: 14,
            confidence: 0.7
        )
        let snapshot = DashboardSnapshot(
            date: Date(timeIntervalSince1970: 0),
            meals: [meal(source: .photoVision, items: [reviewedItem])],
            goal: nil
        )
        let repository = MockDashboardRepository(snapshot: snapshot)
        let userID = UUID()

        let before = try await repository.loadToday(userID: userID, date: snapshot.date)
        XCTAssertEqual(before.meals[0].items[0].confidence, 0.7)

        try await repository.confirmMealItem(userID: userID, itemID: reviewedItem.itemID)

        let after = try await repository.loadToday(userID: userID, date: snapshot.date)
        XCTAssertEqual(after.meals[0].items[0].confidence, 1.0)
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

    func testEffectiveGoalPrefersCompleteManualOverride() {
        let manual = StoredDashboardGoal(
            calorieTargetKcal: 2_000,
            proteinG: 150,
            carbsG: 200,
            fatG: 70,
            source: .manual
        )

        let goal = DashboardMath.effectiveGoal(stored: manual, profile: nil)

        XCTAssertEqual(
            goal,
            DashboardGoal(calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .manual)
        )
    }

    func testEffectiveGoalComputesFromProfileWhenStoredGoalIsMissing() {
        let profile = DashboardProfile(
            sex: .male,
            ageYears: 30,
            heightCm: 180,
            weightKg: 80,
            activityLevel: .moderate,
            dietGoal: .maintain,
            goalWeightKg: nil
        )

        let goal = DashboardMath.effectiveGoal(stored: nil, profile: profile)

        XCTAssertEqual(
            goal,
            DashboardGoal(calorieTargetKcal: 2_759, proteinG: 207, carbsG: 310, fatG: 77, source: .computed)
        )
    }

    func testEffectiveGoalIsUnavailableWithoutStoredGoalOrProfile() {
        XCTAssertNil(DashboardMath.effectiveGoal(stored: nil, profile: nil))
    }

    func testAppleNonceHashMatchesSupabaseAppleSignInRequirement() {
        XCTAssertEqual(
            AppleNonce.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
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
        fat: Double?,
        confidence: Double? = 0.9
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
            confidence: confidence,
            notes: nil
        )
    }
}

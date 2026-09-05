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

    // MARK: - Issue #113 recency mirror + latest-weight computed path

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        ) ?? Date(timeIntervalSince1970: 0)
    }

    private func profile(
        weightKg: Double,
        activity: ProfileActivityLevel = .moderate,
        diet: ProfileDietGoal = .maintain,
        updatedAt: Date?
    ) -> DashboardProfile {
        DashboardProfile(
            sex: .male, ageYears: 30, heightCm: 180, weightKg: weightKg,
            activityLevel: activity, dietGoal: diet, goalWeightKg: nil,
            updatedAt: updatedAt
        )
    }

    func testManualGoalStaysCurrentWhenWrittenAfterProfile() {
        let stored = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70,
            source: .manual, updatedAt: date(2026, 9, 5, 9)
        )
        let profile = self.profile(weightKg: 80, updatedAt: date(2026, 9, 5, 7))

        let goal = DashboardMath.effectiveGoal(stored: stored, profile: profile)

        XCTAssertEqual(
            goal,
            DashboardGoal(calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .manual)
        )
    }

    func testStaleManualGoalIsSupersededByNewerProfile() {
        let stored = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 100, carbsG: 0, fatG: 0,
            source: .manual, updatedAt: date(2026, 9, 5, 7)
        )
        let profile = self.profile(weightKg: 80, updatedAt: date(2026, 9, 5, 9))

        let goal = DashboardMath.effectiveGoal(stored: stored, profile: profile)

        XCTAssertEqual(
            goal,
            DashboardMath.computedGoal(for: profile, latestWeightKg: nil)
        )
        XCTAssertEqual(goal?.source, .computed)
        XCTAssertEqual(
            DashboardMath.supersededManual(stored: stored, profile: profile),
            SupersededManualGoal(
                calorieTargetKcal: 2_000, proteinG: 100, carbsG: 0, fatG: 0,
                updatedAt: date(2026, 9, 5, 7)
            )
        )
    }

    func testMissingManualWriteTimeComputesEvenWhenProfileAlsoLacksOne() {
        // Server parity (service.ts resolveEffectiveGoal): manualIsCurrent
        // requires stored.updated_at to EXIST — when it is undefined the
        // manual cannot prove it is newer, so computed wins (the DB stamps
        // updated_at NOT NULL; this only occurs on legacy/cached rows).
        let stored = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .manual
        )
        let profile = self.profile(weightKg: 80, updatedAt: nil)

        let goal = DashboardMath.effectiveGoal(stored: stored, profile: profile)

        XCTAssertEqual(goal?.source, .computed)
        XCTAssertEqual(goal?.calorieTargetKcal, DashboardMath.computedGoal(for: profile).calorieTargetKcal)
    }

    func testStaleManualWithoutWriteTimeComputesWhenProfileIsNewer() {
        let stored = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 100, carbsG: 0, fatG: 0, source: .manual
        )
        let profile = self.profile(weightKg: 80, updatedAt: date(2026, 9, 5, 9))

        let goal = DashboardMath.effectiveGoal(stored: stored, profile: profile)

        XCTAssertEqual(goal?.source, .computed)
        XCTAssertNil(DashboardMath.supersededManual(stored: stored, profile: profile))
    }

    func testPartialManualGoalIsNotReportedAsSuperseded() {
        let partial = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: nil, carbsG: nil, fatG: nil,
            source: .manual, updatedAt: date(2026, 9, 5, 7)
        )
        let profile = self.profile(weightKg: 80, updatedAt: date(2026, 9, 5, 9))

        XCTAssertNil(DashboardMath.supersededManual(stored: partial, profile: profile))
        XCTAssertEqual(
            DashboardMath.effectiveGoal(stored: partial, profile: profile)?.source,
            .computed
        )
    }

    func testLatestSyncedWeightFeedsComputedPath() {
        // Amendment A: profile 63 kg + newer Health sample 61.5 kg -> the
        // computed target uses 61.5 on BOTH sides (app mirror == the server
        // compute_targets weight_used contract).
        let profile63 = self.profile(weightKg: 63, updatedAt: date(2026, 9, 5, 9))
        let profile615 = self.profile(weightKg: 61.5, updatedAt: date(2026, 9, 5, 9))

        let fromSample = DashboardMath.computedGoal(for: profile63, latestWeightKg: 61.5)
        let fromTyped615 = DashboardMath.computedGoal(for: profile615)

        XCTAssertEqual(fromSample, fromTyped615)
        XCTAssertNotEqual(
            fromSample,
            DashboardMath.computedGoal(for: profile63, latestWeightKg: nil),
            "the newer Health sample must override the typed 63 kg profile weight"
        )
    }

    func testComputedGoalFallsBackToProfileWeightWithoutSample() {
        let profile63 = self.profile(weightKg: 63, updatedAt: nil)

        XCTAssertEqual(
            DashboardMath.computedGoal(for: profile63, latestWeightKg: nil),
            DashboardMath.computedGoal(for: profile63)
        )
        XCTAssertEqual(
            DashboardMath.effectiveGoal(stored: nil, profile: profile63, latestWeightKg: nil),
            DashboardMath.computedGoal(for: profile63)
        )
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

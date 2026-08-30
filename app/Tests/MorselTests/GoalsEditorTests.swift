import XCTest
@testable import Morsel

final class GoalsEditorTests: XCTestCase {
    @MainActor
    func testEmptyAndNegativeGoalsDisableSave() {
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil))
        let viewModel = GoalsEditorViewModel(repository: repository, userID: UUID())
        XCTAssertFalse(viewModel.isValid)
        viewModel.calories = "-1"
        viewModel.protein = "20"
        viewModel.carbs = "20"
        viewModel.fat = "20"
        XCTAssertFalse(viewModel.isValid)
    }

    @MainActor
    func testDirectionPrefillsComputedValuesAndManualEditFlipsOneSource() async {
        let goal = DashboardGoal(calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .computed)
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: goal))
        let viewModel = GoalsEditorViewModel(repository: repository, userID: UUID())
        await viewModel.choose(.maintain)
        XCTAssertEqual(viewModel.sources["protein"], .computed)
        XCTAssertEqual(viewModel.selectedDirection, .maintain)
        viewModel.edit("protein", value: "155")
        XCTAssertEqual(viewModel.sources["protein"], .manual)
        XCTAssertEqual(viewModel.sources["carbs"], .computed)
    }

    @MainActor
    func testSaveWritesManualGoalAndDashboardReloadReflectsIt() async throws {
        let goal = DashboardGoal(calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .computed)
        let snapshot = DashboardSnapshot(date: Date(), meals: [], goal: goal)
        let repository = MockDashboardRepository(snapshot: snapshot)
        let userID = UUID()
        let viewModel = GoalsEditorViewModel(repository: repository, userID: userID)
        await viewModel.choose(.maintain)
        viewModel.edit("calories", value: "2000")
        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)
        let stored = try await repository.loadGoals(userID: userID)
        XCTAssertEqual(stored?.source, .manual)
        XCTAssertEqual(stored?.calorieTargetKcal, 2_000)
    }

    @MainActor
    func testComputedDirectionSaveKeepsComputedSource() async throws {
        let goal = DashboardGoal(calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .computed)
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: goal))
        let userID = UUID()
        let viewModel = GoalsEditorViewModel(repository: repository, userID: userID)
        await viewModel.choose(.maintain)
        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)
        let stored = try await repository.loadGoals(userID: userID)
        XCTAssertEqual(stored?.source, .computed)
    }

    @MainActor
    func testEditingComputedDirectionSaveFlipsSourceToManual() async throws {
        let goal = DashboardGoal(calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .computed)
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: goal))
        let userID = UUID()
        let viewModel = GoalsEditorViewModel(repository: repository, userID: userID)
        await viewModel.choose(.maintain)
        viewModel.edit("protein", value: "155")
        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)
        let stored = try await repository.loadGoals(userID: userID)
        XCTAssertEqual(stored?.source, .manual)
    }

    @MainActor
    func testZeroGoalsMatchSetGoalsNonNegativeContract() {
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil))
        let viewModel = GoalsEditorViewModel(repository: repository, userID: UUID())
        viewModel.calories = "0"
        viewModel.protein = "0"
        viewModel.carbs = "0"
        viewModel.fat = "0"
        XCTAssertTrue(viewModel.isValid)
        XCTAssertNil(viewModel.fieldError("calories"))
    }

    @MainActor
    func testInvalidFieldProvidesSpecificValidationMessage() {
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil))
        let viewModel = GoalsEditorViewModel(repository: repository, userID: UUID())
        viewModel.edit("fat", value: "not-a-number")
        XCTAssertEqual(viewModel.fieldError("fat"), "Enter a number of 0 or more.")
    }

    @MainActor
    func testFractionalStoredGoalLoadsAndResavesWithoutRounding() async throws {
        let goal = DashboardGoal(
            calorieTargetKcal: 2000.5, proteinG: 150.2, carbsG: 200.7, fatG: 70.5, source: .manual
        )
        let repository = MockDashboardRepository(
            snapshot: DashboardSnapshot(date: Date(), meals: [], goal: goal)
        )
        let userID = UUID()
        let viewModel = GoalsEditorViewModel(repository: repository, userID: userID)
        await viewModel.load()
        XCTAssertEqual(viewModel.calories, "2000.5")
        XCTAssertEqual(viewModel.protein, "150.2")
        XCTAssertEqual(viewModel.carbs, "200.7")
        XCTAssertEqual(viewModel.fat, "70.5")
        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)
        let savedGoal = try await repository.loadGoals(userID: userID)
        let saved = try XCTUnwrap(savedGoal)
        XCTAssertEqual(saved.calorieTargetKcal, 2000.5)
        XCTAssertEqual(saved.proteinG, 150.2)
        XCTAssertEqual(saved.carbsG, 200.7)
        XCTAssertEqual(saved.fatG, 70.5)
    }

    @MainActor
    func testV3RenderContractsCoverAgentPanelSourceConsequenceAndSavedBanner() async {
        let goal = DashboardGoal(calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .computed)
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: goal))
        let viewModel = GoalsEditorViewModel(repository: repository, userID: UUID())
        await viewModel.choose(.maintain)
        XCTAssertEqual(viewModel.sourceIndicator, "writes source: computed")
        XCTAssertTrue(viewModel.whatChangesText.contains("\(MorselFormat.number(2759)) KCAL LEFT"))
        var didSeeToday = false
        let actionViewModel = GoalsEditorViewModel(
            repository: repository, userID: UUID(), onSeeToday: { didSeeToday = true }
        )
        actionViewModel.seeToday()
        XCTAssertTrue(didSeeToday)
        viewModel.edit("fat", value: "75")
        XCTAssertEqual(viewModel.sourceIndicator, "writes source: manual")
        XCTAssertTrue(viewModel.whatChangesText.contains("KCAL LEFT"))
        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)
        XCTAssertTrue(viewModel.didSave)
    }

    @MainActor
    func testV3QuantitativeConsequenceCoversUnderAndOver() {
        XCTAssertEqual(
            GoalsEditorViewModel.calorieConsequence(goal: 2100, eaten: 993),
            "\(MorselFormat.number(1107)) KCAL LEFT"
        )
        XCTAssertEqual(
            GoalsEditorViewModel.calorieConsequence(goal: 2100, eaten: 2250),
            "\(MorselFormat.number(150)) KCAL OVER"
        )
    }

    func testGoalsRepositoryEncodesRPCEnvelopeAndGuardsEverySavedField() throws {
        let userID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let input = ComputeTargetsFunctionInput(
            userID: userID, profile: DashboardProfile(
                sex: .female, ageYears: 31, heightCm: 165, weightKg: 62,
                activityLevel: .light, dietGoal: .maintain, goalWeightKg: 62
            ), dietGoal: .maintain
        )
        let encoded = try JSONEncoder().encode(ComputeTargetsRPCParams(input: input))
        let rpcBody = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(rpcBody.keys), ["p"])
        XCTAssertEqual((rpcBody["p"] as? [String: Any])?["user_id"] as? String, userID.uuidString)

        let goal = DashboardGoal(
            calorieTargetKcal: 2100, proteinG: 130, carbsG: 250, fatG: 70, source: .manual
        )
        let response = GoalResponse(
            calorieTargetKcal: 2100, proteinG: 130, carbsG: 250, fatG: 70, source: "manual"
        )
        XCTAssertTrue(SupabaseDashboardRepository.savedGoalMatches(response, goal: goal))
        let mismatches = [
            GoalResponse(calorieTargetKcal: 2099, proteinG: 130, carbsG: 250, fatG: 70, source: "manual"),
            GoalResponse(calorieTargetKcal: 2100, proteinG: 129, carbsG: 250, fatG: 70, source: "manual"),
            GoalResponse(calorieTargetKcal: 2100, proteinG: 130, carbsG: 249, fatG: 70, source: "manual"),
            GoalResponse(calorieTargetKcal: 2100, proteinG: 130, carbsG: 250, fatG: 69, source: "manual"),
            GoalResponse(calorieTargetKcal: 2100, proteinG: 130, carbsG: 250, fatG: 70, source: "computed")
        ]
        for mismatch in mismatches {
            XCTAssertFalse(SupabaseDashboardRepository.savedGoalMatches(mismatch, goal: goal))
        }
    }

    @MainActor
    func testRequiredUIConstraintAllowsDecimalValues() {
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil))
        let viewModel = GoalsEditorViewModel(repository: repository, userID: UUID())
        viewModel.calories = "2000.5"
        viewModel.protein = "150.25"
        viewModel.carbs = "200.75"
        viewModel.fat = "70.5"
        XCTAssertTrue(viewModel.isValid)
    }
}

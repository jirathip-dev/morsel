import XCTest
@testable import Morsel

@MainActor
final class GoalsRestoreTests: XCTestCase {
    private let account = UUID()

    override func setUp() {
        super.setUp()
        GoalsRestoreTransport.reset()
    }

    func testRestoreFillsExactFieldsSavesManualAndReloadsCurrent() async throws {
        let repository = try GoalsRestoreTransport.repository(userID: account)
        var notifications = 0
        let model = GoalsEditorViewModel(repository: repository, userID: account, onSaved: { notifications += 1 })
        await model.load()
        XCTAssertTrue(model.canRestorePreviousManualGoals)
        XCTAssertEqual(model.goal?.source, .computed)
        let previous = try XCTUnwrap(model.supersededManual)
        let saved = await model.restorePreviousManualGoals()
        XCTAssertTrue(saved)
        XCTAssertEqual([model.calories, model.protein, model.carbs, model.fat], ["2000.5", "104.2", "255.7", "60.1"])
        XCTAssertEqual(model.sources, ["calories": .manual, "protein": .manual, "carbs": .manual, "fat": .manual])
        XCTAssertNil(model.selectedDirection)
        XCTAssertTrue(model.didSave)
        XCTAssertNil(model.supersededNote)
        XCTAssertFalse(model.canRestorePreviousManualGoals)
        XCTAssertEqual(notifications, 1)
        let payload = try XCTUnwrap(GoalsRestoreTransport.savedPayloads().first)
        XCTAssertEqual(GoalsRestoreTransport.savedPayloads().count, 1)
        XCTAssertEqual(payload["source"] as? String, "manual")
        XCTAssertEqual(payload["user_id"] as? String, account.uuidString)
        for (key, value) in GoalsRestoreTransport.values { XCTAssertEqual(payload[key] as? Double, value) }
        let context = try await repository.loadGoalsContext(userID: account)
        let stored = try XCTUnwrap(context.stored)
        let stamp = try XCTUnwrap(stored.updatedAt)
        XCTAssertGreaterThan(stamp, previous.updatedAt)
        XCTAssertGreaterThanOrEqual(stamp, try XCTUnwrap(context.profile?.updatedAt))
        XCTAssertNil(DashboardMath.supersededManual(stored: stored, profile: context.profile))
        let effective = DashboardMath.effectiveGoal(stored: stored, profile: context.profile)
        XCTAssertEqual(effective, DashboardGoal(
            calorieTargetKcal: previous.calorieTargetKcal, proteinG: previous.proteinG,
            carbsG: previous.carbsG, fatG: previous.fatG, source: .manual
        ))
        await model.load()
        XCTAssertEqual(model.goal, effective)
        XCTAssertNil(model.supersededNote)
        XCTAssertFalse(model.canRestorePreviousManualGoals)
        let duplicate = await model.restorePreviousManualGoals()
        XCTAssertFalse(duplicate)
        XCTAssertEqual(GoalsRestoreTransport.savedPayloads().count, 1)
    }

    func testNormalEditDoesNotRestoreAndStillUsesOrdinarySave() async throws {
        let model = GoalsEditorViewModel(
            repository: try GoalsRestoreTransport.repository(userID: account), userID: account
        )
        await model.load()
        let originalCalories = model.calories
        model.edit("protein", value: "111.1")
        XCTAssertFalse(model.canRestorePreviousManualGoals)
        let restored = await model.restorePreviousManualGoals()
        XCTAssertFalse(restored)
        XCTAssertTrue(GoalsRestoreTransport.savedPayloads().isEmpty)
        XCTAssertEqual(model.calories, originalCalories)
        let saved = await model.save()
        XCTAssertTrue(saved)
        let payload = try XCTUnwrap(GoalsRestoreTransport.savedPayloads().first)
        XCTAssertEqual(payload["calorie_target_kcal"] as? Double, Double(originalCalories))
        XCTAssertEqual(payload["protein_g"] as? Double, 111.1)
        XCTAssertEqual(payload["source"] as? String, "manual")
    }

    func testAbsentSupersededRowNeverWritesOrFillsStaleValues() async throws {
        let repository = try GoalsRestoreTransport.repository(userID: account)
        let model = GoalsEditorViewModel(repository: repository, userID: account)
        await model.load()
        XCTAssertTrue(model.canRestorePreviousManualGoals)
        for source in ["computed", "manual"] {
            GoalsRestoreTransport.reset(source: source, stamp: "2099-09-07T01:00:00.000Z")
            await model.load()
            let fields = [model.calories, model.protein, model.carbs, model.fat]
            XCTAssertNil(model.supersededManual)
            XCTAssertFalse(model.canRestorePreviousManualGoals)
            let restored = await model.restorePreviousManualGoals()
            XCTAssertFalse(restored)
            XCTAssertTrue(GoalsRestoreTransport.savedPayloads().isEmpty)
            XCTAssertEqual([model.calories, model.protein, model.carbs, model.fat], fields)
        }
    }

    func testMissingIncompleteOrUndatedRowsNeverRestore() async {
        let repository = GoalsPageRequestSpy()
        repository.contextProfile = DashboardProfile(
            sex: .male, ageYears: 30, heightCm: 167, weightKg: 63,
            activityLevel: .active, dietGoal: .lose, goalWeightKg: nil, updatedAt: Date()
        )
        let model = GoalsEditorViewModel(repository: repository, userID: account)
        for stored in [
            nil,
            StoredDashboardGoal(calorieTargetKcal: 2000, proteinG: nil, carbsG: 255, fatG: 60,
                                source: .manual, updatedAt: Date(timeIntervalSince1970: 1)),
            StoredDashboardGoal(calorieTargetKcal: 2000, proteinG: 104, carbsG: 255, fatG: 60, source: .manual)
        ] {
            repository.storedGoal = stored
            await model.load()
            let restored = await model.restorePreviousManualGoals()
            XCTAssertFalse(restored)
            XCTAssertFalse(model.canRestorePreviousManualGoals)
            XCTAssertNil(repository.savedGoal)
        }
    }

    func testLegacyPrecisionIsNotSilentlyRoundedOrWritten() async throws {
        GoalsRestoreTransport.reset(protein: 104.25)
        let model = GoalsEditorViewModel(
            repository: try GoalsRestoreTransport.repository(userID: account), userID: account
        )
        await model.load()
        let saved = await model.restorePreviousManualGoals()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.protein, "104.25")
        XCTAssertEqual(model.sources["protein"], .manual)
        XCTAssertEqual(model.fieldError("protein"), "One decimal is plenty — 2000.5 not 2000.55")
        XCTAssertTrue(GoalsRestoreTransport.savedPayloads().isEmpty)
        XCTAssertFalse(model.didSave)
    }

    func testSaveFailureDoesNotClaimSuccessOrRemoveShortcut() async throws {
        GoalsRestoreTransport.failWrites()
        var notifications = 0
        let model = GoalsEditorViewModel(
            repository: try GoalsRestoreTransport.repository(userID: account), userID: account,
            onSaved: { notifications += 1 }
        )
        await model.load()
        let saved = await model.restorePreviousManualGoals()
        XCTAssertFalse(saved)
        XCTAssertFalse(model.didSave)
        XCTAssertFalse(model.isSaving)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.canRestorePreviousManualGoals)
        XCTAssertEqual(notifications, 0)
    }

    func testDirectionChoiceClearsShortcutAndPreservesComputedSave() async throws {
        let repository = GoalsPageRequestSpy()
        repository.storedGoal = StoredDashboardGoal(
            calorieTargetKcal: 2000, proteinG: 104, carbsG: 255, fatG: 60, source: .manual,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        repository.contextProfile = DashboardProfile(
            sex: .male, ageYears: 30, heightCm: 167, weightKg: 63,
            activityLevel: .active, dietGoal: .lose, goalWeightKg: nil, updatedAt: Date()
        )
        let model = GoalsEditorViewModel(repository: repository, userID: account)
        await model.load()
        for direction in GoalDirection.allCases {
            await model.choose(direction)
            XCTAssertFalse(model.canRestorePreviousManualGoals)
            let restored = await model.restorePreviousManualGoals()
            XCTAssertFalse(restored)
            let saved = await model.save()
            XCTAssertTrue(saved)
            XCTAssertEqual(repository.savedGoal?.source, .computed)
            XCTAssertEqual(model.selectedDirection, direction)
        }
    }
}

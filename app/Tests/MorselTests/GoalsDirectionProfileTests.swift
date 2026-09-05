import XCTest
@testable import Morsel

// Issue #123 — documented behavior for the direction chips when the goal
// on screen is MANUAL (head-only: pins the new `profileDirection` surface,
// proven discriminating by a head mutation run; the base-RED set lives in
// GoalsPolishTests.swift, which compiles at the pristine base).
//
// Chosen and pinned behavior: the filled chip is derived ONLY when the
// effective goal is computed (lose→cut / maintain→maintain / gain→bulk).
// A current manual goal fills NO chip — its numbers are typed, not chosen —
// and the profile's own phase renders as the lighter "profile" hint chip
// (`profileDirection`), with no hint chip when there is no profile row.

final class GoalsDirectionProfileTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        ) ?? Date(timeIntervalSince1970: 0)
    }

    private func profile(dietGoal: ProfileDietGoal, updatedAt: Date) -> DashboardProfile {
        DashboardProfile(
            sex: .male, ageYears: 30, heightCm: 167, weightKg: 63,
            activityLevel: .active, dietGoal: dietGoal, goalWeightKg: nil,
            updatedAt: updatedAt
        )
    }

    @MainActor
    private func makeViewModel(
        stored: StoredDashboardGoal?, profile: DashboardProfile?
    ) -> GoalsEditorViewModel {
        let repository = MockDashboardRepository(
            snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil)
        )
        repository.seedGoalsContext(profile: profile, latestWeight: nil)
        if let stored {
            repository.seedStoredGoal(stored)
        }
        return GoalsEditorViewModel(repository: repository, userID: UUID())
    }

    func testGoalDirectionMapsProfileDietGoals() {
        XCTAssertEqual(GoalDirection(profileDietGoal: .lose), .cut)
        XCTAssertEqual(GoalDirection(profileDietGoal: .maintain), .maintain)
        XCTAssertEqual(GoalDirection(profileDietGoal: .gain), .bulk)
    }

    @MainActor
    func testCurrentManualGoalFillsNoChipAndExposesTheProfileDirectionHint() async {
        let manual = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 100, carbsG: 0, fatG: 0,
            source: .manual, updatedAt: date(2026, 9, 5, 9)
        )
        let profile = self.profile(dietGoal: .lose, updatedAt: date(2026, 9, 5, 7))
        let viewModel = makeViewModel(stored: manual, profile: profile)

        await viewModel.load()

        // Manual numbers stay effective (manual row newer than the profile).
        XCTAssertEqual(viewModel.calories, "2000.0")
        XCTAssertEqual(viewModel.sources["calories"], .manual)
        // No chip is FILLED — the numbers were typed, not chosen…
        XCTAssertNil(viewModel.selectedDirection)
        // …and the lose profile renders the lighter Cut "profile" hint.
        XCTAssertEqual(viewModel.profileDirection, .cut)
        XCTAssertNil(viewModel.fieldError("calories"))
    }

    @MainActor
    func testMaintainProfileHintMapsManualGoalToMaintainChip() async {
        let manual = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 100, carbsG: 0, fatG: 0,
            source: .manual, updatedAt: date(2026, 9, 5, 9)
        )
        let profile = self.profile(dietGoal: .maintain, updatedAt: date(2026, 9, 5, 7))
        let viewModel = makeViewModel(stored: manual, profile: profile)

        await viewModel.load()

        XCTAssertNil(viewModel.selectedDirection)
        XCTAssertEqual(viewModel.profileDirection, .maintain)
    }

    @MainActor
    func testManualGoalWithoutProfileShowsNoDirectionAtAll() async {
        let manual = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 100, carbsG: 0, fatG: 0, source: .manual
        )
        let viewModel = makeViewModel(stored: manual, profile: nil)

        await viewModel.load()

        XCTAssertNil(viewModel.selectedDirection)
        XCTAssertNil(viewModel.profileDirection, "no profile row — no hint chip")
    }

    @MainActor
    func testProfileOnlyShowsHintChipWithNoGoalYet() async {
        let profile = self.profile(dietGoal: .lose, updatedAt: date(2026, 9, 5, 7))
        let viewModel = makeViewModel(stored: nil, profile: profile)

        await viewModel.load()

        XCTAssertTrue(viewModel.calories.isEmpty)
        XCTAssertNil(viewModel.selectedDirection)
        XCTAssertEqual(viewModel.profileDirection, .cut)
        XCTAssertNil(viewModel.fieldError("calories"))
    }

    @MainActor
    func testStaleManualSupersededByProfileFillsTheDerivedChip() async {
        // The profile changed AFTER the manual row: computed targets are
        // effective, so the lose profile's Cut chip is FILLED (not the
        // lighter hint) and the superseded note still appears.
        let staleManual = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 100, carbsG: 0, fatG: 0,
            source: .manual, updatedAt: date(2026, 9, 5, 7)
        )
        let profile = self.profile(dietGoal: .lose, updatedAt: date(2026, 9, 5, 9))
        let viewModel = makeViewModel(stored: staleManual, profile: profile)

        await viewModel.load()

        XCTAssertEqual(viewModel.sources["calories"], .computed)
        XCTAssertEqual(viewModel.selectedDirection, .cut)
        XCTAssertEqual(viewModel.profileDirection, .cut)
        XCTAssertNotNil(viewModel.supersededNote)
    }
}

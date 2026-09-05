import XCTest
@testable import Morsel

// Issue #113 app parts — Goals page recency behavior (superseded note,
// computed prefill, read-only profile line) and the calm copy builders,
// including the amendment C margin note.

final class GoalsEditorRecencyTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        ) ?? Date(timeIntervalSince1970: 0)
    }

    private func profile(weightKg: Double = 63, updatedAt: Date) -> DashboardProfile {
        DashboardProfile(
            sex: .male, ageYears: 30, heightCm: 167, weightKg: weightKg,
            activityLevel: .active, dietGoal: .lose, goalWeightKg: nil,
            updatedAt: updatedAt
        )
    }

    private func staleManual() -> StoredDashboardGoal {
        StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 100, carbsG: 0, fatG: 0,
            source: .manual, updatedAt: date(2026, 9, 5, 7)
        )
    }

    @MainActor
    private func makeViewModel(
        stored: StoredDashboardGoal?, profile: DashboardProfile?, weight: SyncedWeightSample?
    ) -> (GoalsEditorViewModel, MockDashboardRepository) {
        let repository = MockDashboardRepository(
            snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil)
        )
        repository.seedGoalsContext(profile: profile, latestWeight: weight)
        if let stored {
            repository.seedStoredGoal(stored)
        }
        return (GoalsEditorViewModel(repository: repository, userID: UUID()), repository)
    }

    @MainActor
    func testProfileUpdateSupersedesStaleManualWithComputedPrefillAndNote() async {
        let profile = self.profile(updatedAt: date(2026, 9, 5, 9))
        let weight = SyncedWeightSample(kilograms: 61.5, measuredAt: date(2026, 9, 5, 6))
        let (viewModel, _) = makeViewModel(stored: staleManual(), profile: profile, weight: weight)

        await viewModel.load()

        let computed = DashboardMath.computedGoal(for: profile, latestWeightKg: 61.5)
        XCTAssertEqual(viewModel.calories, GoalsEditorViewModel.displayValue(computed.calorieTargetKcal))
        XCTAssertEqual(viewModel.protein, GoalsEditorViewModel.displayValue(computed.proteinG))
        XCTAssertEqual(viewModel.carbs, GoalsEditorViewModel.displayValue(computed.carbsG))
        XCTAssertEqual(viewModel.fat, GoalsEditorViewModel.displayValue(computed.fatG))
        XCTAssertEqual(viewModel.sources["calories"], .computed)
        XCTAssertEqual(viewModel.sourceIndicator, "writes source: computed")
        XCTAssertEqual(
            viewModel.supersededNote,
            "your profile changed on 5 Sep; these are the new computed targets"
                + " — your earlier manual numbers were 2,000 / 100 / 0 / 0"
        )
    }

    @MainActor
    func testUneditedSaveAfterSupersedeKeepsComputedSource() async throws {
        let profile = self.profile(updatedAt: date(2026, 9, 5, 9))
        let userID = UUID()
        let repository = MockDashboardRepository(
            snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil)
        )
        repository.seedGoalsContext(profile: profile, latestWeight: nil)
        repository.seedStoredGoal(staleManual())
        let viewModel = GoalsEditorViewModel(repository: repository, userID: userID)

        await viewModel.load()
        let didSave = await viewModel.save()

        XCTAssertTrue(didSave)
        XCTAssertNil(viewModel.supersededNote)
        let stored = try await repository.loadGoals(userID: userID)
        XCTAssertEqual(stored?.source, .computed)
    }

    @MainActor
    func testCurrentManualGoalKeepsItsNumbersAndHidesNote() async {
        let manual = StoredDashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 100, carbsG: 0, fatG: 0,
            source: .manual, updatedAt: date(2026, 9, 5, 9)
        )
        let profile = self.profile(updatedAt: date(2026, 9, 5, 7))
        let (viewModel, _) = makeViewModel(stored: manual, profile: profile, weight: nil)

        await viewModel.load()

        XCTAssertEqual(viewModel.calories, "2000.0")
        XCTAssertEqual(viewModel.protein, "100.0")
        XCTAssertEqual(viewModel.sources["calories"], .manual)
        XCTAssertNil(viewModel.supersededNote)
    }

    @MainActor
    func testEditingOrChoosingClearsTheSupersededNote() async {
        let profile = self.profile(updatedAt: date(2026, 9, 5, 9))
        let (viewModel, _) = makeViewModel(stored: staleManual(), profile: profile, weight: nil)

        await viewModel.load()
        XCTAssertNotNil(viewModel.supersededNote)

        viewModel.edit("protein", value: "110")
        XCTAssertNil(viewModel.supersededNote)

        await viewModel.load()
        XCTAssertNotNil(viewModel.supersededNote)
        await viewModel.choose(.maintain)
        XCTAssertNil(viewModel.supersededNote)
    }

    @MainActor
    func testNoProfileYetCopyRendersWithoutStoredRow() async {
        let (viewModel, _) = makeViewModel(stored: nil, profile: nil, weight: nil)

        await viewModel.load()

        XCTAssertEqual(
            viewModel.profileLine,
            "no profile yet — tell your agent your height, weight, age and activity"
        )
        XCTAssertTrue(viewModel.calories.isEmpty)
    }
}

final class GoalsPageCopyTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        ) ?? Date(timeIntervalSince1970: 0)
    }

    private func context(profile: DashboardProfile?, latestWeight: SyncedWeightSample? = nil) -> GoalsPageContext {
        GoalsPageContext(
            stored: nil, profile: profile, latestWeight: latestWeight, profileRowRead: true
        )
    }

    func testProfileLineShowsHealthWeightSourceAndProfileFacts() {
        let profile = DashboardProfile(
            sex: .male, ageYears: 30, heightCm: 167, weightKg: 63,
            activityLevel: .active, dietGoal: .lose, goalWeightKg: nil,
            updatedAt: date(2026, 9, 5, 9, 0)
        )
        let weight = SyncedWeightSample(kilograms: 61.5, measuredAt: date(2026, 9, 5, 6, 30))

        XCTAssertEqual(
            GoalsPageCopy.profileLine(context: context(profile: profile, latestWeight: weight)),
            "computed from 61.5 kg (Health · 5 Sep) · 167 cm · 30 y · active · lose"
                + " — set via your agent 5 Sep"
        )
    }

    func testProfileLineFallsBackToTypedWeightWithoutHealthSample() {
        let profile = DashboardProfile(
            sex: .female, ageYears: 31, heightCm: 165, weightKg: 63,
            activityLevel: .light, dietGoal: .maintain, goalWeightKg: nil,
            updatedAt: nil
        )

        XCTAssertEqual(
            GoalsPageCopy.profileLine(context: context(profile: profile)),
            "computed from 63 kg (profile) · 165 cm · 31 y · light · maintain"
        )
    }

    func testProfileLineNoProfileCopyOnlyWhenProfileTableWasRead() {
        XCTAssertEqual(
            GoalsPageCopy.profileLine(context: context(profile: nil)),
            "no profile yet — tell your agent your height, weight, age and activity"
        )
        XCTAssertNil(
            GoalsPageCopy.profileLine(
                context: GoalsPageContext(stored: nil, profile: nil, latestWeight: nil, profileRowRead: false)
            )
        )
    }

    func testMarginNoteShowsAppleHealthSourceAndLastImportTime() {
        let stamp = date(2026, 9, 5, 7, 32)

        XCTAssertEqual(
            ActiveEnergyMarginNote.line(totalKcal: 412, lastImport: stamp),
            "moved 412 kcal · Apple Health · 07:32"
        )
    }

    func testMarginNoteStaysHiddenAtZeroAndKeepsLegacyCopyWithoutStamp() {
        XCTAssertNil(ActiveEnergyMarginNote.line(totalKcal: 0, lastImport: date(2026, 9, 5, 7, 32)))
        XCTAssertNil(ActiveEnergyMarginNote.line(totalKcal: -1, lastImport: nil))
        XCTAssertEqual(
            ActiveEnergyMarginNote.line(totalKcal: 412, lastImport: nil),
            "moved 412 kcal today"
        )
    }

    @MainActor
    func testViewModelExposesTheCalmStatusStampForTheMarginNote() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalHealthStore(databaseURL: directory.appendingPathComponent("health.sqlite"))
        let stamp = date(2026, 9, 5, 7, 32)
        try store.setLastSuccessfulUpload(stamp)

        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil))
        let viewModel = DashboardViewModel(repository: repository, userID: UUID(), healthStore: store)

        XCTAssertEqual(viewModel.lastHealthImportDate, stamp)
    }
}

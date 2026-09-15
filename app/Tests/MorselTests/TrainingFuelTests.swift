import XCTest
@testable import Morsel

@MainActor
final class TrainingFuelTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_789_300_800)
    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    private func snapshot(_ source: GoalSource = .computed, date: Date? = nil) -> DashboardSnapshot {
        DashboardSnapshot(date: date ?? today, meals: [MealRecord(
            mealLogID: UUID(), mealType: .lunch, eatenAt: today, source: .manual, items: []
        )], goal: DashboardGoal(calorieTargetKcal: 2_000, proteinG: 90, carbsG: 250, fatG: 60, source: source),
        activeEnergyBurned: 820)
    }

    private func model() -> TrainingFuelModel { TrainingFuelModel(calendar: calendar, now: { self.today }) }

    func testBlankExplicitConfirmEditUndoPreservesMealsAndGoal() async {
        let subject = model()
        let original = snapshot()
        subject.synchronize(original)
        subject.longerDay = true
        subject.beginReview()
        XCTAssertEqual(subject.draft, "")
        XCTAssertFalse(subject.canConfirm)
        await subject.confirm()
        XCTAssertNil(subject.addition)
        subject.draft = "271.5"
        XCTAssertEqual(subject.target, 2_000, "typing and hard context are not confirmation")
        await subject.confirm()
        XCTAssertEqual(subject.target, 2_271.5)
        XCTAssertEqual(subject.baseline, original.goal)
        subject.beginReview()
        XCTAssertEqual(Double(subject.draft), 271.5)
        subject.draft = "180"
        await subject.confirm()
        XCTAssertEqual(subject.target, 2_180)
        subject.undo()
        XCTAssertEqual(subject.target, 2_000)
        XCTAssertNil(subject.addition)
        XCTAssertEqual(original.meals.count, 1)
        XCTAssertEqual(original.goal?.calorieTargetKcal, 2_000)
        XCTAssertEqual(original.activeEnergyBurned, 820)
        subject.beginReview()
        XCTAssertEqual(subject.draft, "")
    }

    func testManualAcknowledgementIsUncheckedAndRequiredEveryTime() async {
        let subject = model()
        subject.synchronize(snapshot())
        subject.synchronize(snapshot(.manual))
        subject.beginReview()
        subject.draft = "125"
        XCTAssertFalse(subject.acknowledgesDayOnly)
        XCTAssertFalse(subject.canConfirm)
        await subject.confirm()
        XCTAssertEqual(subject.target, 2_000)
        subject.acknowledgesDayOnly = true
        await subject.confirm()
        XCTAssertEqual(subject.target, 2_125)
        subject.beginReview()
        XCTAssertFalse(subject.acknowledgesDayOnly)
        XCTAssertFalse(subject.canConfirm)
        subject.cancel()
        XCTAssertEqual(subject.target, 2_125)
        XCTAssertEqual(subject.baseline?.source, .manual)
        subject.undo()
        XCTAssertEqual(subject.baseline?.calorieTargetKcal, 2_000)
    }

    func testPendingFailureRetainsDraftAndExistingConfirmation() async {
        let gate = TrainingFuelTestGate()
        let subject = TrainingFuelModel(calendar: calendar, now: { self.today }, accept: { try await gate.wait() })
        subject.synchronize(snapshot())
        subject.beginReview()
        subject.draft = "111"
        let first = Task { await subject.confirm() }
        await gate.entered()
        XCTAssertTrue(subject.isPending)
        XCTAssertEqual(subject.target, 2_000)
        gate.finish()
        await first.value
        XCTAssertEqual(subject.target, 2_111)
        subject.beginReview()
        subject.draft = "222"
        let second = Task { await subject.confirm() }
        await gate.entered()
        XCTAssertEqual(subject.target, 2_111)
        gate.finish(failing: true)
        await second.value
        XCTAssertFalse(subject.isPending)
        XCTAssertNotNil(subject.error)
        XCTAssertEqual(subject.draft, "222")
        XCTAssertEqual(subject.target, 2_111)
        subject.cancel()
        XCTAssertEqual(subject.target, 2_111)
    }

    func testCancelPendingDiscardsLateSuccessAndDoesNotApply() async {
        let gate = TrainingFuelTestGate()
        let subject = TrainingFuelModel(calendar: calendar, now: { self.today }, accept: { try await gate.wait() })
        subject.synchronize(snapshot())
        subject.beginReview()
        subject.draft = "125"
        let save = Task { await subject.confirm() }
        await gate.entered()
        subject.cancel()
        gate.finish()
        await save.value
        XCTAssertEqual(subject.target, 2_000)
        XCTAssertNil(subject.addition)
    }

    func testPastDatedSnapshotAndNextDayNeverBorrowTheCurrentGoal() async {
        var clock = today
        let subject = TrainingFuelModel(calendar: calendar, now: { clock })
        subject.synchronize(snapshot(date: today.addingTimeInterval(-86_400)))
        XCTAssertNil(subject.target)
        subject.synchronize(snapshot())
        subject.beginReview()
        subject.draft = "137"
        await subject.confirm()
        let confirmed = subject.baseline
        clock = today.addingTimeInterval(86_400)
        // Issue #254 — the confirmed note belongs to the day it was confirmed
        // for. After a rollover nothing about the previous day is presented as
        // the new day's note, with or without a refresh.
        XCTAssertFalse(subject.isCurrentDay)
        XCTAssertNil(subject.addition)
        XCTAssertNil(subject.baseline)
        XCTAssertNil(subject.target)
        subject.beginReview()
        XCTAssertFalse(subject.isEditing)
        subject.undo()
        XCTAssertNil(subject.addition)
        let next = DashboardSnapshot(date: clock, meals: [], goal: DashboardGoal(
            calorieTargetKcal: 2_100, proteinG: 95, carbsG: 250, fatG: 60, source: .computed))
        subject.synchronize(next)
        XCTAssertEqual(subject.target, 2_100)
        XCTAssertNotEqual(subject.baseline, confirmed, "the new day never borrows the previous day's note")
    }

    func testTodayBaselineRevisionTakesEffectAndPreservesTheConfirmedAddition() async {
        let subject = model()
        subject.synchronize(snapshot())
        subject.beginReview()
        subject.draft = "137"
        await subject.confirm()
        XCTAssertEqual(subject.target, 2_137)
        // Confirmed contract: a goal observed for TODAY is a baseline revision.
        // It takes effect today, keeps the confirmed addition, and the revised
        // total is shown. No past date is rewritten.
        let revised = DashboardSnapshot(date: today, meals: [MealRecord(
            mealLogID: UUID(), mealType: .lunch, eatenAt: today, source: .manual, items: [])],
            goal: DashboardGoal(calorieTargetKcal: 2_500, proteinG: 100, carbsG: 250, fatG: 70, source: .manual))
        subject.synchronize(revised)
        XCTAssertEqual(subject.baseline?.calorieTargetKcal, 2_500)
        XCTAssertEqual(subject.addition, 137, "a baseline revision preserves the confirmed addition")
        XCTAssertEqual(subject.target, 2_637)
        XCTAssertEqual(revised.goal?.calorieTargetKcal, 2_500, "the revision never writes the goal")
        subject.beginReview()
        subject.draft = "63"
        subject.acknowledgesDayOnly = true
        await subject.confirm()
        XCTAssertEqual(subject.addition, 63)
        XCTAssertEqual(subject.target, 2_563)
    }

    func testDuplicateConfirmAndOfflineRetryApplyTheNoteExactlyOnce() async {
        let gate = TrainingFuelTestGate()
        var accepted = 0
        let subject = TrainingFuelModel(calendar: calendar, now: { self.today }, accept: {
            accepted += 1
            try await gate.wait()
        })
        subject.synchronize(snapshot())
        subject.beginReview()
        subject.draft = "150"
        let first = Task { await subject.confirm() }
        await gate.entered()
        await subject.confirm() // duplicate confirm while the first is pending
        gate.finish()
        await first.value
        XCTAssertEqual(accepted, 1, "a duplicate confirm never applies the note twice")
        XCTAssertEqual(subject.addition, 150)
        XCTAssertEqual(subject.target, 2_150)

        var attempts = 0
        let retried = TrainingFuelModel(calendar: calendar, now: { self.today }, accept: {
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteUnknown) }
        })
        retried.synchronize(snapshot())
        retried.beginReview()
        retried.draft = "225"
        await retried.confirm() // offline failure
        XCTAssertNil(retried.addition)
        XCTAssertEqual(retried.target, 2_000)
        XCTAssertEqual(retried.draft, "225", "a failure retains the draft")
        XCTAssertNotNil(retried.error)
        XCTAssertTrue(retried.isEditing)
        await retried.confirm() // retry
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(retried.addition, 225)
        XCTAssertEqual(retried.target, 2_225)
        XCTAssertNil(retried.error)
        XCTAssertFalse(retried.isEditing)
    }

    func testUndoNeverTouchesTheBaselineMealsOrHealthContext() async {
        let subject = model()
        let original = snapshot()
        subject.synchronize(original)
        let reading = TrainingFuelReading(value: "415 kcal", sampleDate: today,
                                          source: "Apple Health · active energy", checkedAt: today)
        subject.context = TrainingFuelContext(movement: reading, workout: nil)
        subject.longerDay = true
        subject.beginReview()
        subject.draft = "271.5"
        await subject.confirm()
        XCTAssertEqual(subject.addition, 271.5)
        subject.undo()
        XCTAssertNil(subject.addition)
        XCTAssertEqual(subject.target, 2_000)
        XCTAssertEqual(subject.baseline, original.goal)
        XCTAssertEqual(subject.context.movement, reading)
        XCTAssertEqual(subject.context.workout, nil)
        XCTAssertEqual(original.meals.count, 1)
        XCTAssertEqual(original.goal?.calorieTargetKcal, 2_000)
        XCTAssertEqual(original.activeEnergyBurned, 820)
    }

    func testInvalidNumbersCannotBecomeAdjustments() async {
        let subject = model()
        subject.synchronize(snapshot())
        subject.beginReview()
        for input in ["", " ", "-5", "0", "NaN", "inf", "1e999", "food"] {
            subject.draft = input
            XCTAssertFalse(subject.canConfirm, input)
            await subject.confirm()
            XCTAssertEqual(subject.target, 2_000)
        }
    }

    func testMissingAndStaleHealthKeepRealDatesAndSeparateProvenance() {
        let staleDate = today.addingTimeInterval(-86_400)
        let reading = TrainingFuelReading(value: "415 kcal", sampleDate: staleDate,
                                          source: "Apple Health · active energy", checkedAt: today)
        let workout = TrainingFuelReading(value: "Run · 40 min", sampleDate: today,
                                          source: "Apple Health · Watch", checkedAt: today.addingTimeInterval(90))
        let context = TrainingFuelContext(movement: reading, workout: workout)
        XCTAssertEqual(TrainingFuelContext.value(nil), "Unavailable")
        XCTAssertEqual(TrainingFuelContext.value(context.movement), "415 kcal")
        XCTAssertTrue(reading.detail(for: today).contains("Last known · not today's total"))
        XCTAssertTrue(reading.detail(for: today).contains(staleDate.formatted(date: .abbreviated, time: .shortened)))
        XCTAssertTrue(workout.detail(for: today).contains("Watch"))
        let checked = workout.checkedAt.formatted(date: .abbreviated, time: .shortened)
        XCTAssertTrue(workout.detail(for: today).contains(checked))
        XCTAssertFalse(workout.detail(for: today).contains("Last known"))
    }

    func testATrueZeroReadingIsNeverRenderedAsMissingHealth() {
        let zero = TrainingFuelReading(value: "0 kcal", sampleDate: today,
                                       source: "Apple Health · active energy", checkedAt: today)
        let context = TrainingFuelContext(movement: zero, workout: nil)
        XCTAssertEqual(TrainingFuelContext.value(context.movement), "0 kcal")
        XCTAssertEqual(TrainingFuelContext.value(nil), "Unavailable")
        XCTAssertNotEqual(TrainingFuelContext.value(context.movement), TrainingFuelContext.value(nil),
                          "a real zero is not missing, denied or unavailable Health")
        XCTAssertTrue(zero.detail(for: today).contains("Recorded"))
        XCTAssertFalse(zero.detail(for: today).contains("Last known"))
        XCTAssertEqual(TrainingFuelContext.value(context.workout), "Unavailable",
                       "separate types stay separate: no Movement value stands in for a workout")
    }
}

/// Fix round 1 — the reachable path that wiped today's baseline: a locally
/// queued meal is painted before any dashboard read, so ViewModel.swift
/// publishes a today-dated snapshot whose goal is absent and
/// TrainingFuelHost.swift forwards it to the model. Its own class keeps
/// `TrainingFuelTests` inside the type-body budget.
@MainActor
final class TrainingFuelNilGoalRegressionTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_789_300_800)

    func testAbsentGoalSnapshotFromAQueuedMealPaintKeepsBaselineAndConfirmation() async {
        let subject = TrainingFuelModel(calendar: Calendar(identifier: .gregorian), now: { self.today })
        subject.synchronize(DashboardSnapshot(date: today, meals: [], goal: DashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 90, carbsG: 250, fatG: 60, source: .computed)))
        XCTAssertEqual(subject.target, 2_000)
        let record = MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: today, source: .manual, items: [])
        let viewModel = DashboardViewModel(repository: QueuedMealWithoutGoalRepository(record: record),
                                           userID: UUID(), dateProvider: { self.today })
        let saved = await viewModel.addMeal(
            draft: MealDraft(mealType: .lunch, eatenAt: today, notes: nil, items: []), photo: nil)
        XCTAssertTrue(saved)
        XCTAssertNil(viewModel.errorMessage)
        let published = viewModel.snapshot
        XCTAssertNil(published?.goal, "the queued-meal paint publishes a today-dated snapshot with no goal")
        subject.synchronize(published, calendar: .autoupdatingCurrent) // TrainingFuelHost.swift forwards this
        XCTAssertEqual(subject.baseline?.calorieTargetKcal, 2_000, "an absent goal is not an observation")
        XCTAssertEqual(subject.target, 2_000)
        subject.beginReview()
        subject.draft = "150"
        XCTAssertTrue(subject.canConfirm, "an absent goal must not disable confirmation")
        await subject.confirm()
        XCTAssertEqual(subject.target, 2_150)
        subject.synchronize(DashboardSnapshot(date: today, meals: [], goal: nil))
        XCTAssertEqual(subject.addition, 150, "a confirmed addition survives an absent-goal snapshot")
        XCTAssertEqual(subject.target, 2_150)
    }
}

@MainActor
private final class TrainingFuelTestGate {
    private var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func entered() async {
        for _ in 0..<1_000 {
            if continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Confirmation did not reach its pending boundary")
    }
    func finish(failing: Bool = false) {
        let waiting = continuation
        continuation = nil
        if failing { waiting?.resume(throwing: CocoaError(.fileWriteUnknown)) } else { waiting?.resume() }
    }
}

/// Fix round 1 — the repository state behind ViewModel.swift's queued-meal
/// paint: the meal is committed locally, no dashboard read has produced a
/// snapshot yet, and the follow-up reload fails rather than supplying a goal.
private final class QueuedMealWithoutGoalRepository: DashboardRepository {
    private let record: MealRecord

    init(record: MealRecord) {
        self.record = record
    }

    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        record.mealLogID
    }

    func localMealRecord(userID: UUID, localMealID: UUID) async throws -> MealRecord? { record }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        throw MorselError.requestFailed(503, "dashboard read not available yet")
    }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        throw MorselError.requestFailed(503, "dashboard read not available yet")
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        throw MorselError.requestFailed(503, "goals read not available yet")
    }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
}

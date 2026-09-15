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

    func testNoCurrentGoalIsInventedForOldDatesOrNextDay() async {
        var clock = today
        let subject = TrainingFuelModel(calendar: calendar, now: { clock })
        subject.synchronize(snapshot(date: today.addingTimeInterval(-86_400)))
        XCTAssertNil(subject.target)
        subject.synchronize(snapshot())
        subject.beginReview()
        subject.draft = "137"
        await subject.confirm()
        let baseline = subject.baseline
        let changed = DashboardSnapshot(date: today, meals: [], goal: DashboardGoal(
            calorieTargetKcal: 2_500, proteinG: 100, carbsG: 250, fatG: 70, source: .manual))
        subject.synchronize(changed)
        XCTAssertEqual(subject.baseline, baseline)
        XCTAssertEqual(subject.target, 2_137)
        clock = today.addingTimeInterval(86_400)
        XCTAssertNil(subject.target)
        subject.synchronize(changed)
        XCTAssertNil(subject.target)
        XCTAssertNil(subject.addition)
        XCTAssertEqual(changed.goal?.calorieTargetKcal, 2_500)
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

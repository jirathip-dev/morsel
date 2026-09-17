import XCTest
@testable import Morsel

// Issue #190 — the Goals save is acknowledged by its own write. The day read is
// invalidated (`invalidateDayAfterConfirmedGoals`, the shell's `onSaved`
// wiring) and never awaited, so a slow dashboard cannot hold the Save control
// in its saving state. This suite uses that new entry point, so the base leg
// runs `base-probe/GoalsWiringBaseProbe.swift` instead (identical composition
// with the BASE shell wiring).

final class WriteAckGoalsTests: WriteAckTestCase {
    private func goals(onSaved: @escaping () async -> Void) -> GoalsEditorViewModel {
        GoalsEditorViewModel(repository: WriteAckRepository(harness: harness), userID: account,
                             now: { self.date }, onSaved: onSaved)
    }

    private func draft(_ model: GoalsEditorViewModel) {
        model.calories = "2200.0"
        model.protein = "160.0"
        model.carbs = "210.0"
        model.fat = "75.0"
    }

    func testGoalsSaveFinishesWithoutWaitingForTheDashboardRead() async {
        let day = DashboardViewModel(repository: WriteAckRepository(harness: harness), userID: account,
                                     dateProvider: { self.date })
        let model = goals(onSaved: { day.invalidateDayAfterConfirmedGoals() })
        draft(model)

        var saved: Bool?
        let save = Task { saved = await model.save() }
        await until("the confirmed Goals save finishes with the day read blocked") { saved != nil }

        XCTAssertEqual(saved, true)
        XCTAssertTrue(model.didSave, "the acknowledged save is reported on its own")
        XCTAssertFalse(model.isSaving, "the Save control leaves its saving state")
        XCTAssertEqual(harness.writeLog, ["goals"], "the goals row is written once")
        XCTAssertTrue(day.isLoading, "the invalidated day read is admitted, never awaited")
        XCTAssertEqual(harness.readDates.count, 1)
        save.cancel()
    }

    func testConfirmedGoalsSaveSurvivesALaterFailedRefresh() async {
        let day = DashboardViewModel(repository: WriteAckRepository(harness: harness), userID: account,
                                     dateProvider: { self.date })
        let model = goals(onSaved: { day.invalidateDayAfterConfirmedGoals() })
        draft(model)

        var saved: Bool?
        let save = Task { saved = await model.save() }
        await until("the invalidated read is admitted") { harness.readDates.count == 1 }
        await until("the confirmed save finishes with the read parked") { saved != nil }
        XCTAssertEqual(saved, true)
        harness.fail(0, MorselError.configurationMissing)
        await until("the failed read settles") { !day.isLoading }

        XCTAssertTrue(model.didSave, "a later refresh failure cannot unset the acknowledged save")
        XCTAssertNil(model.errorMessage, "the goals error belongs to the goals write")
        XCTAssertFalse(model.isSaving)
        save.cancel()
    }

    func testRejectedGoalsSaveKeepsTheDraftAndReportsTheRefusal() async {
        let day = DashboardViewModel(repository: WriteAckRepository(harness: harness), userID: account,
                                     dateProvider: { self.date })
        let model = goals(onSaved: { day.invalidateDayAfterConfirmedGoals() })
        draft(model)
        harness.refusal = MorselError.requestFailed(503, "raw backend text")

        let saved = await model.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(model.errorMessage, "The request could not be completed. Try again.")
        XCTAssertEqual(model.calories, "2200.0", "the draft keeps what the user typed")
        XCTAssertFalse(model.didSave)
        XCTAssertFalse(model.isSaving)
        XCTAssertTrue(harness.readDates.isEmpty, "a refused save invalidates nothing")
    }

    func testDoubleTapOnGoalsSaveIssuesOneMutation() async {
        let day = DashboardViewModel(repository: WriteAckRepository(harness: harness), userID: account,
                                     dateProvider: { self.date })
        let model = goals(onSaved: { day.invalidateDayAfterConfirmedGoals() })
        draft(model)

        var left: Bool?
        var right: Bool?
        let taps = [Task { left = await model.save() }, Task { right = await model.save() }]
        await until("both taps resolve") { left != nil && right != nil }

        XCTAssertEqual(harness.writeLog, ["goals"], "a repeated tap issues no second mutation")
        XCTAssertEqual(left, true)
        XCTAssertFalse(model.isSaving)
        for tap in taps { tap.cancel() }
    }

    /// The shipped shell must use the non-blocking wiring, not the old await.
    func testMorselAppGoalsWiringUsesTheConfirmedInvalidation() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/Morsel/MorselApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("onSaved: { viewModel.invalidateDayAfterConfirmedGoals() }"))
        XCTAssertFalse(source.contains("onSaved: { await viewModel.invalidateDay() }"),
                       "the Goals save must not await a full dashboard reload")
    }
}

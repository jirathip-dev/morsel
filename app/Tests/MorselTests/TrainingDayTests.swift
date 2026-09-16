import SwiftUI
import XCTest
@testable import Morsel

@MainActor
final class TrainingDayTests: XCTestCase {
    func testEveryNamedMatrixStateIsReachableWithoutChangingTheTargetFromContext() async {
        XCTAssertEqual(TrainingDayFixture.states.count, 30)
        XCTAssertEqual(Set(TrainingDayFixture.states).count, 30)
        for state in TrainingDayFixture.states {
            let fixture = TrainingDayFixture(state)
            await fixture.prepare()
            let model = fixture.model
            let unavailable = ["unavailable", "unavailable-sheet", "loading", "error", "rollover"].contains(state)
            let confirmed = ["confirmed", "confirmed-sheet", "edit"].contains(state)
            XCTAssertEqual(model.target, unavailable ? nil : confirmed ? 2_426 : 2_126, state)
            XCTAssertEqual(model.isPresented, !TrainingDayFixture.pages.contains(state), state)
            XCTAssertEqual(model.rowText, unavailable ? "Usual target · unavailable" :
                           "\(confirmed ? "Training day" : "Usual day") · \(confirmed ? "2,426" : "2,126") kcal", state)
            let ready = ["valid-draft", "edit", "manual-ready", "save-error"].contains(state)
            XCTAssertEqual(model.canConfirm, ready, state)
            if ["unconfirmed", "blank", "unavailable-sheet", "rollover"].contains(state) {
                XCTAssertEqual(model.draft, "", state)
            }
            if state == "invalid" { XCTAssertNotNil(model.validationMessage) }
            if state == "pending" { XCTAssertTrue(model.isPending) }
            if state == "save-error" { XCTAssertNotNil(model.error); XCTAssertEqual(model.draft, "300") }
            assertContext(fixture)
            await fixture.finish()
        }
    }

    private func assertContext(_ fixture: TrainingDayFixture) {
        let state = fixture.state
        let model = fixture.model
        if state == "health-loading" { XCTAssertTrue(model.isReadingHealth) }
        if state == "health-error" { XCTAssertTrue(model.context.movementFailed) }
        if state == "zero-health" { XCTAssertEqual(model.context.movement?.value, "0 kcal") }
        if state == "loading" { XCTAssertTrue(fixture.viewModel.isLoading) }
        if state == "error" {
            XCTAssertNil(fixture.viewModel.snapshot)
            XCTAssertNotNil(fixture.viewModel.errorMessage)
        }
        if state == "stale-data" {
            XCTAssertNotNil(fixture.viewModel.snapshot); XCTAssertNotNil(fixture.viewModel.errorMessage)
        }
    }

    func testSheetStaysOpenAfterConfirmAndUndoAndReopenClearsDraftAndConsent() async {
        let fixture = TrainingDayFixture("manual-ready")
        await fixture.prepare()
        let model = fixture.model
        await model.confirm()
        XCTAssertTrue(model.isPresented)
        XCTAssertFalse(model.isEditing)
        model.beginReview()
        XCTAssertFalse(model.acknowledgesDayOnly)
        model.draft = "125"
        model.cancel()
        model.openSheet()
        XCTAssertFalse(model.isEditing)
        XCTAssertEqual(model.addition, 300)
        XCTAssertEqual(model.draft, "")
        XCTAssertFalse(model.acknowledgesDayOnly)
        let context = model.context
        model.undo()
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.context, context)
        XCTAssertEqual(model.baseline?.calorieTargetKcal, 2_126)
        XCTAssertNil(model.addition)
        await fixture.finish()
    }

    func testUnavailableSheetOpensAndCancellationInvalidatesPendingConfirmation() async {
        let missing = TrainingDayFixture("unavailable-sheet")
        await missing.prepare()
        XCTAssertTrue(missing.model.isPresented)
        missing.model.draft = "5"
        XCTAssertFalse(missing.model.canConfirm)
        await missing.finish()
        let pending = TrainingDayFixture("pending")
        await pending.prepare()
        pending.model.cancel()
        await pending.finish()
        XCTAssertNil(pending.model.addition)
        XCTAssertFalse(pending.model.isPresented)
    }

    func testRolloverInvalidatesPendingHealthAndConfirmationWhileSheetRemainsHonest() async {
        for state in ["pending", "health-loading"] {
            let fixture = TrainingDayFixture(state)
            await fixture.prepare()
            fixture.clock = fixture.clock.addingTimeInterval(86_400)
            fixture.model.synchronize(nil)
            XCTAssertTrue(fixture.model.isPresented)
            XCTAssertEqual(fixture.model.rowText, "Usual target · unavailable")
            XCTAssertEqual(fixture.model.draft, "")
            fixture.gate.finish()
            for task in fixture.tasks { await task.value }
            XCTAssertNil(fixture.model.addition)
            XCTAssertNil(fixture.model.context.movement)
            XCTAssertFalse(fixture.model.isPending)
            XCTAssertFalse(fixture.model.isReadingHealth)
            await fixture.finish()
        }
    }

    func testTrueZeroMissingDeniedAndStaleAreNotInterchangeable() async {
        let missing = TrainingDayFixture("missing-health")
        let denied = TrainingDayFixture("denied-health")
        let stale = TrainingDayFixture("stale-health")
        await missing.prepare(); await denied.prepare(); await stale.prepare()
        XCTAssertEqual(missing.model.context, denied.model.context)
        let reading = stale.model.context.movement
        XCTAssertEqual(reading?.sampleDate, stale.clock.addingTimeInterval(-86_400))
        XCTAssertEqual(reading?.checkedAt, stale.clock)
        XCTAssertTrue(reading?.detail(for: stale.clock).contains("Last known · not today's total") == true)
        await missing.finish(); await denied.finish(); await stale.finish()
    }

    func testLocalFiguresUseBundledSerifWithEqualDigitAdvancesAndRowsFitNarrowPhone() async throws {
        MorselFontCatalog.register()
        for size: CGFloat in [17, 19, 20, 26] {
            let font = TrainingDayType.figureFont(size: size)
            XCTAssertTrue(font.familyName.contains("Garamond"))
            let widths = (0...9).map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
            XCTAssertEqual(try XCTUnwrap(widths.min()), try XCTUnwrap(widths.max()), accuracy: 0.01)
        }
        for state in ["usual", "confirmed", "unavailable"] {
            let fixture = TrainingDayFixture(state)
            await fixture.prepare()
            let host = UIHostingController(rootView: TrainingFuelSection(model: fixture.model))
            let size = host.sizeThatFits(in: CGSize(width: 256, height: 1_000))
            XCTAssertLessThanOrEqual(size.width, 256)
            XCTAssertGreaterThanOrEqual(size.height, 44)
            XCTAssertLessThanOrEqual(size.height, 88)
            await fixture.finish()
        }
    }

    func testFractionsRemainAuthoredRatherThanRoundingToTwoPlaces() async {
        let fixture = TrainingDayFixture("unconfirmed")
        await fixture.prepare()
        fixture.model.draft = "0.125"
        await fixture.model.confirm()
        XCTAssertEqual(fixture.model.addition, 0.125)
        XCTAssertTrue(fixture.model.rowText.contains("2,126.125"))
        await fixture.finish()
    }
}

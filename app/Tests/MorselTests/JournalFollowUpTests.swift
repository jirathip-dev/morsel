import UIKit
import XCTest
@testable import Morsel

// Issue #105 — journal follow-up regression suite (AC1/2/3/6/7 native rules).
// The #94 shell swapped tab content instantly with no page-turn direction or
// swipe boundary contract, Add Meal was a primary .sheet, and inputs had no
// shared focus/keyboard policy. These tests pin the #105 navigation rules,
// route presentation, focus policy, and theme seam so a revert of the pager
// wiring, the Add Meal route, or the keyboard contract fails here. UI wiring
// is additionally pinned source-level by app/issue-105-journal-contract.test.ts
// (hosted probe) per the repo convention.

// ── AC1/AC2: page-turn direction + swipe boundary rules ────────────────────

final class JournalTurnRuleTests: XCTestCase {
    func testSelectingALaterTabTurnsForward() {
        XCTAssertEqual(JournalTabNavigation.direction(from: .today, to: .history), .forward)
        XCTAssertEqual(JournalTabNavigation.direction(from: .history, to: .goals), .forward)
        XCTAssertEqual(JournalTabNavigation.direction(from: .today, to: .goals), .forward)
    }

    func testSelectingAnEarlierTabTurnsBackward() {
        XCTAssertEqual(JournalTabNavigation.direction(from: .history, to: .today), .backward)
        XCTAssertEqual(JournalTabNavigation.direction(from: .goals, to: .history), .backward)
        XCTAssertEqual(JournalTabNavigation.direction(from: .goals, to: .today), .backward)
    }

    func testReselectingTheCurrentTabProducesNoTurn() {
        XCTAssertNil(JournalTabNavigation.direction(from: .today, to: .today))
        XCTAssertNil(JournalTabNavigation.direction(from: .goals, to: .goals))
    }

    func testForwardSwipeMovesToAdjacentTabAndNeverWrapsFromGoals() {
        // Swipe left/right walks the tab order (Today → History → Goals);
        // the last page must not wrap back to Today.
        XCTAssertEqual(JournalTabNavigation.adjacent(to: .today, turning: .forward), .history)
        XCTAssertEqual(JournalTabNavigation.adjacent(to: .history, turning: .forward), .goals)
        XCTAssertNil(JournalTabNavigation.adjacent(to: .goals, turning: .forward))
    }

    func testBackwardSwipeMovesToAdjacentTabAndNeverWrapsFromToday() {
        XCTAssertEqual(JournalTabNavigation.adjacent(to: .goals, turning: .backward), .history)
        XCTAssertEqual(JournalTabNavigation.adjacent(to: .history, turning: .backward), .today)
        XCTAssertNil(JournalTabNavigation.adjacent(to: .today, turning: .backward))
    }

    @MainActor
    func testBoundarySwipeCannotTriggerAnyTabChange() {
        // A swipe at the first/last tab is a no-op (no wrap, no accidental
        // action), so the pager state must stay exactly where it was.
        let pager = JournalPagerModel()
        pager.swipe(.backward)
        XCTAssertEqual(pager.selection, .today)
        pager.swipe(.forward)
        XCTAssertEqual(pager.selection, .history)
        pager.select(.goals)
        pager.swipe(.forward)
        XCTAssertEqual(pager.selection, .goals)
    }

    @MainActor
    func testRapidRepeatedTapsSettleOnTheLastRequestedTabAtomically() {
        // AC1: rapid repeated taps cannot leave content and the tab indicator
        // out of sync. The pager applies every request in arrival order and
        // settles on the FINAL requested tab (no stale intermediate wins).
        let pager = JournalPagerModel()
        pager.select(.history)
        pager.select(.goals)
        pager.select(.history)
        pager.select(.today)
        XCTAssertEqual(pager.selection, .today)
        XCTAssertEqual(pager.lastTurnDirection, .backward)
    }

    @MainActor
    func testRapidBurstDirectionDescribesTheLastCommittedMove() {
        let pager = JournalPagerModel()
        pager.select(.goals)
        XCTAssertEqual(pager.lastTurnDirection, .forward)
        pager.select(.goals) // no-op tap: nothing may change
        XCTAssertEqual(pager.selection, .goals)
        XCTAssertEqual(pager.lastTurnDirection, .forward)
        pager.select(.history)
        XCTAssertEqual(pager.lastTurnDirection, .backward)
    }
}

// ── AC3: Add Meal is a journal page/route, not the primary sheet ───────────

final class JournalRoutePresentationTests: XCTestCase {
    @MainActor
    func testAddMealRouteStartsClosedAsTabPages() {
        let model = JournalRouteModel()
        XCTAssertEqual(model.route, .tabPages)
        XCTAssertFalse(model.isPresentingAddMeal)
    }

    @MainActor
    func testOpenAddMealPresentsTheJournalPageRoute() {
        let model = JournalRouteModel()
        model.openAddMeal()
        XCTAssertTrue(model.isPresentingAddMeal)
        XCTAssertEqual(model.route, .addMeal)
    }

    @MainActor
    func testCancelAndSaveBothReturnToTheTodayPages() {
        // Cancel/back and save-close use the same dismissal; the journal
        // returns to the tab pages (Today origin stays selected underneath).
        let model = JournalRouteModel()
        model.openAddMeal()
        model.closeAddMeal()
        XCTAssertEqual(model.route, .tabPages)
        XCTAssertFalse(model.isPresentingAddMeal)

        model.openAddMeal()
        model.closeAddMeal()
        XCTAssertEqual(model.route, .tabPages)
    }

    @MainActor
    func testRepeatedOpenRequestsStayIdempotent() {
        let model = JournalRouteModel()
        model.openAddMeal()
        model.openAddMeal() // rapid double-open must not queue a second page
        XCTAssertTrue(model.isPresentingAddMeal)
        model.closeAddMeal()
        XCTAssertEqual(model.route, .tabPages)
    }
}

// ── AC6: focus/keyboard policy ─────────────────────────────────────────────

final class JournalFocusPolicyTests: XCTestCase {
    func testNumericKeyboardsExposeAVisibleDoneAction() {
        // Numeric pads have no Return key, so the shared keyboard bar must
        // surface Done for every numeric keyboard the journal fields use.
        XCTAssertTrue(JournalKeyboardKind.needsVisibleDone(keyboardType: .decimalPad))
        XCTAssertTrue(JournalKeyboardKind.needsVisibleDone(keyboardType: .numberPad))
        XCTAssertTrue(JournalKeyboardKind.needsVisibleDone(keyboardType: .numbersAndPunctuation))
    }

    func testLetterAndEmailKeyboardsDoNotNeedTheDoneBar() {
        XCTAssertFalse(JournalKeyboardKind.needsVisibleDone(keyboardType: .default))
        XCTAssertFalse(JournalKeyboardKind.needsVisibleDone(keyboardType: .emailAddress))
        XCTAssertFalse(JournalKeyboardKind.needsVisibleDone(keyboardType: .asciiCapable))
    }

    func testFieldClassificationDrivesTheDoneBarForNumericOnlyFields() {
        XCTAssertEqual(JournalKeyboardKind.classify(keyboardType: .decimalPad), .numeric)
        XCTAssertEqual(JournalKeyboardKind.classify(keyboardType: .numberPad), .numeric)
        XCTAssertEqual(JournalKeyboardKind.classify(keyboardType: .numbersAndPunctuation), .numeric)
        XCTAssertEqual(JournalKeyboardKind.classify(keyboardType: .default), .text)
        XCTAssertEqual(JournalKeyboardKind.classify(keyboardType: .emailAddress), .text)
    }

    func testMultilineFieldsAreTextNotNumeric() {
        // Notes fields scroll vertically; they keep the default keyboard and
        // are dismissed by scroll/tap like every other text input.
        XCTAssertNotEqual(JournalKeyboardKind.classify(keyboardType: .default), .numeric)
    }
}

// ── Issue #111: hinged page-turn seam (V1 geometry) ────────────────────────

final class JournalHingeSeamTests: XCTestCase {
    func testForwardTurnHingesOnTheLeadingBindingEdge() {
        // The approved V1 prototype turns the incoming page in from the
        // binding edge: hinge on the LEFT (leading), swing −70° → 0°.
        XCTAssertEqual(JournalTurnSeam.anchor(for: .forward), .leading)
        XCTAssertEqual(JournalTurnSeam.startAngle(for: .forward), -70)
    }

    func testBackwardTurnMirrorsTheHingeOnTheTrailingEdge() {
        // Turning back mirrors the hinge so the direction reads correctly.
        XCTAssertEqual(JournalTurnSeam.anchor(for: .backward), .trailing)
        XCTAssertEqual(JournalTurnSeam.startAngle(for: .backward), 70)
    }

    func testSwingStartsFadedAndSettlesOpaque() {
        XCTAssertEqual(JournalTurnSeam.startOpacity, 0.2)
    }

    func testRichSwingMatchesTheApprovedCurveAndDurations() {
        // .55s cubic-bezier(.2,.7,.2,1); Reduce Motion = .28s ease-out fade.
        XCTAssertEqual(JournalTurnSeam.richDuration, 0.55)
        XCTAssertEqual(JournalTurnSeam.reducedDuration, 0.28)
    }
}

// ── AC7: theme seam stays trait-driven (regression against a forced scheme) ─

final class JournalThemeImmediacyTests: XCTestCase {
    func testPreferenceKeysAreStableSingleConstants() {
        // Root (MorselApp) and Settings both store through this exact key, so
        // a Paper/Night-ink change re-inks the visible surface immediately.
        XCTAssertEqual(MorselAppearance.themePreferenceKey, "morsel.appearance.theme")
    }

    func testBothThemePreferencesResolveToADifferentRootScheme() {
        // Night ink forces dark, Paper forces light: switching the stored
        // preference re-resolves every dual token at the root.
        let paper = MorselAppearance.scheme(for: .paper)
        let night = MorselAppearance.scheme(for: .nightInk)
        XCTAssertNotNil(paper)
        XCTAssertNotNil(night)
        XCTAssertNotEqual(paper, night)
    }
}

// ── Issue #174: the gesture/scene plumbing the turn seam depends on ────────

// The #174 race suite (JournalPagerRaceTests) drives the extracted
// JournalTurnMachine seam and the mounted turner directly, so this contract
// pins the thin wiring that connects the real drag gesture and the scene
// lifecycle to that machine.
final class JournalPagerWiringContractTests: XCTestCase {
    private func turnerSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let turner = appDirectory.appendingPathComponent("Sources/Morsel/JournalPageTurner.swift")
        return try String(contentsOf: turner, encoding: .utf8)
    }

    func testTheDragGestureForwardsRealTranslationIntoTheStateMachine() throws {
        let source = try turnerSource()
        XCTAssertTrue(source.contains("DragGesture(minimumDistance: 15"))
        XCTAssertTrue(source.contains("machine.dragChanged(deltaX: value.translation.width"))
        XCTAssertTrue(source.contains("machine.dragEnded(deltaX: value.translation.width"))
        XCTAssertTrue(source.contains("predictedX: value.predictedEndTranslation.width"))
    }

    func testSceneInactivityAndRemovalInterruptTheTurn() throws {
        let source = try turnerSource()
        XCTAssertTrue(source.contains(".onChange(of: scenePhase)"))
        XCTAssertTrue(source.contains(".onDisappear { machine.interrupt() }"))
        XCTAssertTrue(source.contains("machine.selectionChanged(to: newTab)"))
        XCTAssertTrue(source.contains("machine.swingDidAppear(id: turn.id)"))
    }
}

// ── Issue #176: presentation ownership + the applied ownership channels ────

/// The shell owns Today's presentations, outside the transient pages, and
/// keeps AT MOST one of them: a request arriving while one is open (or
/// opening) changes nothing, and the sheets keep their #136 dismissal paths.
@MainActor
final class JournalPresentationOwnershipTests: XCTestCase {
    private func item() -> MealItem {
        MealItem(itemID: UUID(), name: "oats", quantity: 1, unit: .serving,
                 caloriesKcal: 200, proteinG: 8, carbsG: 30, fatG: 4,
                 fiberG: 4, sugarG: 1, confidence: 1, notes: nil)
    }

    private func meal() -> MealRecord {
        MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: Date(timeIntervalSince1970: 100),
                   source: .manual, items: [item()])
    }

    func testAtMostOnePresentationExistsInBothRequestOrders() {
        let presentations = JournalPresentationModel()
        let first = item()
        presentations.requestEdit(first)
        presentations.requestEdit(item())
        presentations.requestDelete(meal())
        XCTAssertEqual(presentations.editingItem?.itemID, first.itemID)
        XCTAssertNil(presentations.mealToDelete, "a second request must not stack a second presentation")
        presentations.finishEdit()
        XCTAssertFalse(presentations.isPresenting)

        let lunch = meal()
        presentations.requestDelete(lunch)
        presentations.requestEdit(item())
        XCTAssertEqual(presentations.mealToDelete?.mealLogID, lunch.mealLogID)
        XCTAssertNil(presentations.editingItem)
        presentations.deleteBinding.wrappedValue = nil
        XCTAssertFalse(presentations.isPresenting)
    }
}

/// Touch and accessibility cannot be observed in the unit bundle (#174/#177:
/// 0 accessibility elements, `hitTest` answers `_UIHostingView` everywhere),
/// so the applied ownership lines are pinned where they are declared.
final class JournalInteractionOwnershipWiringTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appDirectory.appendingPathComponent("Sources/Morsel/\(name)"),
                          encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String?) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start), "missing anchor \(start)")
        guard let end else { return String(source[startRange.lowerBound...]) }
        let endRange = try XCTUnwrap(source.range(of: end), "missing anchor \(end)")
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    func testPageLayersApplyAllThreeOwnershipChannelsFromOnePredicate() throws {
        let app = try source("MorselApp.swift")
        let layer = try slice(app, from: "private func page(_ tab: JournalTab) -> some View {",
                              to: "/// Issue #176 — the declared active page")
        XCTAssertTrue(layer.contains(".allowsHitTesting(owns(tab))"))
        XCTAssertTrue(layer.contains(".disabled(!owns(tab))"))
        XCTAssertTrue(layer.contains(".accessibilityHidden(!owns(tab))"))

        let decoration = try slice(
            app, from: "if let turn = machine.turn, activations[turn.incoming] == nil {",
            to: ".accessibilityLabel(\"Opening the page\")"
        )
        XCTAssertTrue(decoration.contains(".allowsHitTesting(false)"),
                      "an animation-only layer must never own a touch")
    }

    func testTheShellRoutesCoverageAndAnchorsThePresentationsItOwns() throws {
        let app = try source("MorselApp.swift")
        let shell = try slice(app, from: "private struct AuthenticatedDashboardView", to: nil)
        XCTAssertTrue(shell.contains("overlayCoversPages: routeModel.route != .tabPages"))
        XCTAssertTrue(shell.contains("@StateObject private var presentations = JournalPresentationModel()"))
        XCTAssertTrue(shell.contains(".journalPresentations(presentations, viewModel: viewModel)"))

        let today = try slice(try source("Views.swift"), from: "struct TodayView: View {", to: "// MARK: - Header")
        XCTAssertFalse(today.contains(".sheet("), "Today must not present from the transient page")
        XCTAssertFalse(today.contains("@State"), "no presentation state may live in the transient page")
        XCTAssertTrue(today.contains("presentations.requestEdit("))
        XCTAssertTrue(today.contains("presentations.requestDelete("))
    }
}

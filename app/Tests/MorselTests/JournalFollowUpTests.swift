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

import Combine
import SwiftUI

// Issue #105 — journal page-turn navigation contract. The #94 shell swapped
// tab content instantly behind a custom bar; #105 turns the three primary
// tabs into an ordered page sequence: selecting a later tab turns the page
// forward (content arrives from the trailing edge), selecting an earlier tab
// turns backward, a horizontal swipe walks to the adjacent page, and the
// first/last page never wraps. Today · History · Goals order is pinned by
// AppearanceThemeTests (JournalTab.allCases) — these rules read the same
// declaration, so content order and the indicator order cannot drift.

/// Direction of a journal page turn. `forward` moves to a later tab (content
/// enters from the trailing/right edge); `backward` moves to an earlier tab.
enum PageTurnDirection: Equatable, Sendable {
    case forward
    case backward
}

enum JournalTabNavigation {
    /// Which way the page must turn to move between two tabs. Same-tab
    /// requests produce no turn (`nil`) — the pager treats them as no-ops so
    /// repeated taps cannot queue stale content.
    static func direction(from current: JournalTab, to next: JournalTab) -> PageTurnDirection? {
        guard let currentIndex = orderIndex(of: current),
              let nextIndex = orderIndex(of: next),
              currentIndex != nextIndex else {
            return nil
        }
        return currentIndex < nextIndex ? .forward : .backward
    }

    /// The adjacent page in `direction`, or `nil` at the first/last tab —
    /// swipes never wrap Today → Goals or Goals → Today, and a boundary
    /// swipe is a no-op that cannot trigger an accidental action.
    static func adjacent(to tab: JournalTab, turning direction: PageTurnDirection) -> JournalTab? {
        let tabs = JournalTab.allCases
        guard let index = orderIndex(of: tab) else { return nil }
        switch direction {
        case .forward:
            let nextIndex = tabs.index(after: index)
            return nextIndex < tabs.endIndex ? tabs[nextIndex] : nil
        case .backward:
            guard index > tabs.startIndex else { return nil }
            return tabs[tabs.index(before: index)]
        }
    }

    private static func orderIndex(of tab: JournalTab) -> Array<JournalTab>.Index? {
        JournalTab.allCases.firstIndex(of: tab)
    }
}

/// Single source of truth for the journal pager (AC1/AC2). The shell's
/// TabView and the custom tab bar BOTH read `selection` from this model, so
/// the visible page and the active tab word update in the same state pass —
/// rapid repeated taps settle on the last requested tab and can never leave
/// content and indicator out of sync. `select`/`swipe` encode the bar-tap and
/// horizontal-swipe semantics (no wrap at the boundaries).
@MainActor
final class JournalPagerModel: ObservableObject {
    @Published private(set) var selection: JournalTab = .today
    /// Direction of the LAST committed change (nil before any move; no-op
    /// taps leave it untouched).
    @Published private(set) var lastTurnDirection: PageTurnDirection?

    func select(_ tab: JournalTab) {
        guard let turn = JournalTabNavigation.direction(from: selection, to: tab) else {
            return // same-tab tap: no state change, nothing to animate
        }
        lastTurnDirection = turn
        selection = tab
    }

    /// Horizontal swipe on page content: moves to the adjacent page or stays
    /// put at the first/last tab (no wrap, no accidental action).
    func swipe(_ direction: PageTurnDirection) {
        guard let adjacent = JournalTabNavigation.adjacent(to: selection, turning: direction) else {
            return
        }
        lastTurnDirection = direction
        selection = adjacent
    }
}

// MARK: - Add Meal as a journal page (AC3)

/// Issue #105 route presentation: Add Meal is a full journal page inside the
/// journal flow — never the primary `.sheet` from TodayView. Opening the
/// route keeps the journal underneath (Today origin stays selected), and
/// Cancel/back and save-close share one dismissal that returns to the Today
/// pages.
@MainActor
final class JournalRouteModel: ObservableObject {
    enum Route: Equatable, Sendable {
        case tabPages
        case addMeal
    }

    @Published private(set) var route: Route = .tabPages

    var isPresentingAddMeal: Bool { route == .addMeal }

    func openAddMeal() {
        route = .addMeal
    }

    /// Cancel/back or save-close — returns to the tab pages (Today origin).
    func closeAddMeal() {
        route = .tabPages
    }
}

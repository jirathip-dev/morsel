import XCTest
@testable import Morsel

// Issue #94 — V1 appearance seam: Paper/Night ink/Follow system map to the
// root scheme; the default is Paper (light). The root PLACEMENT of the
// modifier is pinned by the hosted probe in app/hotfix-89-contract.test.ts.
final class AppearanceThemeTests: XCTestCase {
    func testPaperForcesLightAndIsTheDefault() {
        XCTAssertEqual(MorselAppearance.defaultThemePreference, .paper)
        XCTAssertEqual(MorselAppearance.scheme(for: .paper), .light)
    }

    func testNightInkForcesDark() {
        XCTAssertEqual(MorselAppearance.scheme(for: .nightInk), .dark)
    }

    func testFollowSystemDoesNotForceAScheme() {
        XCTAssertNil(MorselAppearance.scheme(for: .followSystem))
    }

    func testPreferenceTitlesReadAsTheV1SettingsChoices() {
        XCTAssertEqual(MorselThemePreference.paper.title, "Paper")
        XCTAssertEqual(MorselThemePreference.nightInk.title, "Night ink")
        XCTAssertEqual(MorselThemePreference.followSystem.title, "Follow system")
    }

    func testJournalTabsAreTodayHistoryGoalsPrimary() {
        // AC1: Today, History, Goals are primary tabs; Goals is not behind a
        // secondary route. A fourth "settings" tab case must fail here.
        XCTAssertEqual(JournalTab.allCases, [.today, .history, .goals])
        XCTAssertEqual(JournalTab.allCases.map(\.title), ["Today", "History", "Goals"])
    }
}

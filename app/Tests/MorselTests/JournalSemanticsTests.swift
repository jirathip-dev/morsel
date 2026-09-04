import XCTest
@testable import Morsel

// Issue #94 — native energy/history semantics + V1 palette roles. These tests
// compile against the real model/palette tables (no rendered scene needed)
// and are mirrored by source-level hosted probes for UI wiring.

@MainActor
final class JournalEnergySemanticsTests: XCTestCase {
    // ── eaten vs goal (AC3): active energy is context, never subtracted ────

    func testEatenMinusGoalIsTheOnlyDisplayedDelta() {
        XCTAssertEqual(DashboardMath.eatenMinusGoal(eaten: 1_800, goal: 2_000), -200)
        XCTAssertEqual(DashboardMath.eatenMinusGoal(eaten: 2_410, goal: 2_100), 310)
        XCTAssertEqual(DashboardMath.eatenMinusGoal(eaten: 1_214, goal: 2_100), -886)
    }

    func testEatenMinusGoalUnavailableWithoutAValidGoal() {
        XCTAssertNil(DashboardMath.eatenMinusGoal(eaten: 1_800, goal: nil))
        XCTAssertNil(DashboardMath.eatenMinusGoal(eaten: 1_800, goal: 0))
    }

    func testActivityBurnNeverEntersTheDelta() async {
        // Regression: subtracting 300 kcal of active energy from 1,800 eaten
        // produced a legacy "net" readout of 1,500. The delta must stay -200.
        let meal = MealRecord(
            mealLogID: UUID(), mealType: .breakfast, eatenAt: Date(),
            source: .manual,
            items: [MealItem(
                itemID: UUID(), name: "oats", quantity: 1, unit: .serving,
                caloriesKcal: 1_800, proteinG: 0, carbsG: 0, fatG: 0,
                fiberG: 0, sugarG: 0, confidence: 1, notes: nil, source: .manual
            )]
        )
        let goal = DashboardGoal(calorieTargetKcal: 2_000, proteinG: 0, carbsG: 0, fatG: 0, source: .manual)
        let snapshot = DashboardSnapshot(
            date: Date(), meals: [meal], goal: goal, activeEnergyBurned: 300
        )
        let repository = MockDashboardRepository(snapshot: snapshot)
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())

        await viewModel.load()

        XCTAssertEqual(viewModel.totals.caloriesKcal, 1_800)
        // The burn stays a margin note — never a net-intake operand.
        XCTAssertEqual(viewModel.snapshot?.activeEnergyBurned, 300)
        let delta = DashboardMath.eatenMinusGoal(
            eaten: viewModel.totals.caloriesKcal, goal: goal.calorieTargetKcal
        )
        XCTAssertEqual(delta, -200)
    }

    func testComparisonStateWordsUseTheFiftyKcalToleranceBand() {
        XCTAssertEqual(DashboardMath.comparison(delta: -886), .under)
        XCTAssertEqual(DashboardMath.comparison(delta: -49), .onTarget)
        XCTAssertEqual(DashboardMath.comparison(delta: -50), .onTarget)
        XCTAssertEqual(DashboardMath.comparison(delta: 0), .onTarget)
        XCTAssertEqual(DashboardMath.comparison(delta: 50), .onTarget)
        XCTAssertEqual(DashboardMath.comparison(delta: 51), .over)
        XCTAssertEqual(DashboardMath.comparison(delta: 310), .over)
        XCTAssertNil(DashboardMath.eatenMinusGoal(eaten: 0, goal: nil))
    }

    func testComparisonWordsMatchTheNormativeStateWords() {
        XCTAssertEqual(DashboardMath.comparison(delta: -886).word, "under")
        XCTAssertEqual(DashboardMath.comparison(delta: 30).word, "on target")
        XCTAssertEqual(DashboardMath.comparison(delta: 310).word, "over")
    }

    // ── History ledger math (AC6 + C3) ─────────────────────────────────────

    private func utcDay(_ offset: Int, from base: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let start = calendar.startOfDay(for: base)
        return calendar.date(byAdding: .day, value: offset, to: start) ?? start
    }

    func testHistorySummarySumsCompletedDaysOnlyAndExcludesTodayProvisional() {
        let goal = 2_100.0
        let days = [
            HistoryDay(date: utcDay(-4), eatenKcal: 1_800, logged: true),   // under
            HistoryDay(date: utcDay(-3), eatenKcal: 2_050, logged: true),   // on target
            HistoryDay(date: utcDay(-2), eatenKcal: 2_300, logged: true),   // over
            HistoryDay(date: utcDay(-1), eatenKcal: 0, logged: false),      // gap
            HistoryDay(date: utcDay(0), eatenKcal: 1_214, logged: true)    // today, provisional
        ]
        let today = utcDay(0)

        XCTAssertEqual(DashboardMath.daysLogged(days, today: today), 3)
        XCTAssertEqual(DashboardMath.daysOverGoal(days, goal: goal, today: today), 1)
        XCTAssertEqual(DashboardMath.averageKcal(days, today: today) ?? 0, (1_800 + 2_050 + 2_300) / 3.0)
        XCTAssertEqual(DashboardMath.loggingStreak(days, today: today), 1) // today only; -1 is a gap
    }

    func testLoggingStreakRunsBackwardThroughLoggedDays() {
        let days = [
            HistoryDay(date: utcDay(-3), eatenKcal: 1_000, logged: true),
            HistoryDay(date: utcDay(-2), eatenKcal: 1_100, logged: true),
            HistoryDay(date: utcDay(-1), eatenKcal: 1_200, logged: true),
            HistoryDay(date: utcDay(0), eatenKcal: 500, logged: true)
        ]
        XCTAssertEqual(DashboardMath.loggingStreak(days, today: utcDay(0)), 4)

        // today has no meals yet → the streak may end yesterday.
        let daysWithoutToday = [
            HistoryDay(date: utcDay(-2), eatenKcal: 1_100, logged: true),
            HistoryDay(date: utcDay(-1), eatenKcal: 1_200, logged: true),
            HistoryDay(date: utcDay(0), eatenKcal: 0, logged: false)
        ]
        XCTAssertEqual(DashboardMath.loggingStreak(daysWithoutToday, today: utcDay(0)), 2)

        XCTAssertEqual(DashboardMath.loggingStreak([], today: utcDay(0)), 0)
    }
}

// ── V1 dual palette roles (AC2: Paper and Night ink visually distinct) ────

final class JournalPaletteRoleTests: XCTestCase {
    private func luminance(hex: String) -> Double {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        guard value.count == 6, Scanner(string: value).scanHexInt64(&rgb) else { return 0 }
        func linear(_ value: Double) -> Double {
            let channel = value / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let redChannel = Double((rgb >> 16) & 0xff)
        let greenChannel = Double((rgb >> 8) & 0xff)
        let blueChannel = Double(rgb & 0xff)
        return 0.2126 * linear(redChannel) + 0.7152 * linear(greenChannel) + 0.0722 * linear(blueChannel)
    }

    private func contrast(_ foreground: String, _ background: String) -> Double {
        let highLuminance = luminance(hex: foreground)
        let lowLuminance = luminance(hex: background)
        let high = max(highLuminance, lowLuminance)
        let low = min(highLuminance, lowLuminance)
        return (high + 0.05) / (low + 0.05)
    }

    private func assertAA(_ foreground: String, _ background: String, _ label: String) {
        let ratio = contrast(foreground, background)
        XCTAssertGreaterThanOrEqual(
            ratio, 4.5,
            "\(label): \(foreground) on \(background) = \(String(format: "%.2f", ratio)):1, below AA"
        )
    }

    private func assertMark(_ foreground: String, _ background: String, _ label: String) {
        let ratio = contrast(foreground, background)
        XCTAssertGreaterThanOrEqual(
            ratio, 3.0,
            "\(label): \(foreground) on \(background) = \(String(format: "%.2f", ratio)):1, below 3:1"
        )
    }

    func testEveryTokenCarriesDistinctPaperAndNightVariants() {
        let distinct: [(String, MorselPalette.Pair)] = [
            ("ink", MorselPalette.ink), ("inkTwo", MorselPalette.inkTwo),
            ("inkThree", MorselPalette.inkThree), ("background", MorselPalette.background),
            ("surface", MorselPalette.surface), ("surfaceTwo", MorselPalette.surfaceTwo),
            ("line", MorselPalette.line), ("accentSoft", MorselPalette.accentSoft),
            ("leaf", MorselPalette.leaf), ("leafSoft", MorselPalette.leafSoft),
            ("forest", MorselPalette.forest), ("coral", MorselPalette.coral),
            ("review", MorselPalette.review),
            ("over", MorselPalette.over), ("inkline", MorselPalette.inkline),
            ("proteinWash", MorselPalette.proteinWash), ("carbsWash", MorselPalette.carbsWash),
            ("fatWash", MorselPalette.fatWash), ("todayWash", MorselPalette.todayWash)
        ]
        for (name, pair) in distinct {
            XCTAssertNotEqual(pair.paper, pair.night, "\(name) must differ between themes")
        }
        // accent + mustard + mustardDeep stay identical pigments in both themes.
        XCTAssertEqual(MorselPalette.accent.paper, MorselPalette.accent.night)
        XCTAssertEqual(MorselPalette.mustard.paper, MorselPalette.mustard.night)
        XCTAssertEqual(MorselPalette.mustardDeep.paper, MorselPalette.mustardDeep.night)
    }

    func testNightInkInvertsTheGroundAndRoles() {
        // Night page ground is the ink pigment; night copy is the cream paper.
        XCTAssertEqual(MorselPalette.background.night, MorselPalette.ink.paper)
        XCTAssertEqual(MorselPalette.ink.night, MorselPalette.background.paper)
        // Pigments flip to their soft family on charcoal.
        XCTAssertEqual(MorselPalette.forest.night, MorselPalette.leafSoft.paper)
        XCTAssertEqual(MorselPalette.review.night, MorselPalette.accentSoft.paper)
        XCTAssertEqual(MorselPalette.accentSoft.night, MorselPalette.review.paper)
        XCTAssertEqual(MorselPalette.coral.night, MorselPalette.accentSoft.paper)
        XCTAssertEqual(MorselPalette.carbsWash.night, MorselPalette.mustard.paper)
        XCTAssertEqual(MorselPalette.fatWash.night, MorselPalette.leafSoft.paper)
        // Wash pigments lighten from their pigment to the ~0.92 wash base.
        XCTAssertNotEqual(MorselPalette.proteinWash.paper, MorselPalette.coral.paper)
    }

    func testStrictTextPairsPassAAOnPaper() {
        assertAA(MorselPalette.ink.paper, MorselPalette.background.paper, "paper body text")
        assertAA(MorselPalette.inkTwo.paper, MorselPalette.background.paper, "paper secondary")
        assertAA(MorselPalette.inkThree.paper, MorselPalette.background.paper, "paper metadata")
        assertAA(MorselPalette.forest.paper, MorselPalette.background.paper, "paper active text")
        assertAA(MorselPalette.review.paper, MorselPalette.accentSoft.paper, "paper verify tag")
        assertAA(MorselPalette.labelOnAccent.paper, MorselPalette.accent.paper, "paper ink-on-accent label")
        assertAA(MorselPalette.ink.paper, MorselPalette.surface.paper, "paper on surface")
        assertAA(MorselPalette.ink.paper, MorselPalette.surfaceTwo.paper, "paper on field")
    }

    func testStrictTextPairsPassAAOnNight() {
        assertAA(MorselPalette.ink.night, MorselPalette.background.night, "night body text")
        assertAA(MorselPalette.inkTwo.night, MorselPalette.background.night, "night secondary")
        assertAA(MorselPalette.inkThree.night, MorselPalette.background.night, "night metadata")
        assertAA(MorselPalette.forest.night, MorselPalette.background.night, "night active text")
        assertAA(MorselPalette.review.night, MorselPalette.accentSoft.night, "night verify tag text")
        assertAA(MorselPalette.labelOnAccent.night, MorselPalette.accent.night, "night ink-on-accent label")
        assertAA(MorselPalette.ink.night, MorselPalette.surface.night, "night on surface")
        assertAA(MorselPalette.ink.night, MorselPalette.surfaceTwo.night, "night on field")
    }

    func testStrictMarkPairsClearThreeToOne() {
        assertMark(MorselPalette.inkline.paper, MorselPalette.background.paper, "paper inkline mark")
        assertMark(MorselPalette.inkline.night, MorselPalette.background.night, "night inkline mark")
        assertMark(MorselPalette.mustardDeep.paper, MorselPalette.background.paper, "paper near-goal stroke")
        assertMark(MorselPalette.mustardDeep.night, MorselPalette.background.night, "night near-goal stroke")
        assertMark(MorselPalette.accent.paper, MorselPalette.surface.paper, "paper accent on surface")
    }
}

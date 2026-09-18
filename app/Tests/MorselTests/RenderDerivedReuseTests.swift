import SwiftUI
import UIKit
import XCTest
@testable import Morsel

/// Issue #195 — the count-based reuse regression and the invalidation parity it
/// depends on. Counts come from the production `derivedScanCount`; every value
/// is also compared against an independent reference scan, so a reuse that
/// served stale data fails here even when the count looks right.
@MainActor
final class RenderDerivedReuseTests: XCTestCase {
    private let account = UUID()
    private let day = DashboardMath.startOfLocalDay(Date(timeIntervalSince1970: 1_770_000_000))

    private func makeModel(_ data: DashboardSnapshot) -> (DashboardViewModel, ProbeRemote) {
        let remote = ProbeRemote(snapshot: data)
        let model = DashboardViewModel(repository: remote, userID: account, dateProvider: { self.day })
        return (model, remote)
    }

    /// Unchanged loading/status/turn updates must reuse the derived scan.
    func testUnchangedUpdatesReuseTheDerivedScan() async throws {
        let data = RenderDerivedFixture.snapshot(day: day, meals: 40, itemsPerMeal: 12)
        let (model, remote) = makeModel(data)
        await model.load()
        _ = model.totals
        let firstPaint = model.derivedScanCount
        XCTAssertGreaterThan(firstPaint, 0, "the first paint must scan once")
        for _ in 0..<200 {
            await model.load()
            for _ in 0..<6 { _ = model.totals }
            for _ in 0..<2 { _ = model.mealGroups }
            _ = model.reviewItems
        }
        for _ in 0..<50 {
            model.cancelRefresh()
            _ = model.totals
            _ = model.mealGroups
        }
        XCTAssertEqual(model.derivedScanCount, firstPaint, "unchanged updates must not rescan the day")
        XCTAssertGreaterThan(remote.dayReads, 200)
        RenderDerivedReference.assertParity(model, meals: data.meals)
    }

    /// A real meal mutation invalidates exactly one scan and the new values are
    /// the exact reference values.
    func testMealMutationInvalidatesExactlyOnce() async throws {
        var data = RenderDerivedFixture.snapshot(day: day, meals: 6, itemsPerMeal: 3)
        let (model, remote) = makeModel(data)
        await model.load()
        _ = model.totals
        _ = model.mealGroups
        let reviewsBefore = model.reviewItems.count
        let baseline = model.derivedScanCount
        await model.load()
        _ = model.totals
        XCTAssertEqual(model.derivedScanCount, baseline, "an equal republish must reuse the scan")
        let added = RenderDerivedFixture.reviewMeal(day: day, kcal: 250)
        data = DashboardSnapshot(date: data.date, meals: data.meals + [added], goal: data.goal)
        remote.snapshot = data
        await model.load()
        _ = model.totals
        XCTAssertEqual(model.derivedScanCount, baseline + 1, "a real mutation invalidates exactly one scan")
        RenderDerivedReference.assertParity(model, meals: data.meals)
        XCTAssertEqual(model.reviewItems.count, reviewsBefore + 1, "the added low-confidence item needs review")
        XCTAssertTrue(model.reviewItems.contains { $0.itemID == added.items[0].itemID })
        XCTAssertEqual(model.totals.caloriesKcal, DashboardMath.totals(for: data.meals).caloriesKcal)
    }

    /// A day change clears the derived values; reloading restores the exact
    /// reference values for the newly selected day.
    func testDaySelectionClearsAndReloadsTheDerivedValues() async throws {
        let data = RenderDerivedFixture.snapshot(day: day, meals: 4, itemsPerMeal: 2)
        let (model, _) = makeModel(data)
        await model.load()
        _ = model.totals
        model.selectDate(day.addingTimeInterval(-86_400))
        XCTAssertEqual(model.totals, DashboardTotals(caloriesKcal: 0, proteinG: 0, carbsG: 0, fatG: 0))
        XCTAssertTrue(model.mealGroups.isEmpty)
        XCTAssertTrue(model.reviewItems.isEmpty)
        await model.load()
        RenderDerivedReference.assertParity(model, meals: data.meals)
    }

    /// The mounted real page must reuse the scan across unchanged updates.
    func testMountedTodayReusesTheDerivedScan() async throws {
        let data = RenderDerivedFixture.snapshot(day: day, meals: 6, itemsPerMeal: 2)
        let (model, _) = makeModel(data)
        await model.load()
        let window = RenderDerivedMount.window(
            TodayView(viewModel: model, showSettings: {}, addMeal: {})
                .environment(\.trainingFuelHosted, true)
                .environmentObject(TrainingFuelModel())
        )
        defer { window.isHidden = true }
        RenderDerivedMount.pump(0.3)
        let settled = model.derivedScanCount
        for _ in 0..<20 {
            await model.load()
            RenderDerivedMount.pump(0.01)
        }
        XCTAssertEqual(model.derivedScanCount, settled, "the mounted body path must reuse the derived scan")
        RenderDerivedReference.assertParity(model, meals: data.meals)
    }

    // MARK: - AC3: zone/locale semantics stay exact

    /// The gutter folio must match a freshly built formatter in every device
    /// zone, and the zone decides the rendered day exactly as it did before.
    func testGutterDateMatchesAFreshFormatterAcrossTimeZones() throws {
        let instants = [Date(timeIntervalSince1970: 1_770_000_000), Date(timeIntervalSince1970: 1_770_058_200)]
        let expected = [
            "UTC": ["02.FEB.2026", "02.FEB.2026"],
            "Asia/Tokyo": ["02.FEB.2026", "03.FEB.2026"],
            "America/Los_Angeles": ["01.FEB.2026", "02.FEB.2026"]
        ]
        let savedTZ = ProcessInfo.processInfo.environment["TZ"]
        let previousZone = NSTimeZone.default
        defer { restoreTimezone(previousZone, savedTZ: savedTZ) }
        for zone in expected.keys.sorted() {
            setTimezone(zone)
            for (index, instant) in instants.enumerated() {
                let rendered = JournalPageFurniture.gutterDate(instant)
                XCTAssertEqual(rendered, Self.freshGutterDate(instant), "\(zone) must match a fresh formatter")
                XCTAssertEqual(rendered, expected[zone]?[index], "\(zone) exact folio")
            }
        }
    }

    /// History's derived window follows range and zone exactly (this lane does
    /// not change those properties; the pin keeps the contract honest).
    func testHistoryWindowFollowsRangeAndZone() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let days = (0..<30).reversed().map { offset in
            HistoryDay(date: calendar.date(byAdding: .day, value: -offset, to: day) ?? day,
                       eatenKcal: 1_800 + Double(offset), logged: true)
        }
        let remote = ProbeRemote(snapshot: RenderDerivedFixture.snapshot(day: day, meals: 1, itemsPerMeal: 1))
        remote.overview = HistoryOverview(days: days, goal: DashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 100, carbsG: 250, fatG: 55, source: .manual))
        let model = HistoryViewModel(repository: remote, userID: account, dateProvider: { self.day })
        await model.load()
        XCTAssertEqual(model.chartDays, Array(days.suffix(7)))
        XCTAssertEqual(model.daysLogged, 6, "today is excluded from completed logged days")
        model.range = .thirty
        await model.load()
        XCTAssertEqual(model.chartDays, days)
        XCTAssertEqual(model.averageKcal, 1_815, "the completed-day average is exact")
        let savedTZ = ProcessInfo.processInfo.environment["TZ"]
        let previousZone = NSTimeZone.default
        defer { restoreTimezone(previousZone, savedTZ: savedTZ) }
        setTimezone("Pacific/Kiritimati")
        let start = DashboardMath.startOfLocalDay(day)
        let windowStart = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -29, to: start) ?? start
        XCTAssertEqual(model.chartDays, days.filter { $0.date >= windowStart && $0.date <= start })
        XCTAssertEqual(model.chartDays.count, 29, "the +14 zone moves the window start past the newest day")
    }

    // MARK: - helpers

    /// Switches the process zone through BOTH Foundation paths: `NSTimeZone.default`
    /// (the repo's own idiom — other suites pin it) and the `TZ` environment with a
    /// system-zone reset. Callers capture the previous default and restore it.
    private func setTimezone(_ identifier: String) {
        NSTimeZone.default = TimeZone(identifier: identifier) ?? NSTimeZone.default
        setenv("TZ", identifier, 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
    }

    private func restoreTimezone(_ previous: TimeZone, savedTZ: String?) {
        NSTimeZone.default = previous
        if let savedTZ { setenv("TZ", savedTZ, 1) } else { unsetenv("TZ") }
        tzset()
        NSTimeZone.resetSystemTimeZone()
    }

    private static func freshGutterDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MMM.yyyy"
        return formatter.string(from: date).uppercased()
    }
}

import XCTest
@testable import Morsel

final class WeightDeltaTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_789_344_000)

    func testPayloadCannotSupplyADatedTargetEvenForToday() {
        let day = WeightDeltaDay(day: HistoryDay(date: today, eatenKcal: 1_700, logged: true))
        XCTAssertNil(day.foodTargetKcal)
        XCTAssertNil(day.targetSource)
        XCTAssertNil(day.deltaKcal)
        XCTAssertEqual(day.status, "food target unavailable")
        XCTAssertEqual(day.symbol, "?")
    }

    func testOnlyAnAvailableDatedFoodTargetProducesASignedDelta() {
        let day = WeightDeltaDay(date: today, logged: true, eatenKcal: 1_700,
                                 foodTargetKcal: 2_100, targetSource: "Illustrative dated target")
        XCTAssertEqual(day.deltaKcal, -400)
        XCTAssertEqual(day.symbol, "−")
        var above = day
        above.foodTargetKcal = 1_500
        XCTAssertEqual(above.deltaKcal, 200)
        XCTAssertEqual(above.status, "+200 kcal")
        above.foodTargetKcal = 1_700
        XCTAssertEqual(above.deltaKcal, 0)
        XCTAssertEqual(above.symbol, "○")
    }

    func testUnloggedDayIsNotZeroIntakeOrZeroDeltaEvenWithATarget() {
        let day = WeightDeltaDay(date: today, logged: false, eatenKcal: 0,
                                 foodTargetKcal: 2_100, targetSource: "Illustrative dated target")
        XCTAssertNil(day.eatenKcal)
        XCTAssertNil(day.deltaKcal)
        XCTAssertEqual(day.status, "no food log")
        XCTAssertEqual(day.symbol, "×")
    }

    func testLoggedZeroIsDifferentFromMissingLog() {
        let day = WeightDeltaDay(date: today, logged: true, eatenKcal: 0,
                                 foodTargetKcal: 2_100, targetSource: "Illustrative dated target")
        XCTAssertEqual(day.eatenKcal, 0)
        XCTAssertEqual(day.deltaKcal, -2_100)
    }

    func testTargetNeedsBothValidValueAndSource() {
        var day = WeightDeltaDay(date: today, logged: true, eatenKcal: 1_000, foodTargetKcal: 2_000)
        XCTAssertNil(day.deltaKcal)
        day.targetSource = ""
        XCTAssertNil(day.deltaKcal)
        day.targetSource = "Illustrative dated target"
        for invalid in [0, -1, Double.nan, .infinity] {
            day.foodTargetKcal = invalid
            XCTAssertNil(day.deltaKcal)
        }
    }

    func testOneDateAxisIncludesEveryWeightAndFoodDateWithoutInventingLogs() throws {
        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.startOfDay(for: today)
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -29, to: end))
        let days = [WeightDeltaDay(day: HistoryDay(date: end, eatenKcal: 1_500, logged: true))]
        let points = [WeightTrendPoint(date: start, kilograms: 62.5),
                      WeightTrendPoint(date: end.addingTimeInterval(1_000), kilograms: 62)]
        let timeline = WeightDeltaTimeline(days: days, points: points, today: end)
        XCTAssertEqual(timeline.days.count, 30, "preserve the existing full weight window in 7-day food mode")
        XCTAssertEqual(timeline.days.first?.date, start)
        XCTAssertEqual(timeline.days.last?.date, end)
        XCTAssertEqual(timeline.domain.lowerBound, start)
        XCTAssertTrue(points.allSatisfy { timeline.domain.contains($0.date) })
        XCTAssertNil(timeline.days.first?.logged, "outside the food query is unknown, not logged:false")
        XCTAssertEqual(timeline.days.first?.status, "food log unavailable")
        XCTAssertEqual(timeline.days.last?.status, "food target unavailable")
        XCTAssertEqual(Set(timeline.days.map(\.date)).count, 30)
    }

    func testCalendarDaysStayAlignedAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7)))
        let dates = try (0..<4).map { try XCTUnwrap(calendar.date(byAdding: .day, value: $0, to: start)) }
        let days = dates.map { WeightDeltaDay(day: HistoryDay(date: $0, eatenKcal: 500, logged: true)) }
        let timeline = WeightDeltaTimeline(days: days, points: [], today: dates[3], calendar: calendar)
        XCTAssertEqual(timeline.days.map(\.date), dates)
        XCTAssertEqual(dates[2].timeIntervalSince(dates[1]), 23 * 3_600)
    }

    func testScaleGrowsToFitAnAvailableDeltaRatherThanClipping() {
        let day = WeightDeltaDay(date: today, logged: true, eatenKcal: 4_500,
                                 foodTargetKcal: 2_000, targetSource: "Illustrative dated target")
        XCTAssertEqual(WeightDeltaTimeline(days: [day], points: [], today: today).deltaLimit, 2_500)
    }

    func testExistingWeightDedupeAndLedgerMissingLogSemanticsStayUnchanged() throws {
        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.startOfDay(for: today)
        let previous = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: end))
        let points = [WeightTrendPoint(date: previous, kilograms: 62),
                      WeightTrendPoint(date: previous.addingTimeInterval(0.4), kilograms: 62.1),
                      WeightTrendPoint(date: end, kilograms: 61.9)]
        let deduped = DashboardMath.dedupeWeightTrendByWholeSecond(points)
        XCTAssertEqual(deduped, Array(points.suffix(2)))
        let days = [HistoryDay(date: previous, eatenKcal: 0, logged: false),
                    HistoryDay(date: end, eatenKcal: 1_500, logged: true)]
        XCTAssertNil(DashboardMath.averageKcal(days, today: end))
        XCTAssertEqual(DashboardMath.daysLogged(days, today: end), 0)
        _ = WeightDeltaTimeline(days: days.map(WeightDeltaDay.init(day:)), points: deduped, today: end)
        XCTAssertEqual(deduped, Array(points.suffix(2)), "food alignment must not resample the weight trace")
    }
}

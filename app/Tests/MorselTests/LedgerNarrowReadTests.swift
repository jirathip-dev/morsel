import XCTest
@testable import Morsel

// Issue #193 — the History overview must transfer only what the ledger renders.
// These tests drive the production read methods through a PostgREST-shaped
// transport seam: the selected columns and the delivered payload bytes are
// asserted from the real request/response, and every aggregation case is
// compared against the base-pin baseline computed from the identical fixture
// rows. RED at the base pin: the overview asks for the shared rich item
// projection (`mealItemColumns`) and the full meal-log row.

final class LedgerNarrowReadTests: LedgerNarrowTestCase {
    func testOverviewRequestsOnlyTheNarrowLedgerColumns() async throws {
        LedgerStubTransport.configure(.multipleMeals)
        let overview = try await repository().loadHistory(userID: account, end: referenceInstant, days: 7)

        let logs = try XCTUnwrap(LedgerStubTransport.records("meal_logs").first)
        let items = try XCTUnwrap(LedgerStubTransport.records("meal_items").first)
        XCTAssertEqual(logs.select, ["id", "eaten_at"], "the ledger needs meal identity and date only")
        XCTAssertEqual(items.select, ["meal_log_id", "calories_kcal"], "the ledger needs the calorie contribution only")

        let transferred = Set(logs.select + items.select)
        let ledgerNeverRenders: Set<String> = [
            "name", "quantity", "unit", "protein_g", "carbs_g", "fat_g", "fiber_g", "sugar_g",
            "confidence", "source_notes", "menu_group_id", "menu_name", "artwork_id",
            "meal_type", "source", "image_path"
        ]
        XCTAssertTrue(
            transferred.isDisjoint(with: ledgerNeverRenders),
            "descriptive/nutrition/menu/photo fields must not be transferred: \(transferred)"
        )

        XCTAssertEqual(overview.days.count, 7)
        XCTAssertEqual(overview.goal?.calorieTargetKcal, 2000, "the fixture is really aggregated")
        XCTAssertTrue(overview.days.contains { $0.eatenKcal > 0 })
    }

    func testPayloadBytesOnIdenticalFixturesAreSmallerThanTheBaselineProjection() async throws {
        for fixture in [LedgerFixture.multipleMeals, LedgerFixture.menuSnapshot] {
            LedgerStubTransport.configure(fixture)
            _ = try await repository().loadHistory(userID: account, end: referenceInstant, days: 7)

            let logs = try XCTUnwrap(LedgerStubTransport.records("meal_logs").first)
            let items = try XCTUnwrap(LedgerStubTransport.records("meal_items").first)
            // The delivered body is the identical rows through the request's own select.
            XCTAssertEqual(logs.body, LedgerStubTransport.projectedBody("meal_logs", selecting: logs.select))
            XCTAssertEqual(items.body, LedgerStubTransport.projectedBody("meal_items", selecting: items.select))
            // Hand-written expectation for the same bytes: no parallel calculation.
            let expectedLogs = "[" + fixture.meals.map { "{\"id\":\"\($0.id)\",\"eaten_at\":\"\($0.eatenAt)\"}" }
                .joined(separator: ",") + "]"
            XCTAssertEqual(logs.body, expectedLogs)
            // The base pin's selects on the identical rows: the rich meal-log row and mealItemColumns.
            let baseLogs = LedgerStubTransport.projectedBody(
                "meal_logs", selecting: ["id", "eaten_at", "meal_type", "source", "image_path"]
            )
            let baseItems = LedgerStubTransport.projectedBody(
                "meal_items", selecting: mealItemColumns.split(separator: ",").map(String.init)
            )
            print(
                "ISSUE193-BYTES fixture=\(fixture.name) "
                    + "meal_logs narrow=\(logs.bytes) baseline=\(baseLogs.utf8.count) "
                    + "meal_items narrow=\(items.bytes) baseline=\(baseItems.utf8.count)"
            )
            XCTAssertLessThan(logs.bytes, baseLogs.utf8.count, fixture.name)
            XCTAssertLessThan(items.bytes, baseItems.utf8.count, fixture.name)
            XCTAssertFalse(logs.body.contains("\"image_path\""), fixture.name)
            XCTAssertTrue(baseLogs.contains("\"image_path\""), fixture.name)
            XCTAssertFalse(items.body.contains("\"name\""), fixture.name)
            XCTAssertTrue(baseItems.contains("\"name\""), fixture.name)
        }
    }

    func testNarrowAndBaselineAggregationMatchForEveryFixture() async throws {
        let calendar = Calendar.autoupdatingCurrent
        for fixture in LedgerFixture.aggregationCases {
            LedgerStubTransport.configure(fixture)
            let overview = try await repository().loadHistory(userID: account, end: referenceInstant, days: 7)
            let baseline = LedgerBaseline.days(fixture, end: referenceInstant, count: 7, calendar: calendar)
            XCTAssertEqual(
                overview.days.map(LedgerDayValue.init), baseline.map(LedgerDayValue.init),
                "narrow and baseline aggregation must match: \(fixture.name)"
            )
            // AC3 — the untouched goal/weight reads keep the base-pin values.
            XCTAssertEqual(
                overview.goal,
                DashboardGoal(calorieTargetKcal: 2000, proteinG: 150, carbsG: 200, fatG: 60, source: .manual),
                fixture.name
            )
            XCTAssertEqual(overview.weightTrend.map(\.kilograms), [81.2], fixture.name)
        }

        // A zone-independent total for the multi-meal case: 420 + (null) + 180 + 95.5 + 300.
        LedgerStubTransport.configure(.multipleMeals)
        let multi = try await repository().loadHistory(userID: account, end: referenceInstant, days: 7)
        XCTAssertEqual(multi.days.reduce(0) { $0 + $1.eatenKcal }, 995.5, accuracy: 0.001)
    }

    func testLoggedEmptyAndZeroCalorieDaysStayDistinct() async throws {
        LedgerStubTransport.configure(.loggedAndZero)
        let overview = try await repository().loadHistory(userID: account, end: referenceInstant, days: 7)
        let calendar = Calendar.autoupdatingCurrent
        let nullDay = calendar.startOfDay(for: instant("2026-09-01T20:00:00.000Z"))
        let zeroDay = calendar.startOfDay(for: instant("2026-09-02T20:00:00.000Z"))

        XCTAssertEqual(overview.days.first { $0.date == nullDay }?.logged, true, "a null-calorie meal is logged")
        XCTAssertEqual(overview.days.first { $0.date == nullDay }?.eatenKcal, 0)
        XCTAssertEqual(overview.days.first { $0.date == zeroDay }?.logged, true, "a zero-calorie meal is logged")
        XCTAssertEqual(overview.days.first { $0.date == zeroDay }?.eatenKcal, 0)
        XCTAssertEqual(overview.days.filter(\.logged).count, 2, "only the two meal days are logged")
        XCTAssertTrue(overview.days.contains { !$0.logged && $0.eatenKcal == 0 }, "a day with no meals stays unlogged")
        XCTAssertFalse(overview.days.contains { $0.eatenKcal > 0 }, "no fixture row carries calories")
    }

    func testLocalDayBucketingAcrossDSTTransitions() async throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let springEnd = instant("2026-03-08T17:00:00Z")
        LedgerStubTransport.configure(.dstSpringForward)
        let spring = try await repository().loadHistory(
            userID: account, end: springEnd, days: 2, calendar: calendar
        )
        XCTAssertEqual(
            spring.days.map(LedgerDayValue.init),
            LedgerBaseline.days(.dstSpringForward, end: springEnd, count: 2, calendar: calendar)
                .map(LedgerDayValue.init)
        )
        let springLogged = spring.days.filter(\.logged)
        XCTAssertEqual(springLogged.map(\.eatenKcal), [300, 540], "01:30 EST and 03:30 EDT are one 23-hour day")
        XCTAssertEqual(springLogged.map(\.date), [
            calendar.startOfDay(for: instant("2026-03-07T06:30:00Z")),
            calendar.startOfDay(for: instant("2026-03-08T06:30:00Z"))
        ])
        XCTAssertEqual(
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: instant("2026-03-08T06:30:00Z"))),
            instant("2026-03-09T04:00:00Z"),
            "the local day after the spring-forward day starts 23 hours later"
        )

        let fallEnd = instant("2026-11-01T17:00:00Z")
        LedgerStubTransport.configure(.dstFallBack)
        let fall = try await repository().loadHistory(userID: account, end: fallEnd, days: 2, calendar: calendar)
        XCTAssertEqual(
            fall.days.map(LedgerDayValue.init),
            LedgerBaseline.days(.dstFallBack, end: fallEnd, count: 2, calendar: calendar).map(LedgerDayValue.init)
        )
        let fallLogged = fall.days.filter(\.logged)
        XCTAssertEqual(fallLogged.map(\.eatenKcal), [210, 390], "01:30 EDT and 01:30 EST are one 25-hour day")
        XCTAssertEqual(
            calendar.startOfDay(for: instant("2026-11-01T05:30:00Z")),
            calendar.startOfDay(for: instant("2026-11-01T06:30:00Z")),
            "the repeated 01:30 local hour buckets to one local day"
        )
        XCTAssertEqual(
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: instant("2026-11-01T05:30:00Z"))),
            instant("2026-11-02T05:00:00Z"),
            "the local day after the fall-back day starts 25 hours later"
        )
    }

    func testDrillDownStillRetrievesCompleteItemsAndImages() async throws {
        let imagePath = "\(account.uuidString)/\(LedgerFixture.mealID(1)).jpg"
        let fixture = LedgerFixture(
            name: "drill-down",
            meals: [LedgerFixture.meal(1, at: "2026-09-05T02:00:00.000Z", image: imagePath)],
            items: [
                LedgerFixture.item(1, meal: 1, kcal: 640, menuName: "Chipotle bowl",
                                   menuGroupID: "33333333-3333-4333-8333-333333333333",
                                   artworkID: "44444444-4444-4444-8444-444444444444"),
                LedgerFixture.item(2, meal: 1, kcal: 160)
            ]
        )
        LedgerStubTransport.configure(fixture)
        let snapshot = try await repository().loadToday(userID: account, date: referenceInstant)

        let logs = try XCTUnwrap(LedgerStubTransport.records("meal_logs").first)
        let items = try XCTUnwrap(LedgerStubTransport.records("meal_items").first)
        XCTAssertEqual(logs.select, ["id", "eaten_at", "meal_type", "source", "image_path"],
                       "the drill-down keeps the complete meal-log row")
        XCTAssertEqual(items.select, mealItemColumns.split(separator: ",").map(String.init),
                       "the drill-down keeps the shared rich item projection")

        let meal = try XCTUnwrap(snapshot.meals.first)
        XCTAssertEqual(meal.imagePath, imagePath, "the drill-down still carries the meal photo path")
        XCTAssertEqual(meal.items.count, 2)
        let item = try XCTUnwrap(meal.items.first { $0.itemID.uuidString == LedgerFixture.itemID(1) })
        XCTAssertEqual(item.name, "Synthetic bowl 22222221")
        XCTAssertEqual(item.quantity, 1.5)
        XCTAssertEqual(item.unit, .serving)
        XCTAssertEqual(item.proteinG, 42)
        XCTAssertEqual(item.notes, "synthetic note")
        XCTAssertEqual(item.menuName, "Chipotle bowl")
        XCTAssertEqual(item.menuGroupID?.uuidString.lowercased(), "33333333-3333-4333-8333-333333333333")
        XCTAssertEqual(item.artworkID, "44444444-4444-4444-8444-444444444444")
    }
}

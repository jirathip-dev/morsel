import SwiftUI
import Supabase
import XCTest
@testable import Morsel

@MainActor
final class JournalCalendarTests: XCTestCase {
    private let userID = UUID()
    private func date(_ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 8, day: day)) ?? .distantPast
    }

    func testAllHistoryCrossesEmptyMonthsAndStopsOneDayBeforeTheFirstMeal() async {
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: date(5), meals: [], goal: nil))
        let first = date(5)
        repository.seed(history: HistoryOverview(
            days: [HistoryDay(date: first, eatenKcal: 400, logged: true)], goal: nil))
        let calendar = JournalCalendarModel(repository: repository, userID: userID, today: date(100))
        await calendar.load()
        XCTAssertEqual(calendar.firstLoggedDay, first)
        XCTAssertEqual(calendar.earliestDay, date(4))
        XCTAssertGreaterThan(calendar.months.count, 3, "empty intervening months must not truncate history")
        XCTAssertEqual(calendar.adjacent(to: first, direction: .backward), date(4))
        XCTAssertNil(calendar.adjacent(to: date(4), direction: .backward))
        XCTAssertNil(calendar.adjacent(to: date(100), direction: .forward))
        XCTAssertFalse(calendar.allows(date(3)))
        XCTAssertTrue(calendar.allows(date(40)), "an unlogged day inside history is still openable")
    }

    func testMonthGridKeepsMondayBlanksLeapDayAndPresence() async {
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: date(5), meals: [], goal: nil))
        repository.seed(history: HistoryOverview(
            days: [HistoryDay(date: date(5), eatenKcal: 400, logged: true)], goal: nil))
        let model = JournalCalendarModel(repository: repository, userID: userID, today: date(100))
        await model.showMonth(containing: date(5))
        XCTAssertEqual(model.cells.prefix(5).compactMap { $0 }.count, 0, "August 2026 starts on Saturday")
        XCTAssertEqual(model.cells.compactMap { $0 }.count, 31)
        XCTAssertEqual(model.loggedDates, [date(5)])
        let leap = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2024, month: 2, day: 1)) ?? date(1)
        await model.showMonth(containing: leap)
        XCTAssertEqual(model.cells.compactMap { $0 }.count, 29)
    }

    func testSelectedDateLoadAndTrueEmptyPrehistoryPage() async {
        let repository = DiaryReadRepository()
        repository.meals = [meal(on: date(5))]
        let model = DashboardViewModel(repository: repository, userID: userID, dateProvider: { self.date(10) })
        await model.load()
        model.selectDate(date(5))
        XCTAssertNil(model.snapshot, "the outgoing date must not remain below the new label")
        await model.load()
        XCTAssertEqual(model.snapshot?.date, date(5))
        XCTAssertEqual(model.totals.caloriesKcal, 400)
        model.selectDate(date(4))
        await model.load()
        XCTAssertEqual(model.snapshot?.date, date(4))
        XCTAssertTrue(model.mealGroups.isEmpty)
        XCTAssertEqual(model.totals, DashboardTotals(caloriesKcal: 0, proteinG: 0, carbsG: 0, fatG: 0))
        XCTAssertEqual(repository.requestedDates, [date(10), date(5), date(4)])
    }

    func testCachedPastDayPaintsBeforeItsRemoteReadCompletes() async throws {
        let repository = DiaryReadRepository()
        repository.cached = DashboardSnapshot(date: date(5), meals: [meal(on: date(5))], goal: nil)
        repository.parkedDate = date(5)
        let model = DashboardViewModel(repository: repository, userID: userID, dateProvider: { self.date(10) })
        model.selectDate(date(5))
        let task = Task { await model.load() }
        for _ in 0..<100 where repository.pending == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(repository.pending)
        XCTAssertEqual(model.totals.caloriesKcal, 400, "cache must paint while network is still parked")
        XCTAssertTrue(model.isLoading)
        repository.release()
        await task.value
    }

    func testUncachedFailureDoesNotDisplayThePreviousDatesMeals() async {
        let repository = DiaryReadRepository()
        repository.meals = [meal(on: date(5))]
        let model = DashboardViewModel(repository: repository, userID: userID, dateProvider: { self.date(10) })
        model.selectDate(date(5))
        await model.load()
        repository.failure = MorselError.configurationMissing
        model.selectDate(date(4))
        await model.load()
        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testPastDateAddAndConfirmationReloadThatDate() async throws {
        let repository = DiaryReadRepository()
        let model = DashboardViewModel(repository: repository, userID: userID, dateProvider: { self.date(10) })
        model.selectDate(date(5))
        let stamp = JournalDiaryDraft.date(on: date(5), now: date(10))
        let draft = MealDraft(mealType: .lunch, eatenAt: stamp, items: [MealItemDraft(name: "Rice")])
        let saved = await model.addMeal(draft: draft, photo: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(repository.savedDraft?.eatenAt, stamp)
        let itemID = UUID()
        let confirmed = await model.markReviewed(itemID)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(repository.confirmedItem, itemID)
        // Issue #190 — the confirmation no longer waits for the reload: the
        // invalidated pass still relists the SAME selected day (bounded wait).
        for _ in 0..<200 where repository.requestedDates.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(repository.requestedDates, [date(5), date(5)])
        let label = stamp.formatted(.dateTime.day().month(.abbreviated))
        XCTAssertEqual(JournalDiaryDraft.title(for: stamp), "Add to " + label)
        XCTAssertEqual(JournalDiaryDraft.saveTitle(for: stamp), "Save to " + label)
    }

    func testDateIdentifiersUseTheLocalCalendarDayInEveryZone() throws {
        let zones = ["Asia/Bangkok", "Pacific/Kiritimati", "UTC", "America/Los_Angeles"]
        let dates = [(2026, 8, 14, "2026-08-14"), (2026, 1, 1, "2026-01-01"),
                     (2024, 2, 29, "2024-02-29"), (2026, 3, 8, "2026-03-08")]
        for zone in zones {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            for (year, month, day, expected) in dates {
                let date = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
                let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: date, meals: [], goal: nil))
                let model = JournalCalendarModel(repository: repository, userID: userID,
                                                 today: date, calendar: calendar)
                let view = JournalCalendarView(model: model, selectedDate: date) { _ in }
                let cell = try XCTUnwrap(model.cells.compactMap { $0 }.first { $0 == date })
                XCTAssertEqual(view.dateIdentifier(for: cell), "diary-date-" + expected, zone)
                let late = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: cell))
                XCTAssertEqual(view.dateIdentifier(for: late), "diary-date-" + expected, zone)
            }
        }
    }

    func testDateStepsUseCalendarDaysAcrossDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: first))
        XCTAssertEqual(next.timeIntervalSince(first), 23 * 60 * 60)
        let draftDate = JournalDiaryDraft.date(on: first, now: next, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: draftDate), 0)
    }

    private func meal(on date: Date) -> MealRecord {
        let item = MealItem(itemID: UUID(), name: "Rice", quantity: 1, unit: .serving,
                            caloriesKcal: 400, proteinG: 10, carbsG: 50, fatG: 15,
                            fiberG: nil, sugarG: nil, confidence: 1, notes: nil)
        return MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: date, source: .manual, items: [item])
    }
}

@MainActor
final class JournalMonthSpanTests: XCTestCase {
    override func tearDown() {
        StubTransport.release()
        StubTransport.reset()
        super.tearDown()
    }

    func testThirtyOneDayMonthKeepsBothEdgeDotComparisonsWhenASecondReadWouldFail() async throws {
        // The old trailing-30 + first-day read loses ALL colours if that second read throws.
        try await assertMonth(year: 2026, month: 8, lastDay: 31, zone: "Asia/Bangkok")
    }

    func testMonthLengthsPartialMonthAndDSTUseExactLocalDayBounds() async throws {
        for (year, month, lastDay) in [(2026, 2, 28), (2024, 2, 29), (2026, 4, 30),
                                        (2026, 3, 31), (2026, 11, 30), (2026, 8, 14), (2026, 8, 1)] {
            try await assertMonth(year: year, month: month, lastDay: lastDay, zone: "America/New_York")
        }
    }

    private func assertMonth(year: Int, month: Int, lastDay: Int, zone: String) async throws {
        StubTransport.reset()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        let first = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: 1)))
        let last = try XCTUnwrap(calendar.date(byAdding: .day, value: lastDay - 1, to: first))
        let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: last))
        let edges = Array(Set([first, last])).sorted()
        seedMeals(on: edges)
        let userID = UUID()
        let remote = try makeRemote(userID: userID)
        let repository = DiaryReadRepository()
        repository.indexedDates = edges
        var reads: [(Date, Int)] = []
        repository.historyRead = { userID, end, days in
            reads.append((end, days))
            let overview = try await remote.loadHistory(userID: userID, end: end, days: days, calendar: calendar)
            // Fail the actual transport if the model attempts another totals read.
            StubTransport.respond("goals", .init(status: 503, body: "{\"message\":\"second read unavailable\"}"))
            return overview
        }
        let model = JournalCalendarModel(repository: repository, userID: userID, today: last, calendar: calendar)
        await model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(reads.count, 1, "one month overview, never a patch-up read")
        XCTAssertEqual(reads.first?.0, last)
        XCTAssertEqual(reads.first?.1, lastDay)
        XCTAssertEqual(model.days.count, lastDay, "the real repository must not clamp a month to 30")
        XCTAssertEqual(model.days.first?.date, first)
        XCTAssertEqual(model.days.last?.date, last)
        XCTAssertEqual(model.loggedDates, Set(edges))
        for edge in edges {
            let day = try XCTUnwrap(model.days.first { $0.date == edge })
            let target = try XCTUnwrap(model.goal?.calorieTargetKcal)
            XCTAssertTrue(day.logged)
            XCTAssertEqual(day.eatenKcal, 3000)
            // These are the exact inputs JournalCalendarView.dotColor uses, not the forest fallback.
            XCTAssertEqual(DashboardMath.comparison(delta: day.eatenKcal - target), .over)
        }
        let requests = StubTransport.snapshot()
        XCTAssertEqual(requests.count(.started, "meal_logs"), 1)
        XCTAssertEqual(Set(requests.queryValues("meal_logs", "eaten_at")),
                       Set(["gte.\(MorselDate.iso8601(first))", "lt.\(MorselDate.iso8601(next))"]))
    }

    private func seedMeals(on dates: [Date]) {
        let ids = dates.map { _ in UUID().uuidString }
        let logs = zip(dates, ids).map { date, identifier in
            """
            {"id":"\(identifier)","eaten_at":"\(MorselDate.iso8601(date))","meal_type":"lunch",\
            "source":"manual","image_path":null}
            """
        }
        let items = ids.map { identifier in
            """
            {"id":"\(UUID().uuidString)","meal_log_id":"\(identifier)","name":"Rice","quantity":1,\
            "unit":"serving","calories_kcal":3000}
            """
        }
        StubTransport.respond("meal_logs", .init(body: "[" + logs.joined(separator: ",") + "]"))
        StubTransport.respond("meal_items", .init(body: "[" + items.joined(separator: ",") + "]"))
    }

    private func makeRemote(userID: UUID) throws -> SupabaseDashboardRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        configuration.urlCache = nil
        let client = SupabaseClient(
            supabaseURL: try XCTUnwrap(URL(string: "https://stub.supabase.test")), supabaseKey: "stub-anon-key",
            options: SupabaseClientOptions(
                auth: .init(storage: StubSessionStorage(userID: userID, expiresAt: Date().addingTimeInterval(3600)),
                            storageKey: "sb-stub-auth-token", autoRefreshToken: false),
                global: .init(session: URLSession(configuration: configuration))))
        return SupabaseDashboardRepository(client: client)
    }
}

@MainActor
final class JournalDiaryGestureTests: XCTestCase {
    func testDateRailVerticalDragLeavesHorizontalPagerAloneAndFlipsBothDays() throws {
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = today.addingTimeInterval(-86400)
        let day = JournalTurnState<Date>(base: today, adjacent: { value, direction in
            direction == .backward ? value.addingTimeInterval(-86400) : value.addingTimeInterval(86400)
        }, direction: { $0 < $1 ? .forward : .backward })
        let tabs = JournalTurnMachine()
        // The real date-rail adapter rotates coordinates; the shell receives the original drag.
        tabs.dragChanged(deltaX: 0, deltaY: -90, width: 390)
        day.dragChanged(deltaX: 90, deltaY: 0, width: 120)
        XCTAssertNil(tabs.turn)
        XCTAssertEqual(day.turn?.incoming, yesterday)
        let effect = try XCTUnwrap(day.dragEnded(deltaX: 90, predictedX: 90, width: 120))
        XCTAssertTrue(day.complete(operation: effect.operation))
        XCTAssertEqual(day.baseTab, yesterday)
        day.dragChanged(deltaX: -90, deltaY: 0, width: 120)
        let next = try XCTUnwrap(day.dragEnded(deltaX: -90, predictedX: -90, width: 120))
        XCTAssertTrue(day.complete(operation: next.operation))
        XCTAssertEqual(day.baseTab, today)
    }

    func testHorizontalDragOwnsTabsAndCannotAlsoOwnTheDateRail() throws {
        let date = Date()
        let day = JournalTurnState<Date>(base: date, adjacent: {
            $0.addingTimeInterval($1 == .forward ? 86400 : -86400)
        }, direction: { $0 < $1 ? .forward : .backward })
        let tabs = JournalTurnMachine()
        tabs.dragChanged(deltaX: -300, deltaY: 0, width: 390)
        day.dragChanged(deltaX: 0, deltaY: -300, width: 120)
        XCTAssertNil(day.turn)
        XCTAssertNil(day.dragEnded(deltaX: 0, predictedX: 0, width: 120))
        let effect = try XCTUnwrap(tabs.dragEnded(deltaX: -300, predictedX: -300, width: 390))
        XCTAssertTrue(tabs.complete(operation: effect.operation))
        XCTAssertEqual(tabs.baseTab, .history)
        XCTAssertEqual(day.baseTab, date)
    }

    func testDateTurnInheritsRollbackTokenAndInterruptGuarantees() throws {
        let date = Date()
        let day = JournalTurnState<Date>(base: date, adjacent: {
            $0.addingTimeInterval($1 == .forward ? 86400 : -86400)
        }, direction: { $0 < $1 ? .forward : .backward })
        day.dragChanged(deltaX: 20, deltaY: 0, width: 120)
        let old = try XCTUnwrap(day.dragEnded(deltaX: 20, predictedX: 20, width: 120))
        day.dragChanged(deltaX: 90, deltaY: 0, width: 120)
        XCTAssertFalse(day.complete(operation: old.operation))
        XCTAssertEqual(day.phase, .dragging)
        day.interrupt()
        XCTAssertTrue(day.atRest)
        XCTAssertEqual(day.baseTab, date)
        XCTAssertFalse(day.complete(operation: old.operation))
    }
}

import XCTest
@testable import Morsel

@MainActor
final class HistoryCacheScopeTests: HistoryCacheTestCase {
    func testCacheIsScopedByAccountDayAndRange() async throws {
        let repo = try repository()
        try await seed(repo)
        let otherAccount = UUID()
        let otherRepo = try repository(accountID: otherAccount)
        let wrongAccountHistory = try await otherRepo.cachedHistory(userID: otherAccount, end: today, days: 7)
        let wrongAccountDay = try await otherRepo.cachedToday(userID: otherAccount, date: today)
        let wrongRange = try await repo.cachedHistory(userID: account, end: today, days: 30)
        let tomorrow = today.addingTimeInterval(86_400)
        let wrongDay = try await repo.cachedToday(userID: account, date: tomorrow)
        let wrongEnd = try await repo.cachedHistory(userID: account, end: tomorrow, days: 7)
        XCTAssertNil(wrongAccountHistory)
        XCTAssertNil(wrongAccountDay)
        XCTAssertNil(wrongRange)
        XCTAssertNil(wrongDay)
        XCTAssertNil(wrongEnd)
        await remote.hold()
        let viewModel = model(otherRepo, accountID: otherAccount)
        let load = Task { await viewModel.load() }
        await waitFor("history-7")
        XCTAssertNil(viewModel.overview, "new account must use its own cold cache")
        await remote.release("history-7")
        await complete(load)
        XCTAssertEqual(viewModel.overview?.days.last?.eatenKcal, 200)
        XCTAssertEqual(viewModel.overview?.readProvenance?.isCached, false)
    }

    func testTimezoneChangeCannotReuseOrPublishTheOldLocalDay() async throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        let repo = try repository()
        try await seed(repo)
        let oldKey = LocalFirstDashboardRepository.dayKey(today)
        await remote.hold()
        let viewModel = model(repo)
        let load = Task { await viewModel.load() }
        await waitFor("history-7")
        let selection = Task { await viewModel.select(day()) }
        await waitFor(dayKey())
        XCTAssertNotNil(viewModel.overview)
        XCTAssertNotNil(viewModel.daySnapshot)
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertNotEqual(LocalFirstDashboardRepository.dayKey(today), oldKey)
        await remote.release("history-7")
        await remote.release(dayKey())
        await complete(load)
        await complete(selection)
        XCTAssertNil(viewModel.overview)
        XCTAssertNil(viewModel.daySnapshot)
        XCTAssertNil(viewModel.expandedDay)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.expandedError)
        let wrongHistory = try await repo.cachedHistory(userID: account, end: today, days: 7)
        let wrongDay = try await repo.cachedToday(userID: account, date: today)
        XCTAssertNil(wrongHistory)
        XCTAssertNil(wrongDay)
        let nextLoad = Task { await viewModel.load() }
        await waitFor("history-7")
        XCTAssertNil(viewModel.overview)
        await remote.release("history-7")
        await complete(nextLoad)
        XCTAssertEqual(viewModel.overview?.days.last?.date, DashboardMath.startOfLocalDay(today))
    }

    func testLegacyCacheHasNoInventedFreshnessTime() throws {
        let legacy = HistoryCacheFixture.overview(end: today, days: 7, value: 100)
        let payload = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(HistoryOverview.self, from: payload)
        XCTAssertNil(decoded.readProvenance)
        XCTAssertNil(decoded.cachedCopy.readProvenance?.loadedAt)
        XCTAssertEqual(decoded.cachedCopy.readProvenance?.isCached, true)
    }
}

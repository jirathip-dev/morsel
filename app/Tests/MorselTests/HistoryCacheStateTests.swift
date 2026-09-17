import XCTest
@testable import Morsel

@MainActor
final class HistoryCacheStateTests: HistoryCacheTestCase {
    func testFailedRefreshKeepsCacheAndOriginalFreshnessAcrossReopen() async throws {
        let repo = try repository()
        try await seed(repo)
        let saved = try await repo.cachedHistory(userID: account, end: today, days: 7)
        let savedDay = try await repo.cachedToday(userID: account, date: today)
        await remote.hold()
        let viewModel = model(try repository()) // Reopen the same account's actual SQLite cache.
        let overviewTask = Task { await viewModel.load() }
        await waitFor("history-7")
        let dayTask = Task { await viewModel.select(day()) }
        await waitFor(dayKey())
        XCTAssertEqual(viewModel.overview?.readProvenance?.isCached, true)
        XCTAssertEqual(viewModel.daySnapshot?.readProvenance?.isCached, true)
        await remote.release("history-7", error: URLError(.notConnectedToInternet))
        await remote.release(dayKey(), error: URLError(.timedOut))
        await complete(overviewTask)
        await complete(dayTask)
        XCTAssertEqual(viewModel.overview?.days.last?.eatenKcal, 100)
        XCTAssertEqual(viewModel.daySnapshot?.meals.first?.items.first?.caloriesKcal, 100)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.expandedError)
        XCTAssertNotNil(saved?.readProvenance?.loadedAt)
        XCTAssertEqual(viewModel.overview?.readProvenance, saved?.readProvenance)
        XCTAssertEqual(viewModel.daySnapshot?.readProvenance, savedDay?.readProvenance)

        let retry = Task { await viewModel.load() }
        await waitFor("history-7")
        await remote.release("history-7")
        await complete(retry)
        XCTAssertEqual(viewModel.overview?.readProvenance?.isCached, false)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testColdCacheKeepsSkeletonThenShowsErrorsNotAnEmptySuccess() async throws {
        await remote.hold()
        let viewModel = model(try repository())
        let overviewTask = Task { await viewModel.load() }
        await waitFor("history-7")
        let dayTask = Task { await viewModel.select(day()) }
        await waitFor(dayKey())
        XCTAssertNil(viewModel.overview)
        XCTAssertNil(viewModel.daySnapshot)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.isExpandedLoading)
        await remote.release("history-7", error: URLError(.notConnectedToInternet))
        await remote.release(dayKey(), error: URLError(.notConnectedToInternet))
        await complete(overviewTask)
        await complete(dayTask)
        XCTAssertNil(viewModel.overview)
        XCTAssertNil(viewModel.daySnapshot)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.expandedError)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isExpandedLoading)
    }

    func testCancellationKeepsCachedContentWithoutMisleadingErrorOrFreshness() async throws {
        let repo = try repository()
        try await seed(repo)
        await remote.hold()
        let viewModel = model(repo)
        let overviewTask = Task { await viewModel.load() }
        await waitFor("history-7")
        let dayTask = Task { await viewModel.select(day()) }
        await waitFor(dayKey())
        overviewTask.cancel()
        dayTask.cancel()
        await remote.release("history-7") // A non-cooperative success after cancellation.
        await remote.release(dayKey(), error: URLError(.notConnectedToInternet))
        await complete(overviewTask)
        await complete(dayTask)
        XCTAssertEqual(viewModel.overview?.days.last?.eatenKcal, 100)
        XCTAssertEqual(viewModel.daySnapshot?.meals.first?.items.first?.caloriesKcal, 100)
        XCTAssertEqual(viewModel.overview?.readProvenance?.isCached, true)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.expandedError)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isExpandedLoading)
        let cached = try await repo.cachedHistory(userID: account, end: today, days: 7)
        XCTAssertEqual(cached?.days.last?.eatenKcal, 100, "cancelled success must not overwrite the cache")
    }

    func testTransportCancellationIsNotReportedAsOffline() async throws {
        await remote.hold()
        let viewModel = model(try repository())
        let overviewTask = Task { await viewModel.load() }
        await waitFor("history-7")
        let dayTask = Task { await viewModel.select(day()) }
        await waitFor(dayKey())
        await remote.release("history-7", error: URLError(.cancelled))
        await remote.release(dayKey(), error: CancellationError())
        await complete(overviewTask)
        await complete(dayTask)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.expandedError)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isExpandedLoading)
    }
}

@MainActor
final class HistoryCacheSelectionTests: HistoryCacheTestCase {
    func testRangeSwitchClearsOldCacheAndRejectsLateOverviewAndDay() async throws {
        let repo = try repository()
        try await seed(repo)
        try await seed(repo, days: 30)
        await remote.hold()
        let viewModel = model(repo)
        let oldRange = Task { await viewModel.load() }
        await waitFor("history-7")
        let oldDay = Task { await viewModel.select(day()) }
        await waitFor(dayKey())
        viewModel.range = .thirty
        XCTAssertNil(viewModel.overview)
        XCTAssertNil(viewModel.daySnapshot)
        XCTAssertNil(viewModel.expandedDay)
        let newRange = Task { await viewModel.load() }
        await waitFor("history-30")
        XCTAssertEqual(viewModel.overview?.days.count, 30)
        await remote.release("history-7", error: URLError(.timedOut))
        await remote.release(dayKey())
        await complete(oldRange)
        await complete(oldDay)
        XCTAssertTrue(viewModel.isLoading, "an old defer cannot clear the new refresh flag")
        XCTAssertEqual(viewModel.overview?.days.count, 30)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.daySnapshot)
        XCTAssertNil(viewModel.expandedDay)
        await remote.release("history-30")
        await complete(newRange)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testSelectedDaySwitchAndCollapseRejectLateRemoteResults() async throws {
        let repo = try repository()
        let yesterday = today.addingTimeInterval(-86_400)
        try await seed(repo)
        try await seed(repo, date: yesterday)
        await remote.hold()
        let viewModel = model(repo)
        let oldDay = Task { await viewModel.select(day(yesterday)) }
        await waitFor(dayKey(yesterday))
        let newDay = Task { await viewModel.select(day()) }
        await waitFor(dayKey())
        XCTAssertEqual(viewModel.daySnapshot?.date, today)
        await remote.release(dayKey(yesterday), error: URLError(.timedOut))
        await complete(oldDay)
        XCTAssertEqual(viewModel.daySnapshot?.date, today)
        XCTAssertTrue(viewModel.isExpandedLoading)
        XCTAssertNil(viewModel.expandedError)
        await viewModel.select(day())
        await remote.release(dayKey())
        await complete(newDay)
        XCTAssertNil(viewModel.daySnapshot)
        XCTAssertNil(viewModel.expandedDay)
        XCTAssertFalse(viewModel.isExpandedLoading)
    }

    func testLateCacheCannotPaintSupersededRangeOrCollapsedDay() async {
        await remote.hold(cache: true)
        let viewModel = model(remote)
        let oldRange = Task { await viewModel.load() }
        await waitFor("cache-history-7")
        let oldDay = Task { await viewModel.select(day()) }
        await waitFor("cache-" + dayKey())
        await viewModel.select(day())
        viewModel.range = .thirty
        await remote.releaseAll()
        await complete(oldRange)
        await complete(oldDay)
        XCTAssertNil(viewModel.overview)
        XCTAssertNil(viewModel.daySnapshot)
        XCTAssertNil(viewModel.expandedDay)
        let historyRequested = await remote.pending("history-7")
        let dayRequested = await remote.pending(dayKey())
        XCTAssertFalse(historyRequested)
        XCTAssertFalse(dayRequested)
    }
}

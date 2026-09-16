import XCTest
@testable import Morsel

@MainActor
final class HistoryCachePaintTests: HistoryCacheTestCase {
    // This file compiles unchanged at the pinned base: RED must be a publication assertion, not a build error.
    func testCachedOverviewAndMealsPublishWhileRemoteIsHeld() async throws {
        let repo = try repository()
        try await seed(repo)
        await remote.hold()
        let viewModel = model(repo)
        let overviewTask = Task { await viewModel.load() }
        await waitFor("history-7")
        let dayTask = Task { await viewModel.select(day()) }
        await waitFor(dayKey())

        XCTAssertEqual(viewModel.overview?.days.count, 7, "cache must paint before remote completion")
        XCTAssertEqual(viewModel.daySnapshot?.meals.first?.items.first?.caloriesKcal, 100,
                       "cached meals must paint before remote completion")
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.isExpandedLoading)

        await remote.release("history-7")
        await remote.release(dayKey())
        await complete(overviewTask)
        await complete(dayTask)
        XCTAssertEqual(viewModel.overview?.days.last?.eatenKcal, 200)
        XCTAssertEqual(viewModel.daySnapshot?.meals.first?.items.first?.caloriesKcal, 200)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isExpandedLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.expandedError)
    }
}

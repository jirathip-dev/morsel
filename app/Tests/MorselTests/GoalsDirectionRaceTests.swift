import XCTest
@testable import Morsel

// These behavioral cases use only the API present at the pinned #185 base.
@MainActor
final class GoalsDirectionRaceTests: XCTestCase {
    func testReversedSuccessesKeepBulkValuesSourcesAndSelection() async {
        let harness = GoalsDirectionHarness()
        let cut = await harness.start(.cut, test: self)
        let bulk = await harness.start(.bulk, test: self)
        harness.finish(1, .success(GoalsDirectionHarness.bulk))
        await bulk.value
        harness.finish(0, .success(GoalsDirectionHarness.cut))
        await cut.value
        harness.assertAccepted(GoalsDirectionHarness.bulk, direction: .bulk)
        XCTAssertNil(harness.model.errorMessage)
        XCTAssertEqual(harness.requests, [.cut, .bulk])
        print("ISSUE-185 reversed-success requests=\(harness.requests.count)")
    }

    func testObsoleteErrorCannotOverwriteNewerSuccess() async {
        let harness = GoalsDirectionHarness()
        let cut = await harness.start(.cut, test: self)
        let bulk = await harness.start(.bulk, test: self)
        harness.finish(1, .success(GoalsDirectionHarness.bulk))
        await bulk.value
        harness.finish(0, .failure(GoalsDirectionHarness.failure))
        await cut.value
        harness.assertAccepted(GoalsDirectionHarness.bulk, direction: .bulk)
        XCTAssertNil(harness.model.errorMessage)
        XCTAssertEqual(harness.requests.count, 2)
    }

    func testLatestFailurePreservesAcceptedValuesAndRetrySurvivesOldSuccess() async {
        let harness = GoalsDirectionHarness()
        await harness.seed(test: self)
        let cut = await harness.start(.cut, test: self)
        let bulk = await harness.start(.bulk, test: self)
        harness.finish(2, .failure(GoalsDirectionHarness.failure))
        await bulk.value
        let message = harness.model.errorMessage
        XCTAssertTrue(message?.contains("Tap Bulk to retry.") == true)
        harness.finish(1, .success(GoalsDirectionHarness.cut))
        await cut.value
        harness.assertAccepted(GoalsDirectionHarness.maintain, direction: .maintain)
        XCTAssertEqual(harness.model.errorMessage, message)
        let retry = await harness.start(.bulk, test: self)
        harness.finish(3, .success(GoalsDirectionHarness.bulk))
        await retry.value
        harness.assertAccepted(GoalsDirectionHarness.bulk, direction: .bulk)
        XCTAssertNil(harness.model.errorMessage)
        XCTAssertEqual(harness.requests, [.maintain, .cut, .bulk, .bulk])
    }

    func testManualEditInvalidatesBothLateSuccessAndError() async {
        for result in [Result.success(GoalsDirectionHarness.bulk), .failure(GoalsDirectionHarness.failure)] {
            let harness = GoalsDirectionHarness()
            await harness.seed(test: self)
            let bulk = await harness.start(.bulk, test: self)
            harness.model.edit("protein", value: "155.5")
            let fields = harness.fields
            let sources = harness.model.sources
            harness.finish(1, result)
            await bulk.value
            XCTAssertEqual(harness.fields, fields)
            XCTAssertEqual(harness.model.sources, sources)
            XCTAssertEqual(harness.model.sources["protein"], .manual)
            XCTAssertNil(harness.model.selectedDirection)
            XCTAssertNil(harness.model.errorMessage)
            XCTAssertEqual(harness.requests.count, 2)
        }
    }

    func testCallerCancellationDiscardsNoncooperativeSuccessAndError() async {
        for result in [Result.success(GoalsDirectionHarness.bulk), .failure(GoalsDirectionHarness.failure)] {
            let harness = GoalsDirectionHarness()
            await harness.seed(test: self)
            let bulk = await harness.start(.bulk, test: self)
            bulk.cancel()
            harness.finish(1, result)
            await bulk.value
            harness.assertAccepted(GoalsDirectionHarness.maintain, direction: .maintain)
            XCTAssertNil(harness.model.errorMessage)
            XCTAssertEqual(harness.requests.count, 2)
            XCTAssertEqual(harness.cancelledCompletions, [1])
        }
    }

    func testCutBulkCutUsesGenerationNotDirectionEquality() async {
        let harness = GoalsDirectionHarness()
        let first = await harness.start(.cut, test: self)
        let second = await harness.start(.bulk, test: self)
        let third = await harness.start(.cut, test: self)
        harness.finish(2, .success(GoalsDirectionHarness.cut))
        await third.value
        harness.finish(1, .success(GoalsDirectionHarness.bulk))
        await second.value
        harness.finish(0, .success(GoalsDirectionHarness.maintain))
        await first.value
        harness.assertAccepted(GoalsDirectionHarness.cut, direction: .cut)
        XCTAssertEqual(harness.requests, [.cut, .bulk, .cut])
    }
}

@MainActor
final class GoalsDirectionHarness {
    static let cut = DashboardGoal(calorieTargetKcal: 1800, proteinG: 120, carbsG: 195, fatG: 60, source: .computed)
    static let maintain = DashboardGoal(
        calorieTargetKcal: 2200, proteinG: 140, carbsG: 230, fatG: 80, source: .computed
    )
    static let bulk = DashboardGoal(calorieTargetKcal: 2600, proteinG: 160, carbsG: 310, fatG: 80, source: .computed)
    static let failure: Error = MorselError.requestFailed(503, "synthetic goals failure")
    let repository = GoalsPageRequestSpy()
    lazy var model = GoalsEditorViewModel(repository: repository, userID: UUID())
    private(set) var requests: [GoalDirection] = []
    private(set) var cancelledCompletions: [Int] = []
    private var continuations: [Int: CheckedContinuation<DashboardGoal, Error>] = [:]
    private var started: XCTestExpectation?

    init() {
        repository.compute = { [unowned self] direction in
            let index = requests.count
            requests.append(direction)
            defer { if Task.isCancelled { cancelledCompletions.append(index) } }
            return try await withCheckedThrowingContinuation { continuation in
                continuations[index] = continuation
                started?.fulfill()
                started = nil
            }
        }
    }

    var fields: [String] { [model.calories, model.protein, model.carbs, model.fat] }

    func start(_ direction: GoalDirection, test: XCTestCase) async -> Task<Void, Never> {
        let arrival = XCTestExpectation(description: "compute \(direction) arrives")
        started = arrival
        let task = Task { await model.choose(direction) }
        await test.fulfillment(of: [arrival], timeout: 3)
        return task
    }

    func finish(_ index: Int, _ result: Result<DashboardGoal, Error>) {
        guard let continuation = continuations.removeValue(forKey: index) else {
            XCTFail("No parked computation \(index)")
            return
        }
        continuation.resume(with: result)
    }

    func seed(test: XCTestCase) async {
        let task = await start(.maintain, test: test)
        finish(0, .success(Self.maintain))
        await task.value
    }

    func assertAccepted(_ goal: DashboardGoal, direction: GoalDirection,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.goal, goal, file: file, line: line)
        XCTAssertEqual(fields, [goal.calorieTargetKcal, goal.proteinG, goal.carbsG, goal.fatG]
            .map(GoalsEditorViewModel.displayValue), file: file, line: line)
        XCTAssertEqual(model.sources, ["calories": .computed, "protein": .computed,
                                      "carbs": .computed, "fat": .computed], file: file, line: line)
        XCTAssertEqual(model.selectedDirection, direction, file: file, line: line)
    }
}

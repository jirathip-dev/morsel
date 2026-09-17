import XCTest
@testable import Morsel

@MainActor
final class GoalsDirectionOwnershipTests: XCTestCase {
    func testPendingChoiceDoesNotClaimAcceptedValuesOrPermitSave() async {
        let harness = GoalsDirectionHarness()
        await harness.seed(test: self)
        let saved = await harness.model.save()
        XCTAssertTrue(saved)
        let bulk = await harness.start(.bulk, test: self)
        XCTAssertEqual(harness.model.pendingDirection, .bulk)
        harness.assertAccepted(GoalsDirectionHarness.maintain, direction: .maintain)
        let pendingSave = await harness.model.save()
        XCTAssertFalse(pendingSave)
        harness.finish(1, .success(GoalsDirectionHarness.bulk))
        await bulk.value
        XCTAssertNil(harness.model.pendingDirection)
        XCTAssertFalse(harness.model.didSave)
        harness.assertAccepted(GoalsDirectionHarness.bulk, direction: .bulk)
    }

    func testRepeatedEquivalentChoicesCoalesceWhilePendingAndAfterAcceptance() async {
        let harness = GoalsDirectionHarness()
        let bulk = await harness.start(.bulk, test: self)
        for _ in 0..<20 { await harness.model.choose(.bulk) }
        XCTAssertEqual(harness.requests, [.bulk])
        harness.finish(0, .success(GoalsDirectionHarness.bulk))
        await bulk.value
        for _ in 0..<20 { await harness.model.choose(.bulk) }
        XCTAssertEqual(harness.requests, [.bulk])
        harness.model.edit("fat", value: "95")
        let refresh = await harness.start(.bulk, test: self)
        harness.finish(1, .success(GoalsDirectionHarness.bulk))
        await refresh.value
        XCTAssertEqual(harness.requests, [.bulk, .bulk])
        harness.assertAccepted(GoalsDirectionHarness.bulk, direction: .bulk)
        print("ISSUE-185 equivalent-choices taps=41 requests-before-edit=1 requests-after-edit=2")
    }

    func testReturningToAcceptedDirectionCancelsPendingChoiceWithoutAnotherRead() async {
        let harness = GoalsDirectionHarness()
        await harness.seed(test: self)
        let bulk = await harness.start(.bulk, test: self)
        await harness.model.choose(.maintain)
        XCTAssertNil(harness.model.pendingDirection)
        harness.finish(1, .success(GoalsDirectionHarness.bulk))
        await bulk.value
        harness.assertAccepted(GoalsDirectionHarness.maintain, direction: .maintain)
        XCTAssertEqual(harness.requests, [.maintain, .bulk])
        XCTAssertEqual(harness.cancelledCompletions, [1])
    }

    func testTeardownDiscardsLateSuccessAndErrorAndAllowsNewGeneration() async {
        for result in [Result.success(GoalsDirectionHarness.bulk), .failure(GoalsDirectionHarness.failure)] {
            let harness = GoalsDirectionHarness()
            await harness.seed(test: self)
            let bulk = await harness.start(.bulk, test: self)
            harness.model.cancelDirectionComputation()
            XCTAssertNil(harness.model.pendingDirection)
            harness.finish(1, result)
            await bulk.value
            harness.assertAccepted(GoalsDirectionHarness.maintain, direction: .maintain)
            XCTAssertNil(harness.model.errorMessage)
            XCTAssertEqual(harness.cancelledCompletions, [1])
            let next = await harness.start(.bulk, test: self)
            harness.finish(2, .success(GoalsDirectionHarness.bulk))
            await next.value
            harness.assertAccepted(GoalsDirectionHarness.bulk, direction: .bulk)
            XCTAssertEqual(harness.requests, [.maintain, .bulk, .bulk])
        }
    }

    func testObsoleteCompletionCannotClearNewPendingChoice() async {
        let harness = GoalsDirectionHarness()
        let cut = await harness.start(.cut, test: self)
        let bulk = await harness.start(.bulk, test: self)
        harness.finish(0, .failure(GoalsDirectionHarness.failure))
        await cut.value
        XCTAssertEqual(harness.model.pendingDirection, .bulk)
        XCTAssertNil(harness.model.goal)
        XCTAssertNil(harness.model.errorMessage)
        harness.finish(1, .success(GoalsDirectionHarness.bulk))
        await bulk.value
        harness.assertAccepted(GoalsDirectionHarness.bulk, direction: .bulk)
        XCTAssertNil(harness.model.pendingDirection)
    }

    func testOlderContextRefreshCannotOverwriteChoice() async {
        let harness = GoalsDirectionHarness()
        harness.repository.holdsContext = true
        harness.repository.storedGoal = StoredDashboardGoal(
            calorieTargetKcal: 2100, proteinG: 100, carbsG: 260, fatG: 70, source: .manual
        )
        let load = Task { await harness.model.load() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !harness.repository.parkedOnContext && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(harness.repository.parkedOnContext)
        let bulk = await harness.start(.bulk, test: self)
        harness.finish(0, .success(GoalsDirectionHarness.bulk))
        await bulk.value
        harness.repository.releaseContext()
        await load.value
        harness.assertAccepted(GoalsDirectionHarness.bulk, direction: .bulk)
    }
}

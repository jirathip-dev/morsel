import Combine
import XCTest
@testable import Morsel

/// Uses only entry points present at 2ddba7e, so base RED is behavioural.
@MainActor
final class TodayRefreshRegressionTests: TodayRefreshTestCase {
    func testConcurrentFreshnessJoinsFirstCacheAndOneAuthoritativeRead() async {
        harness.parkCache = true
        harness.cached = harness.value(date: date, marker: 1700)
        var entered = 0
        var returned = 0
        let callers = (0..<4).map { _ in Task {
            entered += 1
            await model.load() // shell / Today / tab / foreground use this entry point
            returned += 1
        } }
        await until("all triggers entered") { entered == 4 && harness.cacheCalls > 0 }
        XCTAssertEqual(harness.cacheCalls, 1)
        XCTAssertTrue(model.isLoading, "ownership begins before the first cache await")
        XCTAssertEqual(returned, 0, "duplicates await shared freshness, rather than returning early")
        harness.releaseCache()
        await until("authoritative read entered") { harness.reads.count == 1 }
        XCTAssertEqual(model.snapshot?.goal?.calorieTargetKcal, 1700)
        XCTAssertTrue(model.isLoading)
        harness.finish(0)
        await until("all freshness callers returned") { returned == 4 }
        XCTAssertEqual(harness.reads.count, 1, "unchanged duplicates must not schedule serial reloads")
        XCTAssertFalse(model.isLoading)
        for caller in callers { caller.cancel() }
        print("ISSUE182 F1 cache=\(harness.cacheCalls) reads=\(harness.reads.count) returned=\(returned)")
    }

    func testConcurrentCommittedMutationsRequireOnlyOneFollowUpAndNeverPublishOldRead() async {
        var publications: [Double] = []
        var admittedReads = 0
        let admission = model.$isLoading.filter { $0 }.sink { _ in admittedReads += 1 }
        let observer = model.$snapshot.compactMap { $0?.goal?.calorieTargetKcal }
            .sink { publications.append($0) }
        let original = Task { await model.load() }
        await until("pre-mutation read entered") { harness.reads.count == 1 }
        var saved = 0
        let updates = [Task { if await model.markReviewed(UUID()) { saved += 1 } },
                       Task { if await model.updateMealItem(MealItemUpdate(itemID: UUID(), caloriesKcal: 300)) {
                           saved += 1
                       } },
                       Task { if await model.deleteMeal(UUID()) { saved += 1 } }]
        await until("three writes committed") { harness.writes == 3 }
        await until("all committed writes reached refresh ownership") { admittedReads == 4 }
        XCTAssertEqual(harness.reads.count, 1, "writes invalidate the read, not start independent reads")
        harness.finish(0, marker: 1000)
        await until("post-mutation read entered") { harness.reads.count >= 2 }
        XCTAssertFalse(publications.contains(1000), "pre-write state must not be published even transiently")
        harness.finish(1, marker: 2400)
        await until("all write callers returned") { saved == 3 }
        // Issue #190 — the writes no longer wait for this read: the post-mutation
        // publish is bounded-waited instead of implied by a write returning.
        await until("the post-mutation read published") {
            model.snapshot?.goal?.calorieTargetKcal == 2400 && !model.isLoading
        }
        XCTAssertEqual(harness.reads.count, 2)
        XCTAssertEqual(model.snapshot?.goal?.calorieTargetKcal, 2400)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isSaving)
        original.cancel()
        for update in updates { update.cancel() }
        withExtendedLifetime(observer) {}
        withExtendedLifetime(admission) {}
        print("ISSUE182 F2 writes=\(harness.writes) reads=\(harness.reads.count) publications=\(publications)")
    }

    func testQueuedMealPaintCannotBeOverwrittenByReadStartedBeforeCommit() async {
        let old = Task { await model.load() }
        await until("old read entered") { harness.reads.count == 1 }
        let record = MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: date,
                                source: .manual, items: [])
        harness.localRecord = record
        let saved = await model.addMeal(draft: MealDraft(mealType: .lunch, eatenAt: date,
                                                       notes: nil, items: []), photo: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.snapshot?.meals.map(\.mealLogID), [record.mealLogID])
        XCTAssertFalse(model.isSaving, "saving closes without waiting for a network read")
        harness.finish(0, marker: 1000)
        await until("one follow-up after local commit") { harness.reads.count == 2 }
        XCTAssertEqual(model.snapshot?.meals.map(\.mealLogID), [record.mealLogID])
        XCTAssertNotEqual(model.snapshot?.goal?.calorieTargetKcal, 1000)
        harness.finish(1)
        await until("follow-up finished") { !model.isLoading }
        XCTAssertEqual(harness.reads.count, 2)
        old.cancel()
    }

    func testCancelledNonCooperativeReadDoesNotGateANewLoadOrPublishLate() async {
        var oldReturned = false
        let old = Task { await model.load(); oldReturned = true }
        await until("old read entered") { harness.reads.count == 1 }
        old.cancel()
        await until("cancelled waiter released without repository cooperation") { oldReturned }
        XCTAssertFalse(model.isLoading)
        let fresh = Task { await model.load() }
        await until("new activation starts without old completion") { harness.reads.count == 2 }
        harness.finish(1, marker: 2500)
        await until("fresh published") { model.snapshot?.goal?.calorieTargetKcal == 2500 }
        harness.finish(0, marker: 1000)
        await until("old repository continuation drained") { harness.pending.isEmpty }
        await Task.yield()
        XCTAssertEqual(model.snapshot?.goal?.calorieTargetKcal, 2500)
        XCTAssertFalse(model.isLoading)
        fresh.cancel()
    }
}

import Combine
import XCTest
@testable import Morsel

// Issue #190 — a confirmed mutation finishes on its OWN acknowledgement; the
// dashboard read is freshness, never the gate. Every witness drives the SHIPPED
// view-model methods against a remote whose day read is parked or failing, so
// the assertions are about ordering and blocking rather than source strings.
// Support types (the scripted remote, fixtures, bounded waits) live in
// WriteAckTestSupport.swift.

final class WriteAckConfirmTests: WriteAckTestCase {
    func testReviewFinishesWithoutWaitingForTheDashboardRead() async {
        let reviewed = meal([item("Rice", confidence: 0.4)])
        await loadedDay([reviewed])
        XCTAssertEqual(model.reviewItems.count, 1)
        let itemID = reviewed.items[0].itemID

        var confirmed: Bool?
        let review = Task { confirmed = await model.markReviewed(itemID) }
        await until("the confirmed review finishes with the day read blocked") { confirmed != nil }

        XCTAssertEqual(confirmed, true)
        XCTAssertEqual(model.reviewItems, [], "the acknowledged item stops needing review")
        XCTAssertEqual(model.snapshot?.meals.first?.items.first?.provenance, .photoVision,
                       "a review never fabricates manual-edit provenance")
        XCTAssertTrue(model.isLoading, "the action returned with the fresh day read still in flight")
        await until("the confirmed review invalidates its day") { harness.readDates.count == 2 }
        harness.answer(1, with: [reviewed])
        await until("the fresh read settles") { !model.isLoading }
        review.cancel()
    }

    func testEditFinishesWithoutWaitingForTheDashboardReadAndTouchesOnlyThatItem() async {
        let edited = meal([item("Rice", caloriesKcal: 220)])
        let untouched = meal([item("Chicken", caloriesKcal: 200)])
        await loadedDay([edited, untouched])
        let itemID = edited.items[0].itemID

        var confirmed: Bool?
        let edit = Task {
            confirmed = await model.updateMealItem(MealItemUpdate(
                itemID: itemID, quantity: 2, caloriesKcal: 440, proteinG: 8, carbsG: 96, fatG: 2
            ))
        }
        await until("the confirmed edit finishes with the day read blocked") { confirmed != nil }

        XCTAssertEqual(confirmed, true)
        XCTAssertEqual(model.totals.caloriesKcal, 640, "the acknowledged row repaints the totals")
        let rows = model.snapshot?.meals ?? []
        XCTAssertEqual(rows.first?.items.first?.quantity, 2)
        XCTAssertEqual(rows.first?.items.first?.caloriesKcal, 440)
        XCTAssertEqual(rows.first?.items.first?.provenance, .manualEdit)
        XCTAssertEqual(rows.first?.items.first?.confidence, 0.4,
                       "the edit writes no confidence: the acknowledged row keeps the server's")
        XCTAssertEqual(rows.last?.items.first?.name, "Chicken", "the sibling item keeps its bytes")
        XCTAssertEqual(rows.last?.items.first?.caloriesKcal, 200)
        XCTAssertFalse(model.isSaving)
        edit.cancel()
    }

    func testPhotoAttachFinishesWithoutWaitingAndKeepsTheQueuedRowPending() async throws {
        let queued = meal([item("Rice", confidence: nil)], syncState: .pending)
        await loadedDay([queued])
        let itemID = queued.items[0].itemID

        var attached: Bool?
        let attach = Task {
            attached = await model.attachPhoto(
                FoodImageUpload(data: Data([0x33]), mimeType: "image/jpeg"), toItem: itemID
            )
        }
        await until("the confirmed attach finishes with the day read blocked") { attached != nil }

        XCTAssertEqual(attached, true)
        let row = try XCTUnwrap(model.snapshot?.meals.first)
        XCTAssertEqual(row.imagePath, FoodImageStore.objectPath(userID: account, imageID: queued.mealLogID),
                       "the acknowledged photo is journal-visible at its canonical path")
        XCTAssertEqual(row.syncState, .pending, "an unsynced row never claims to be synced")
        XCTAssertEqual(row.items.first?.mealImage?.path, row.imagePath)
        attach.cancel()
    }

    func testDeleteFinishesWithoutWaitingForTheDashboardReadAndRemovesOnlyThatMeal() async {
        let deleted = meal([item("Rice")])
        let retained = meal([item("Chicken", caloriesKcal: 200)])
        await loadedDay([deleted, retained])

        var confirmed: Bool?
        let delete = Task { confirmed = await model.deleteMeal(deleted.mealLogID) }
        await until("the confirmed delete finishes with the day read blocked") { confirmed != nil }

        XCTAssertEqual(confirmed, true)
        XCTAssertEqual(model.snapshot?.meals.map(\.mealLogID), [retained.mealLogID])
        XCTAssertEqual(model.totals.caloriesKcal, 200)
        XCTAssertEqual(model.snapshot?.meals.first?.syncState, .synced,
                       "the retained row keeps its own sync state")
        XCTAssertFalse(model.isSaving)
        delete.cancel()
    }

    func testConfirmedWriteSurvivesALaterFailedRefresh() async {
        let deleted = meal([item("Rice")])
        let retained = meal([item("Chicken", caloriesKcal: 200)])
        await loadedDay([deleted, retained])

        var confirmed: Bool?
        let delete = Task { confirmed = await model.deleteMeal(deleted.mealLogID) }
        await until("the confirmed delete finishes with the day read blocked") { confirmed != nil }
        XCTAssertEqual(confirmed, true, "the write is confirmed before any read answers")

        await until("the invalidated read is admitted") { harness.readDates.count == 2 }
        harness.fail(1, MorselError.configurationMissing)
        await until("the failed read settles") { !model.isLoading }

        XCTAssertEqual(model.snapshot?.meals.map(\.mealLogID), [retained.mealLogID],
                       "a later refresh failure cannot report the confirmed write as not saved")
        XCTAssertEqual(model.errorMessage, MorselError.configurationMissing.errorDescription,
                       "the honest error belongs to the read, not to the write")
        XCTAssertFalse(model.isSaving)
        delete.cancel()
    }

    func testRejectedWriteKeepsTheDataAndReportsTheRefusal() async {
        let edited = meal([item("Rice", caloriesKcal: 220)])
        await loadedDay([edited])
        let itemID = edited.items[0].itemID
        harness.refusal = MorselError.invalidData("The meal item could not be updated.")

        let confirmed = await model.updateMealItem(MealItemUpdate(itemID: itemID, caloriesKcal: 440))

        XCTAssertFalse(confirmed)
        XCTAssertEqual(model.errorMessage, "The meal item could not be updated.")
        XCTAssertEqual(model.snapshot?.meals.first?.items.first?.caloriesKcal, 220,
                       "a rejected write leaves the authoritative row in place")
        XCTAssertEqual(model.totals.caloriesKcal, 220)
        XCTAssertEqual(harness.readDates.count, 1, "a rejected write invalidates nothing")
        XCTAssertFalse(model.isSaving)
    }

    func testStalePreMutationResponseCannotUndoTheConfirmedResult() async {
        let deleted = meal([item("Rice")])
        let retained = meal([item("Chicken", caloriesKcal: 200)])
        await loadedDay([deleted, retained])

        // A pass started BEFORE the write: its payload is pre-mutation.
        let stale = Task { await model.load() }
        await until("the pre-mutation pass is in flight") { harness.readDates.count == 2 }

        var published: [[UUID]] = []
        let observer = model.$snapshot.compactMap { $0?.meals.map(\.mealLogID) }
            .sink { published.append($0) }
        var confirmed: Bool?
        let delete = Task { confirmed = await model.deleteMeal(deleted.mealLogID) }
        await until("the confirmed delete finishes with the stale pass parked") { confirmed != nil }
        XCTAssertEqual(confirmed, true)
        let atDelete = published.count
        let cacheReadsAtDelete = harness.cacheReads

        harness.answer(1, with: [deleted, retained])
        await until("the stale pass is superseded by a fresh read") { harness.readDates.count == 3 }

        XCTAssertEqual(model.snapshot?.meals.map(\.mealLogID), [retained.mealLogID],
                       "a pre-mutation response cannot undo the confirmed local result")
        XCTAssertFalse(published.dropFirst(atDelete).contains { $0.contains(deleted.mealLogID) },
                       "the pre-mutation payload is never published, not even transiently")
        XCTAssertEqual(harness.cacheReads, cacheReadsAtDelete,
                       "the invalidated pass hydrates nothing from a pre-mutation cache")

        harness.answer(2, with: [retained])
        await until("the fresh read lands") {
            model.snapshot?.meals.map(\.mealLogID) == [retained.mealLogID] && !model.isLoading
        }
        XCTAssertFalse(model.isShowingCachedDay, "the fresh pass is authoritative, not cached")
        stale.cancel()
        delete.cancel()
        withExtendedLifetime(observer) {}
    }

    func testDoubleTapIssuesOneMutationAndSharesItsOutcome() async {
        let first = meal([item("Rice")])
        let second = meal([item("Chicken", caloriesKcal: 200)])
        await loadedDay([first, second])
        harness.parksWrites = true

        var left: Bool?
        var right: Bool?
        let taps = [Task { left = await model.deleteMeal(first.mealLogID) },
                    Task { right = await model.deleteMeal(first.mealLogID) }]
        await until("the double tap reaches the remote once") { harness.writeLog.count == 1 }
        await until("both taps are waiting on the shared write") { model.isSaving }
        harness.releaseWrites()

        await until("both taps resolve") { left != nil && right != nil }
        XCTAssertEqual([left, right], [true, true], "a repeated tap shares the confirmed outcome")
        XCTAssertEqual(harness.writeLog, ["delete:\(first.mealLogID)"],
                       "a repeated tap issues no second mutation")
        XCTAssertEqual(model.snapshot?.meals.map(\.mealLogID), [second.mealLogID])
        for tap in taps { tap.cancel() }
    }

    func testDoubleTapOnEditIssuesOneMutationAndKeepsTheSecondOutcomeHonest() async {
        let edited = meal([item("Rice", caloriesKcal: 220)])
        await loadedDay([edited])
        let itemID = edited.items[0].itemID
        harness.parksWrites = true

        var left: Bool?
        var right: Bool?
        let taps = [Task { left = await model.updateMealItem(MealItemUpdate(itemID: itemID, caloriesKcal: 440)) },
                    Task { right = await model.updateMealItem(MealItemUpdate(itemID: itemID, caloriesKcal: 440)) }]
        await until("the double tap reaches the remote once") { harness.writeLog.count == 1 }
        harness.releaseWrites()

        await until("both taps resolve") { left != nil && right != nil }
        XCTAssertEqual([left, right], [true, true])
        XCTAssertEqual(harness.writeLog.count, 1, "one acknowledged edit, not a duplicate mutation")
        XCTAssertEqual(model.snapshot?.meals.first?.items.first?.caloriesKcal, 440)
        XCTAssertEqual(model.totals.caloriesKcal, 440)
        for tap in taps { tap.cancel() }
    }

    func testALaterTapAfterTheWriteCompletesIssuesAFreshMutation() async {
        let deleted = meal([item("Rice")])
        await loadedDay([deleted])

        var first: Bool?
        let firstTap = Task { first = await model.deleteMeal(deleted.mealLogID) }
        await until("the first tap is acknowledged") { first != nil }
        XCTAssertEqual(first, true)
        harness.refusal = MorselError.invalidData("The meal could not be deleted.")

        var again: Bool?
        let laterTap = Task { again = await model.deleteMeal(deleted.mealLogID) }
        await until("the later tap reports its own refusal") { again != nil }
        XCTAssertEqual(again, false, "a later tap is a new write and reports its own refusal honestly")
        XCTAssertEqual(harness.writeLog.count, 2, "retry after completion is preserved")
        XCTAssertEqual(model.errorMessage, "The meal could not be deleted.")
        firstTap.cancel()
        laterTap.cancel()
    }
}

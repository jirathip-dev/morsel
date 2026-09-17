import XCTest
@testable import Morsel

// Issue #190 AC5 — every named meal action (review / edit / photo replacement /
// delete) against the same three scenarios: a refused write, a held double tap
// and a confirmed write whose invalidated read then fails. The per-action local
// results are asserted in WriteAckRegressionTests; this matrix is the "all named
// action methods" coverage sweep.

final class WriteAckActionMatrixTests: WriteAckTestCase {
    private enum Action: String, CaseIterable {
        case review, edit, photo, delete

        var key: String {
            switch self {
            case .review: "review"
            case .edit: "edit"
            case .photo: "photo"
            case .delete: "delete"
            }
        }

        var refusal: String {
            switch self {
            case .review: "The meal item could not be reviewed."
            case .edit: "The meal item could not be updated."
            case .photo: "The meal photo could not be attached."
            case .delete: "The meal could not be deleted."
            }
        }
    }

    private struct Day {
        let model: DashboardViewModel
        let itemID: UUID
        let mealLogID: UUID
    }

    /// A fresh day (two meals) for one action, so the matrix cases never share state.
    private func newDay() async -> Day {
        let model = restart()
        let edited = meal([item("Rice", caloriesKcal: 220)])
        let sibling = meal([item("Chicken", caloriesKcal: 200)])
        await loadedDay([edited, sibling])
        return Day(model: model, itemID: edited.items[0].itemID, mealLogID: edited.mealLogID)
    }

    private func run(_ action: Action, on day: Day) async -> Bool {
        switch action {
        case .review:
            return await day.model.markReviewed(day.itemID)
        case .edit:
            return await day.model.updateMealItem(MealItemUpdate(itemID: day.itemID, caloriesKcal: 440))
        case .photo:
            return await day.model.attachPhoto(
                FoodImageUpload(data: Data([0x33]), mimeType: "image/jpeg"), toItem: day.itemID
            )
        case .delete:
            return await day.model.deleteMeal(day.mealLogID)
        }
    }

    func testEveryNamedActionFinishesWithTheRefreshBlocked() async {
        for action in Action.allCases {
            let day = await newDay()
            var confirmed: Bool?
            let write = Task { confirmed = await run(action, on: day) }
            await until("\(action.key): the confirmed action finishes with the read parked") {
                confirmed != nil
            }
            XCTAssertEqual(confirmed, true, "\(action.key) completes on its own acknowledgement")
            XCTAssertTrue(day.model.isLoading, "\(action.key): the invalidated read is admitted, never awaited")
            await until("\(action.key): the invalidated read is admitted") { harness.readDates.count == 2 }
            write.cancel()
        }
    }

    func testRefusedWriteKeepsTheDayAndReportsItsOwnCopyForEveryNamedAction() async {
        for action in Action.allCases {
            let day = await newDay()
            harness.refusal = MorselError.invalidData(action.refusal)

            let confirmed = await run(action, on: day)

            XCTAssertFalse(confirmed, "\(action.key): a refusal is not a confirmation")
            XCTAssertEqual(day.model.errorMessage, action.refusal, "\(action.key): honest refusal copy")
            XCTAssertEqual(harness.writeLog.count, 1, "\(action.key): exactly one refused write was attempted")
            XCTAssertTrue(harness.writeLog.first?.hasPrefix(action.key) == true,
                          "\(action.key): the refused write belongs to this action")
            XCTAssertEqual(day.model.snapshot?.meals.count, 2, "\(action.key): the day keeps its rows")
            XCTAssertEqual(day.model.totals.caloriesKcal, 420, "\(action.key): the totals are unchanged")
            XCTAssertEqual(harness.readDates.count, 1, "\(action.key): a refused write invalidates nothing")
            XCTAssertFalse(day.model.isSaving, "\(action.key): the saving state is released")
        }
    }

    func testHeldDoubleTapIssuesOneWriteForEveryNamedAction() async {
        for action in Action.allCases {
            let day = await newDay()
            harness.parksWrites = true

            var left: Bool?
            var right: Bool?
            let taps = [Task { left = await run(action, on: day) }, Task { right = await run(action, on: day) }]
            await until("\(action.key): the double tap reaches the remote") { harness.writeLog.count >= 1 }
            harness.releaseWrites()
            await until("\(action.key): both taps resolve") { left != nil && right != nil }

            XCTAssertEqual(harness.writeLog.count, 1, "\(action.key): one mutation for a double tap")
            XCTAssertTrue(harness.writeLog.first?.hasPrefix(action.key) == true,
                          "\(action.key): the single write belongs to this action")
            XCTAssertTrue([left, right].allSatisfy { $0 == true },
                          "\(action.key): a repeated tap shares the confirmed outcome")
            for tap in taps { tap.cancel() }
        }
    }

    func testFailedRefreshNeverUnreportsAConfirmedWriteForEveryNamedAction() async {
        for action in Action.allCases {
            let day = await newDay()
            var confirmed: Bool?
            let write = Task { confirmed = await run(action, on: day) }
            await until("\(action.key): the confirmed write finishes with the read parked") { confirmed != nil }
            XCTAssertEqual(confirmed, true)
            await until("\(action.key): the invalidated read is admitted") { harness.readDates.count == 2 }
            harness.fail(1, MorselError.configurationMissing)
            await until("\(action.key): the failed read settles") { !day.model.isLoading }

            XCTAssertEqual(day.model.errorMessage, MorselError.configurationMissing.errorDescription,
                           "\(action.key): the honest error belongs to the read")
            XCTAssertNotEqual(day.model.errorMessage, action.refusal,
                              "\(action.key): a failed refresh never reports the confirmed write as refused")
            XCTAssertFalse(day.model.isSaving)
            write.cancel()
        }
    }
}

import Foundation
import XCTest
@testable import Morsel

// Issue #191 — AC4 (retry/status/merge retention and complete uploads) and AC5
// (the UI-facing lookup stays keyed while a background pass is in flight).
// The harness and the byte counter live in TargetedOutboxReadHarness.swift.

@MainActor
final class TargetedOutboxDeliveryTests: TargetedReadCase {
    func testRetryAndStatusUpdatesRetainEveryFieldAndTruthfulStates() async throws {
        let queue = try makeQueue()
        let target = queue.fixtures[0]
        let path = queue.canonicalPath(target.mealID)
        try queue.store.updateMealImagePath(
            mealID: target.mealID, path: path, now: Date(timeIntervalSince1970: 2_000)
        )

        try queue.store.recordMealAttempt(
            mealID: target.mealID, error: .network, now: Date(timeIntervalSince1970: 3_000)
        )
        let transient = try XCTUnwrap(try queue.store.queuedMeal(mealID: target.mealID))
        XCTAssertEqual(transient.state, .pending, "a transient failure stays retryable")
        XCTAssertEqual(transient.attempts, 1)
        XCTAssertEqual(transient.lastErrorCategory, .network)
        XCTAssertEqual(transient.imagePath, path, "a retry keeps the uploaded path")
        XCTAssertEqual(transient.photo?.data, target.payload)
        XCTAssertEqual(transient.items.first?.name, "oats")
        XCTAssertEqual(transient.notes, "queue-0")

        try queue.store.recordMealAttempt(
            mealID: target.mealID, error: .validation, permanent: true, now: Date(timeIntervalSince1970: 4_000)
        )
        let refused = try XCTUnwrap(try queue.store.queuedMeal(mealID: target.mealID))
        XCTAssertEqual(refused.state, .needsAttention, "a permanent refusal is visible, never green-pending")
        XCTAssertEqual(refused.attempts, 2)
        XCTAssertEqual(refused.lastError, OutboxErrorCategory.validation.friendlyDescription)
        XCTAssertEqual(refused.photo?.data, target.payload, "the recoverable payload survives the refusal")
        XCTAssertEqual(refused.imagePath, path)

        try queue.store.retryMeal(mealID: target.mealID, now: Date(timeIntervalSince1970: 5_000))
        let retried = try XCTUnwrap(try queue.store.queuedMeal(mealID: target.mealID))
        XCTAssertEqual(retried.state, .pending, "a user retry returns the row to retryable pending")
        XCTAssertNil(retried.lastError)
        XCTAssertNil(retried.lastErrorCategory)
        XCTAssertEqual(retried.attempts, 2)
        XCTAssertEqual(retried.photo?.data, target.payload)
    }

    func testJournalMergeRetainsSnapshotAndQueuedRowFields() async throws {
        let queue = try makeQueue()
        try queue.store.recordMealAttempt(
            mealID: queue.fixtures[1].mealID, error: .validation, permanent: true
        )
        let day = Date(timeIntervalSince1970: 1_000)
        let remoteMeal = MealRecord(
            mealLogID: UUID(), mealType: .breakfast, eatenAt: Date(timeIntervalSince1970: 900),
            source: .manual, items: [], syncState: .synced
        )
        let goal = DashboardGoal(calorieTargetKcal: 2_000, proteinG: 100, carbsG: 250, fatG: 55, source: .manual)
        let snapshot = DashboardSnapshot(
            date: day, meals: [remoteMeal], goal: goal,
            readProvenance: DayReadProvenance(isCached: false, loadedAt: day)
        )

        var merged = DashboardSnapshot(date: day, meals: [], goal: nil)
        try await assertZeroPhotoBytes("the journal day merge", store: queue.store) {
            merged = try queue.repository.merged(snapshot, userID: self.account, date: day)
        }

        XCTAssertEqual(merged.date, day)
        XCTAssertEqual(merged.goal, goal, "the day's goal rides through the merge unchanged")
        XCTAssertEqual(merged.readProvenance, snapshot.readProvenance)
        XCTAssertEqual(merged.meals.count, 1 + queue.fixtures.count)
        XCTAssertEqual(merged.meals.first, remoteMeal)
        for fixture in queue.fixtures {
            let row = try XCTUnwrap(merged.meals.first { $0.mealLogID == fixture.mealID })
            XCTAssertEqual(row.imagePath, queue.canonicalPath(fixture.mealID), "the path is known before upload")
            XCTAssertEqual(row.items.first?.name, "oats")
            XCTAssertEqual(row.items.first?.mealImage?.path, queue.canonicalPath(fixture.mealID))
        }
        XCTAssertEqual(
            merged.meals.first { $0.mealLogID == queue.fixtures[1].mealID }?.syncState, .needsAttention,
            "a refused row keeps its visible state through the merge"
        )
        XCTAssertEqual(
            merged.meals.first { $0.mealLogID == queue.fixtures[0].mealID }?.syncState, .pending,
            "a pending row keeps its honest state through the merge"
        )
    }

    func testUploadCarriesTheCompleteDurablePayloadAndOnlyItsOwnBytes() async throws {
        let queue = try makeQueue()
        for fixture in queue.fixtures.dropFirst() {
            try queue.store.recordMealAttempt(mealID: fixture.mealID, error: .validation, permanent: true)
        }
        let outgoing = TargetedReadUploadSpy()
        let engine = LocalSyncEngine(userID: account, store: queue.store, mealRemote: outgoing)

        let before = queue.store.blobBytes(column: "photo_data")
        await engine.runPass()
        let materialized = queue.store.blobBytes(column: "photo_data") - before

        let delivered = queue.fixtures[0]
        let upload = try XCTUnwrap(outgoing.uploads[delivered.mealID])
        XCTAssertEqual(upload.data, delivered.payload, "the upload carries the complete durable payload")
        XCTAssertEqual(upload.mimeType, "image/jpeg")
        XCTAssertEqual(
            materialized, delivered.payload.count,
            "the pass reads its own row's payload; refused rows cost no photo bytes"
        )
        XCTAssertEqual(outgoing.commits, [delivered.mealID])
        XCTAssertNil(try queue.store.queuedMeal(mealID: delivered.mealID), "a committed row is released")
        XCTAssertEqual(try queue.store.queuedMeals().count, queue.fixtures.count - 1)
    }

    func testUIFacingLookupStaysKeyedWhileABackgroundPassIsInFlight() async throws {
        let queue = try makeQueue()
        for fixture in queue.fixtures {
            try queue.store.recordMealAttempt(mealID: fixture.mealID, error: .validation, permanent: true)
        }
        // A row the pass CAN drain: no photo, parked mid-commit so the pass is
        // genuinely in flight while the main-actor lookups below run.
        let inFlight = QueuedMealFactory.make(
            draft: TargetedReadQueue.draft(notes: "in flight"), photo: nil, mealID: UUID(),
            now: Date(timeIntervalSince1970: 2_000)
        )
        try queue.store.enqueueMeal(inFlight)
        let latch = ThumbnailLatch()
        let outgoing = TargetedReadUploadSpy()
        outgoing.parkedCommit = latch
        let userID = account
        let store = queue.store
        let pass = Task.detached {
            await LocalSyncEngine(userID: userID, store: store, mealRemote: outgoing).runPass()
        }
        await latch.waitUntilWaiting()

        let target = queue.fixtures[2]
        let beforeRevision = store.blobBytes(column: "photo_data")
        let revision = await queue.repository.mealPhotoRevision(
            userID: userID, path: queue.canonicalPath(target.mealID)
        )
        let revisionBytes = store.blobBytes(column: "photo_data") - beforeRevision
        let beforeFetch = store.blobBytes(column: "photo_data")
        let served = try await queue.repository.loadMealImage(
            userID: userID, path: queue.canonicalPath(target.mealID)
        )
        let fetchBytes = store.blobBytes(column: "photo_data") - beforeFetch

        XCTAssertEqual(revision, .queued(fingerprint: MealThumbnailFingerprint.of(target.payload)))
        XCTAssertEqual(served, target.payload)
        XCTAssertEqual(revisionBytes, target.payload.count, "naming the revision reads only that photo")
        XCTAssertEqual(fetchBytes, target.payload.count, "the lookup reads only that photo")
        print(
            "ISSUE-191-TRACE seam=main_actor_lookup selected_bytes=\(target.payload.count)"
                + " revision_bytes=\(revisionBytes) fetch_bytes=\(fetchBytes) queued_photo_rows=\(queue.fixtures.count)"
        )

        let beforeDrain = store.blobBytes(column: "photo_data")
        await latch.open()
        await pass.value
        XCTAssertEqual(
            store.blobBytes(column: "photo_data") - beforeDrain, 0,
            "draining the pass materializes no queued payload behind the main-actor lookup"
        )
        XCTAssertNil(try store.queuedMeal(mealID: inFlight.mealID), "the drained row is released")
        XCTAssertEqual(try store.queuedMeals().count, queue.fixtures.count, "refused rows stay queued")
    }
}

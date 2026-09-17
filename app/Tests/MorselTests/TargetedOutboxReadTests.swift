import Foundation
import XCTest
@testable import Morsel

// Issue #191 — targeted outbox/photo reads, held to a byte budget on a real
// account SQLite file.
//
// Every claim here is counted on real rows with several LARGE queued photos
// (`LocalDataStore.blobBytes(column:)`), never estimated:
//
//  * one queued thumbnail read costs exactly the SELECTED photo's bytes;
//  * metadata / status / existence reads cost zero photo bytes;
//  * no-photo, unknown and foreign-account paths refuse safely;
//  * retry/status writes and journal merges keep every field and a truthful state;
//  * an upload still carries the complete durable payload;
//  * the UI-facing lookup stays keyed while a background pass is in flight.
//
// Repro-first: this file is the RED witness on top of the byte instrumentation
// alone — at that tree `queuedPhoto` scans every queued row, `merged` reads the
// whole queue and the status paths materialize rows, so the budgets below fail.
// The read-path commit makes them pass with byte-identical test bytes.

// MARK: - AC1/AC2/AC3: what the read paths cost

@MainActor
final class TargetedOutboxReadTests: TargetedReadCase {
    func testOneQueuedThumbnailReadMaterializesOnlyTheSelectedPhotoBytes() async throws {
        let queue = try makeQueue()
        let totalQueued = queue.totalQueuedPhotoBytes

        for fixture in queue.fixtures {
            let before = queue.store.blobBytes(column: "photo_data")
            let served = try await queue.repository.loadMealImage(
                userID: account, path: queue.canonicalPath(fixture.mealID)
            )
            let materialized = queue.store.blobBytes(column: "photo_data") - before
            XCTAssertEqual(served, fixture.payload, "the requested photo's own bytes are served")
            XCTAssertEqual(
                materialized, fixture.payload.count,
                "one read costs the selected photo (\(fixture.payload.count) B), not the \(totalQueued) B queued"
            )
        }
    }

    func testRevisionLookupNamesTheQueuedPayloadWithoutReadingTheQueue() async throws {
        let queue = try makeQueue()
        let target = queue.fixtures[1]

        let before = queue.store.blobBytes(column: "photo_data")
        let revision = await queue.repository.mealPhotoRevision(
            userID: account, path: queue.canonicalPath(target.mealID)
        )
        let materialized = queue.store.blobBytes(column: "photo_data") - before

        XCTAssertEqual(revision, .queued(fingerprint: MealThumbnailFingerprint.of(target.payload)))
        XCTAssertEqual(materialized, target.payload.count)
    }

    /// The counter's positive control, so the budgets above cannot be vacuous.
    func testFullQueueEnumerationStillMaterializesEveryQueuedPhoto() throws {
        let queue = try makeQueue()
        let before = queue.store.blobBytes(column: "photo_data")

        let rows = try queue.store.queuedMeals()

        XCTAssertEqual(rows.count, queue.fixtures.count)
        XCTAssertEqual(
            queue.store.blobBytes(column: "photo_data") - before, queue.totalQueuedPhotoBytes,
            "the #106 full-queue read is the control that proves the counter sees every payload"
        )
    }

    func testMetadataStatusAndExistenceReadsMaterializeZeroPhotoBytes() async throws {
        let queue = try makeQueue()
        let target = queue.fixtures[0]
        let itemID = try XCTUnwrap(try queue.store.queuedMeal(mealID: target.mealID)?.items.first?.itemID)
        let day = Date(timeIntervalSince1970: 1_000)
        let snapshot = DashboardSnapshot(date: day, meals: [], goal: nil)

        try await assertZeroPhotoBytes("the journal day merge", store: queue.store) {
            _ = try queue.repository.merged(snapshot, userID: self.account, date: day)
        }
        try await assertZeroPhotoBytes("a requested local meal record", store: queue.store) {
            _ = try await queue.repository.localMealRecord(userID: self.account, localMealID: target.mealID)
        }
        try await assertZeroPhotoBytes("an item existence check", store: queue.store) {
            try await queue.repository.confirmMealItem(userID: self.account, itemID: itemID)
        }
        try await assertZeroPhotoBytes("an item edit's local draft read", store: queue.store) {
            try await queue.repository.updateMealItem(
                userID: self.account, update: MealItemUpdate(itemID: itemID, name: "renamed")
            )
        }
        try await assertZeroPhotoBytes("a status write", store: queue.store) {
            try queue.store.recordMealAttempt(mealID: target.mealID, error: .network)
        }
        try await assertZeroPhotoBytes("a queued-meal existence check", store: queue.store) {
            try await queue.repository.deleteMealLog(userID: self.account, mealLogID: queue.fixtures[2].mealID)
        }

        // The metadata reads still saw the truth: the row is durable and edited.
        let row = try XCTUnwrap(try queue.store.queuedMeal(mealID: target.mealID))
        XCTAssertEqual(row.photo?.data, target.payload, "the metadata reads never touched the payload")
        XCTAssertEqual(row.items.first?.name, "renamed")
        XCTAssertEqual(try queue.store.queuedMeals().count, queue.fixtures.count - 1)
    }

    func testNoPhotoAndUnknownPathsRefuseSafelyWithoutLocalBytes() async throws {
        let queue = try makeQueue()
        let plain = QueuedMealFactory.make(
            draft: TargetedReadQueue.draft(notes: "no photo"), photo: nil, mealID: UUID(),
            now: Date(timeIntervalSince1970: 2_000)
        )
        try queue.store.enqueueMeal(plain)

        // A queued meal with NO photo never fakes local bytes: the remote answers.
        let plainPath = queue.canonicalPath(plain.mealID)
        queue.remote.seed(path: plainPath, data: Data([0x01, 0x02, 0x03]))
        try await assertZeroPhotoBytes("a no-photo queued row's read", store: queue.store) {
            let served = try await queue.repository.loadMealImage(userID: self.account, path: plainPath)
            XCTAssertEqual(served, Data([0x01, 0x02, 0x03]))
        }

        // An unknown canonical path answers nothing locally either.
        let unknownPath = queue.canonicalPath(UUID())
        queue.remote.seed(path: unknownPath, data: Data([0x0A, 0x0B]))
        try await assertZeroPhotoBytes("an unknown meal's read", store: queue.store) {
            let served = try await queue.repository.loadMealImage(userID: self.account, path: unknownPath)
            XCTAssertEqual(served, Data([0x0A, 0x0B]))
        }
        XCTAssertEqual(queue.remote.mealImageLoads, 2, "both reads went to the remote object")
    }

    func testForeignAndNonCanonicalPathsRefuseWhileCanonicalAndLegacyFormsServe() async throws {
        let queue = try makeQueue()
        let target = queue.fixtures[2]

        // A foreign account's path refuses before any local match — the same
        // `FoodImageError.invalidPath` the #135 validation has always raised.
        let foreignPath = FoodImageStore.objectPath(userID: foreignAccount, imageID: target.mealID)
        await assertZeroPhotoBytes("a foreign account path's read", store: queue.store) {
            do {
                _ = try await queue.repository.loadMealImage(userID: self.account, path: foreignPath)
                XCTFail("a foreign account's path must refuse")
            } catch {
                XCTAssertEqual(error as? FoodImageError, .invalidPath)
            }
        }

        // The canonical-form match is unchanged: a path that is textually NOT
        // the canonical object path never matches the outbox (the pre-#191 scan
        // compared the canonical text too), so the read falls through.
        let nonCanonical = queue.canonicalPath(target.mealID).lowercased()
        queue.remote.seed(path: nonCanonical, data: Data([0x0C]))
        try await assertZeroPhotoBytes("a non-canonical path's read", store: queue.store) {
            let served = try await queue.repository.loadMealImage(userID: self.account, path: nonCanonical)
            XCTAssertEqual(served, Data([0x0C]))
        }

        // BOTH accepted forms of a queued photo's path serve that row's own
        // bytes, and each costs that photo alone.
        for path in [queue.canonicalPath(target.mealID),
                     FoodImageStore.bucketPath(userID: account, imageID: target.mealID)] {
            let before = queue.store.blobBytes(column: "photo_data")
            let served = try await queue.repository.loadMealImage(userID: self.account, path: path)
            XCTAssertEqual(served, target.payload, "the queued bytes are served for \(path)")
            XCTAssertEqual(queue.store.blobBytes(column: "photo_data") - before, target.payload.count)
        }
    }
}

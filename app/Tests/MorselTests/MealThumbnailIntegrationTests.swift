import Foundation
import UIKit
import XCTest
@testable import Morsel

// Issue #188 — the local-first seam end to end, on a real account store: the
// revision the repository reports for a queued photo, the queued→remote
// transition when the outbox drains, and the same-path replacement a photo
// attach performs. Every claim is counted; nothing here waits on a clock.

@MainActor
final class MealThumbnailIntegrationTests: XCTestCase {
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-thumbnail-188-\(UUID().uuidString)", isDirectory: true)
    private let red = UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
    private let blue = UIColor(red: 0.1, green: 0.1, blue: 0.85, alpha: 1)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func draft() -> MealDraft {
        MealDraft(
            mealType: .lunch,
            eatenAt: Date(timeIntervalSince1970: 60),
            notes: nil,
            items: [MealItemDraft(name: "toast", quantity: 1, unit: .serving)]
        )
    }

    private func photo(_ color: UIColor) throws -> FoodImageUpload {
        FoodImageUpload(
            data: try MealThumbnailFixture.solidJPEG(width: 2_400, height: 1_200, color: color),
            mimeType: "image/jpeg"
        )
    }

    private func makeRepository(
        remote: MealThumbnailRemote,
        revisions: MealPhotoRevisions
    ) throws -> (LocalFirstDashboardRepository, LocalDataStore) {
        let url = LocalDataStore.storeURL(root: directory, accountID: account)
        let store = try LocalDataStore(databaseURL: url)
        let snapshotCache = try LocalSnapshotCache(databaseURL: url)
        let repository = LocalFirstDashboardRepository(
            remote: remote, store: store, snapshotCache: snapshotCache, revisions: revisions
        )
        return (repository, store)
    }

    private func thumbnailRequest(path: String) -> MealThumbnailRequest {
        MealThumbnailRequest(
            accountID: account,
            objectPath: path,
            displayBox: MealThumbnailMetrics.photoFigureBox,
            displayScale: 3
        )
    }

    func testQueuedPhotoRevisionNamesItsOwnBytesAndFlipsWhenTheOutboxDrains() async throws {
        let remote = MealThumbnailRemote()
        let revisions = MealPhotoRevisions()
        let (repository, store) = try makeRepository(remote: remote, revisions: revisions)
        let upload = try photo(red)
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: upload)
        let path = FoodImageStore.objectPath(userID: account, imageID: mealID)
        let cache = MealThumbnailCache()
        let source = MealPhotoSource(repository: repository)

        let queuedRevision = await repository.mealPhotoRevision(userID: account, path: path)
        XCTAssertEqual(queuedRevision, .queued(fingerprint: MealThumbnailFingerprint.of(upload.data)))
        let queued = try await cache.thumbnail(thumbnailRequest(path: path), from: source)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: queued).isDominantlyRed)
        XCTAssertEqual(remote.mealImageLoads, 0, "a queued photo never reaches the remote object")
        XCTAssertEqual(cache.snapshotCounters().fetches, 1)

        // The meal syncs: the outbox row leaves, the remote object holds the
        // same payload — a new revision of the same bytes.
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: MealThumbnailWriter(remote: remote))
        await engine.runPass()
        XCTAssertNil(try store.queuedMeal(mealID: mealID), "a successful sync drains the outbox row")

        let syncedRevision = await repository.mealPhotoRevision(userID: account, path: path)
        XCTAssertEqual(syncedRevision, .remote(epoch: 0))
        XCTAssertNotEqual(syncedRevision.token, queuedRevision.token)

        let synced = try await cache.thumbnail(thumbnailRequest(path: path), from: source)
        XCTAssertTrue(synced === queued, "identical bytes under the new revision are re-filed, not decoded twice")
        XCTAssertEqual(cache.snapshotCounters().fetches, 2, "the transition costs exactly one refetch")
        XCTAssertEqual(cache.snapshotCounters().preparations, 1)
        XCTAssertEqual(remote.mealImageLoads, 1, "the synced read came from the remote object")
        print(
            "ISSUE-188-TRACE seam=queued_to_remote fetches=\(cache.snapshotCounters().fetches)"
                + " preparations=\(cache.snapshotCounters().preparations) remote_loads=\(remote.mealImageLoads)"
        )
    }

    func testQueuedPhotoReplacementThroughTheAttachSeamInvalidatesThePreparedThumbnail() async throws {
        let remote = MealThumbnailRemote()
        let (repository, store) = try makeRepository(remote: remote, revisions: MealPhotoRevisions())
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: try photo(red))
        let path = FoodImageStore.objectPath(userID: account, imageID: mealID)
        let cache = MealThumbnailCache()
        let source = MealPhotoSource(repository: repository)

        let before = try await cache.thumbnail(thumbnailRequest(path: path), from: source)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: before).isDominantlyRed)

        // The shipped replace path: the SAME object path, new bytes.
        let itemID = try XCTUnwrap(try store.queuedMeal(mealID: mealID)?.items.first?.itemID)
        try await repository.attachMealPhoto(userID: account, itemID: itemID, photo: try photo(blue))

        let after = try await cache.thumbnail(thumbnailRequest(path: path), from: source)
        XCTAssertTrue(
            ThumbnailPixelProbe.averageColor(of: after).isDominantlyBlue,
            "the surface is served the replacement, never the stale prepared surrogate"
        )
        XCTAssertEqual(cache.snapshotCounters().fetches, 2)
        XCTAssertEqual(cache.snapshotCounters().preparations, 2)
        print(
            "ISSUE-188-TRACE seam=queued_replace fetches=\(cache.snapshotCounters().fetches)"
                + " preparations=\(cache.snapshotCounters().preparations) served=blue"
        )
    }

    func testSyncedAttachBumpsTheAccountRevisionSoNoStaleSurrogateSurvives() async throws {
        let remote = MealThumbnailRemote()
        let revisions = MealPhotoRevisions()
        let (repository, _) = try makeRepository(remote: remote, revisions: revisions)
        let path = FoodImageStore.objectPath(userID: account, imageID: UUID())
        remote.seed(path: path, data: try photo(red).data)

        let cache = MealThumbnailCache()
        let source = MealPhotoSource(repository: repository)
        let warmed = try await cache.thumbnail(thumbnailRequest(path: path), from: source)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: warmed).isDominantlyRed)
        XCTAssertEqual(revisions.epoch(accountID: account, objectPath: path), 0)

        // A SYNCED meal (no outbox row) is replaced through the authenticated
        // attach seam: the canonical path is derived server-side, so the app can
        // only name the account.
        try await repository.attachMealPhoto(
            userID: account, itemID: UUID(), photo: try photo(blue)
        )
        XCTAssertEqual(remote.attachments.count, 1, "a synced item routes to the remote attach seam")
        XCTAssertEqual(revisions.epoch(accountID: account, objectPath: path), 1)

        // The server now serves the replaced bytes; the next read refetches.
        remote.seed(path: path, data: try photo(blue).data)
        let refreshed = try await cache.thumbnail(thumbnailRequest(path: path), from: source)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: refreshed).isDominantlyBlue)
        XCTAssertEqual(cache.snapshotCounters().fetches, 2, "the account bump costs one refetch per object")
    }

    func testFullSizeReadsStayUntouchedByTheThumbnailCache() async throws {
        let remote = MealThumbnailRemote()
        let (repository, _) = try makeRepository(remote: remote, revisions: MealPhotoRevisions())
        let payload = try photo(red).data
        let path = FoodImageStore.objectPath(userID: account, imageID: UUID())
        remote.seed(path: path, data: payload)

        // The full-size viewer seam keeps returning the object's own bytes —
        // the cache never substitutes a downsampled surrogate for it.
        let bytes = try await repository.loadMealImage(userID: account, path: path)
        XCTAssertEqual(bytes, payload)
        XCTAssertEqual(remote.mealImageLoads, 1)
        let fullSize = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertEqual(MealThumbnailPixels.size(of: fullSize), CGSize(width: 2_400, height: 1_200))
    }
}

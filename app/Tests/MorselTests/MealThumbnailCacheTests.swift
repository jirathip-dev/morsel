import UIKit
import XCTest
@testable import Morsel

// Issue #188 — the prepared-thumbnail cache's counted behaviour: cold and warm
// reads, coalescing, display-scale targets, same-path replacement and the
// queued→remote transition.
//
// Every claim is a COUNT (fetches, decodes, coalesced joins, hits, resident
// bytes) or a PIXEL — never a duration. Fixtures are generated synthetic JPEGs;
// no user photo, health value, token or signed URL appears anywhere.

class MealThumbnailTestCase: XCTestCase {
    let account = UUID()
    let otherAccount = UUID()
    let objectPath = "5B1F0C2A-1111-4000-8000-000000000001/5B1F0C2A-1111-4000-8000-000000000002.jpg"
    let red = UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
    let blue = UIColor(red: 0.1, green: 0.1, blue: 0.85, alpha: 1)

    /// A 2:1 phone-sized photo: at the shipped `.photo` figure box it paints
    /// exactly 870×435 pixels at 3x and 580×290 at 2x.
    func panorama(_ color: UIColor) throws -> Data {
        try MealThumbnailFixture.solidJPEG(width: 2_400, height: 1_200, color: color)
    }

    func request(account: UUID? = nil, path: String? = nil, scale: CGFloat = 3) -> MealThumbnailRequest {
        MealThumbnailRequest(
            accountID: account ?? self.account,
            objectPath: path ?? objectPath,
            displayBox: MealThumbnailMetrics.photoFigureBox,
            displayScale: scale
        )
    }

    func objectPath(index: Int) -> String {
        "5B1F0C2A-1111-4000-8000-00000000000\(index)\(index).jpg"
    }
}

final class MealThumbnailCacheTests: MealThumbnailTestCase {
    func testColdReadFetchesAndPreparesThenWarmRevisitReusesTheSameImage() async throws {
        let cache = MealThumbnailCache()
        let stub = ThumbnailStubSource(
            bytes: ThumbnailBox(try panorama(red)),
            revision: ThumbnailBox(.remote(epoch: 0)),
            fetches: ThumbnailBox(0)
        )

        let cold = try await cache.thumbnail(request(), from: stub.source)
        let coldCounters = cache.snapshotCounters()

        let warm = try await cache.thumbnail(request(), from: stub.source)
        let warmCounters = cache.snapshotCounters()

        XCTAssertEqual(coldCounters.fetches, 1, "the cold read fetches the object bytes exactly once")
        XCTAssertEqual(coldCounters.preparations, 1, "the cold read decodes exactly once")
        XCTAssertEqual(coldCounters.hits, 0)
        XCTAssertEqual(MealThumbnailPixels.size(of: cold), CGSize(width: 870, height: 435))
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: cold).isDominantlyRed)
        XCTAssertEqual(warmCounters.fetches, 1, "a warm revisit must not fetch")
        XCTAssertEqual(warmCounters.preparations, 1, "a warm revisit must not decode")
        XCTAssertEqual(warmCounters.hits, 1)
        XCTAssertTrue(warm === cold, "the warm revisit is served the prepared image itself")
        XCTAssertEqual(cache.residentEntryCount(), 1)
        XCTAssertEqual(
            cache.residentPixelBytes(), 870 * 435 * 4,
            "only the prepared pixels are resident — no original bytes accumulate"
        )
        print(
            "ISSUE-188-COUNTS phase=cold fetches=\(coldCounters.fetches) preparations=\(coldCounters.preparations)"
                + " hits=\(coldCounters.hits) resident=\(cache.residentEntryCount())"
                + " resident_pixel_bytes=\(cache.residentPixelBytes())"
        )
        print(
            "ISSUE-188-COUNTS phase=warm fetches=\(warmCounters.fetches) preparations=\(warmCounters.preparations)"
                + " hits=\(warmCounters.hits) resident=\(cache.residentEntryCount())"
                + " resident_pixel_bytes=\(cache.residentPixelBytes())"
        )
    }

    func testConcurrentIdenticalRequestsShareOneFetchAndOnePreparation() async throws {
        let cache = MealThumbnailCache()
        let gate = ThumbnailLatch()
        let stub = ThumbnailStubSource(
            bytes: ThumbnailBox(try panorama(red)),
            revision: ThumbnailBox(.remote(epoch: 0)),
            fetches: ThumbnailBox(0),
            gate: gate
        )
        let source = stub.source
        let sharedRequest = request()
        let callers = 6

        let images = try await withThrowingTaskGroup(of: UIImage.self) { group in
            for _ in 0..<callers {
                group.addTask { try await cache.thumbnail(sharedRequest, from: source) }
            }
            // Every caller has arrived and joined the SAME parked attempt
            // (counted, never timed) before the fetch is released.
            await ThumbnailTestWait.until("every caller to coalesce") {
                cache.snapshotCounters().coalesced + cache.snapshotCounters().hits == callers - 1
            }
            await gate.open()
            var collected: [UIImage] = []
            for try await image in group {
                collected.append(image)
            }
            return collected
        }

        let counters = cache.snapshotCounters()
        XCTAssertEqual(images.count, callers)
        XCTAssertEqual(counters.fetches, 1, "identical concurrent requests share ONE fetch")
        XCTAssertEqual(counters.preparations, 1, "identical concurrent requests share ONE preparation")
        XCTAssertEqual(counters.coalesced, callers - 1, "the other callers joined the in-flight attempt")
        XCTAssertTrue(images.allSatisfy { $0 === images[0] })
        let peak = await cache.preparerPeakConcurrency()
        XCTAssertEqual(peak, 1, "the shared worker prepares one thumbnail at a time (bounded memory)")
        print(
            "ISSUE-188-COUNTS phase=concurrent callers=\(callers) fetches=\(counters.fetches)"
                + " preparations=\(counters.preparations) coalesced=\(counters.coalesced) hits=\(counters.hits)"
        )
    }

    func testPreparedPixelsMatchTheDisplayScaleAndEachTargetIsItsOwnIdentity() async throws {
        let cache = MealThumbnailCache()
        let stub = ThumbnailStubSource(
            bytes: ThumbnailBox(try panorama(red)),
            revision: ThumbnailBox(.remote(epoch: 0)),
            fetches: ThumbnailBox(0)
        )

        let atThree = try await cache.thumbnail(request(scale: 3), from: stub.source)
        let atTwo = try await cache.thumbnail(request(scale: 2), from: stub.source)

        XCTAssertEqual(
            MealThumbnailPixels.size(of: atThree), CGSize(width: 870, height: 435),
            "145pt at 3x is 435px tall: the prepared pixels ARE the painted pixels"
        )
        XCTAssertEqual(MealThumbnailPixels.size(of: atTwo), CGSize(width: 580, height: 290))
        XCTAssertEqual(cache.snapshotCounters().fetches, 2, "a different target pixel size is a different identity")
        XCTAssertEqual(cache.snapshotCounters().preparations, 2)
        XCTAssertEqual(cache.snapshotCounters().coalesced, 0)
        let targets = Set(cache.residentKeys().map(\.targetPixels))
        XCTAssertEqual(
            targets,
            [
                MealThumbnailPixelSize(width: 1_290, height: 435),
                MealThumbnailPixelSize(width: 860, height: 290)
            ]
        )
        print(
            "ISSUE-188-COUNTS phase=scale scale3=870x435 scale2=580x290 fetches=2 preparations=2"
        )
    }

    func testSamePathReplacementIsANewRevisionAndTheStaleImageIsNeverServed() async throws {
        let cache = MealThumbnailCache()
        let bytes = ThumbnailBox(try panorama(red))
        let replacement = try panorama(blue)
        let revision = ThumbnailBox(MealThumbnailRevision.remote(epoch: 0))
        let stub = ThumbnailStubSource(bytes: bytes, revision: revision, fetches: ThumbnailBox(0))

        let stale = try await cache.thumbnail(request(), from: stub.source)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: stale).isDominantlyRed)

        // The app replaces the photo at the SAME object path (the shipped
        // upsert): new bytes and the object's epoch moves.
        bytes.update { $0 = replacement }
        revision.update { $0 = .remote(epoch: 1) }

        let fresh = try await cache.thumbnail(request(), from: stub.source)
        let counters = cache.snapshotCounters()
        XCTAssertEqual(counters.fetches, 2, "the replaced object is re-read")
        XCTAssertEqual(counters.preparations, 2)
        XCTAssertTrue(
            ThumbnailPixelProbe.averageColor(of: fresh).isDominantlyBlue,
            "the surface is served the replaced photo, not the stale surrogate"
        )
        XCTAssertEqual(cache.residentEntryCount(), 1, "the replaced entry does not linger")
        print(
            "ISSUE-188-COUNTS phase=replacement fetches=\(counters.fetches)"
                + " preparations=\(counters.preparations) resident=\(cache.residentEntryCount())"
                + " served=blue"
        )
    }

    func testQueuedToRemoteTransitionRefetchesOnceAndReFilesThePreparedPixels() async throws {
        let payload = try panorama(red)
        let cache = MealThumbnailCache()
        let revision = ThumbnailBox(
            MealThumbnailRevision.queued(fingerprint: MealThumbnailFingerprint.of(payload))
        )
        let stub = ThumbnailStubSource(bytes: ThumbnailBox(payload), revision: revision, fetches: ThumbnailBox(0))

        let queued = try await cache.thumbnail(request(), from: stub.source)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: queued).isDominantlyRed)
        XCTAssertEqual(cache.snapshotCounters().fetches, 1)
        XCTAssertEqual(cache.snapshotCounters().preparations, 1)

        // The meal syncs: the outbox no longer holds the bytes, the remote
        // object does (identical payload) — a new revision of the same bytes.
        revision.update { $0 = .remote(epoch: 0) }
        let synced = try await cache.thumbnail(request(), from: stub.source)

        XCTAssertEqual(cache.snapshotCounters().fetches, 2, "the transition is observed at the read seam")
        XCTAssertEqual(
            cache.snapshotCounters().preparations, 1,
            "identical bytes under a new revision are re-filed, never decoded twice"
        )
        XCTAssertEqual(cache.snapshotCounters().reuses, 1)
        XCTAssertTrue(synced === queued)
        XCTAssertEqual(cache.residentEntryCount(), 1, "the queued revision is re-filed, not duplicated")

        _ = try await cache.thumbnail(request(), from: stub.source)
        XCTAssertEqual(cache.snapshotCounters().fetches, 2, "and the flip is bounded: one refetch, ever")
        print(
            "ISSUE-188-COUNTS phase=queued_to_remote fetches=\(cache.snapshotCounters().fetches)"
                + " preparations=\(cache.snapshotCounters().preparations) reuses=\(cache.snapshotCounters().reuses)"
        )
    }
}

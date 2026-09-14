import UIKit
import XCTest
@testable import Morsel

// Issue #188 — the bounds that keep the cache honest: a declared capacity and
// byte budget with LRU eviction, no retained originals, refusal of corrupt or
// missing bytes, cancellation that loses nothing, account scoping with logout,
// and the orientation-correct off-body preparation.

final class MealThumbnailReuseEvidenceTests: MealThumbnailTestCase {
    func testExternalChangeIsNeverPolledAndIsPickedUpOnTheNextAppSignal() async throws {
        let cache = MealThumbnailCache()
        let bytes = ThumbnailBox(try panorama(red))
        let replacement = try panorama(blue)
        let revision = ThumbnailBox(MealThumbnailRevision.remote(epoch: 0))
        let stub = ThumbnailStubSource(bytes: bytes, revision: revision, fetches: ThumbnailBox(0))

        let first = try await cache.thumbnail(request(), from: stub.source)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: first).isDominantlyRed)

        // An external change (another device) with NO app signal. The declared
        // bound is zero extra fetches: the cache never polls.
        bytes.update { $0 = replacement }
        let unpolled = try await cache.thumbnail(request(), from: stub.source)
        let unpolledCounters = cache.snapshotCounters()
        XCTAssertEqual(unpolledCounters.fetches, 1, "a warm entry spends no fetch while nothing signals a change")
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: unpolled).isDominantlyRed)

        // The app's own signal (a write-seam epoch bump) is what revalidates.
        revision.update { $0 = .remote(epoch: 1) }
        let revalidated = try await cache.thumbnail(request(), from: stub.source)
        XCTAssertEqual(cache.snapshotCounters().fetches, 2, "one refetch per signal, never more")
        XCTAssertEqual(cache.snapshotCounters().preparations, 2)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: revalidated).isDominantlyBlue)
        print("ISSUE-188-COUNTS phase=external_change warm=1 signalled=\(cache.snapshotCounters().fetches)")
    }

    func testEvictionHoldsTheDeclaredEntryAndByteBounds() async throws {
        // Entry bound: capacity 2 over six distinct identities.
        let cache = MealThumbnailCache(capacity: 2, byteLimit: 64 * 1_024 * 1_024)
        let stub = ThumbnailStubSource(
            bytes: ThumbnailBox(try panorama(red)),
            revision: ThumbnailBox(.remote(epoch: 0)),
            fetches: ThumbnailBox(0)
        )
        for index in 0..<6 {
            _ = try await cache.thumbnail(request(path: objectPath(index: index)), from: stub.source)
        }
        XCTAssertEqual(cache.residentEntryCount(), 2, "the declared capacity is the resident bound")
        XCTAssertGreaterThanOrEqual(cache.snapshotCounters().evictions, 4)

        // The LEAST recently used identity is the one that was dropped.
        let beforeOldest = cache.snapshotCounters().fetches
        _ = try await cache.thumbnail(request(path: objectPath(index: 0)), from: stub.source)
        XCTAssertEqual(cache.snapshotCounters().fetches, beforeOldest + 1, "the LRU victim is re-fetched")
        let beforeNewest = cache.snapshotCounters().fetches
        _ = try await cache.thumbnail(request(path: objectPath(index: 5)), from: stub.source)
        XCTAssertEqual(cache.snapshotCounters().fetches, beforeNewest, "the newest identity is still warm")

        // Byte bound: generous capacity, small budget (each thumbnail is 40×20×4 = 3.2 KB).
        let byteCache = MealThumbnailCache(capacity: 12, byteLimit: 8_000)
        let byteStub = ThumbnailStubSource(
            bytes: ThumbnailBox(try panorama(red)),
            revision: ThumbnailBox(.remote(epoch: 0)),
            fetches: ThumbnailBox(0)
        )
        for index in 0..<4 {
            let tiny = MealThumbnailRequest(
                accountID: account,
                objectPath: objectPath(index: index),
                displayBox: CGSize(width: 40, height: 20),
                displayScale: 1
            )
            _ = try await byteCache.thumbnail(tiny, from: byteStub.source)
        }
        XCTAssertLessThanOrEqual(
            byteCache.residentPixelBytes(), 8_000, "the declared byte budget is the resident bound"
        )
        XCTAssertEqual(byteCache.residentEntryCount(), 2)
        XCTAssertEqual(byteCache.snapshotCounters().evictions, 2)
        print(
            "ISSUE-188-MEMORY capacity=2 entries=\(cache.residentEntryCount())"
                + " pixel_bytes=\(cache.residentPixelBytes()) evictions=\(cache.snapshotCounters().evictions)"
                + " byte_budget_entries=\(byteCache.residentEntryCount())"
                + " byte_budget_bytes=\(byteCache.residentPixelBytes()) budget=8000"
        )
    }

    func testOneOverBudgetEntryIsKeptAndServedInsteadOfThrashing() async throws {
        // The shipped figure box prepares 870×435×4 = 1.5 MB, far over this
        // budget: the cache must still serve it rather than fetch-evict-fetch.
        let cache = MealThumbnailCache(capacity: 12, byteLimit: 1_000)
        let stub = ThumbnailStubSource(
            bytes: ThumbnailBox(try panorama(red)),
            revision: ThumbnailBox(.remote(epoch: 0)),
            fetches: ThumbnailBox(0)
        )
        _ = try await cache.thumbnail(request(), from: stub.source)
        XCTAssertEqual(cache.residentEntryCount(), 1, "one over-budget entry is kept, not thrashed")
        _ = try await cache.thumbnail(request(), from: stub.source)
        XCTAssertEqual(cache.snapshotCounters().fetches, 1, "and a warm read still costs no fetch")
    }

    func testCorruptAndMissingBytesAreRefusedAndNothingIsRetained() async throws {
        let payload = try panorama(red)
        let cache = MealThumbnailCache()
        let bytes = ThumbnailBox<Data>(Data([0x00, 0x01, 0x02, 0x03]))
        let stub = ThumbnailStubSource(
            bytes: bytes, revision: ThumbnailBox(.remote(epoch: 0)), fetches: ThumbnailBox(0)
        )

        do {
            _ = try await cache.thumbnail(request(), from: stub.source)
            XCTFail("undecodable bytes must be refused")
        } catch let error as MealThumbnailError {
            XCTAssertEqual(error, .corruptImage)
        }
        XCTAssertEqual(cache.residentEntryCount(), 0, "a refused image leaves nothing resident")
        XCTAssertEqual(cache.snapshotCounters().preparations, 0, "nothing was decoded")
        XCTAssertEqual(cache.snapshotCounters().failures, 1)

        // The same identity with honest bytes afterwards succeeds (the failure
        // was not poisoned into the cache).
        bytes.update { $0 = payload }
        let recovered = try await cache.thumbnail(request(), from: stub.source)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: recovered).isDominantlyRed)
        XCTAssertEqual(cache.snapshotCounters().preparations, 1)

        // Empty bytes are the shipped "no photo" answer, not a decode failure.
        let empty = ThumbnailBox<Data>(Data())
        let emptyStub = ThumbnailStubSource(
            bytes: empty,
            revision: ThumbnailBox(.remote(epoch: 7)),
            fetches: ThumbnailBox(0)
        )
        do {
            _ = try await cache.thumbnail(request(), from: emptyStub.source)
            XCTFail("empty bytes must be reported as missing, not prepared")
        } catch let error as MealThumbnailError {
            XCTAssertEqual(error, .missingPhoto)
        }
        XCTAssertEqual(cache.residentEntryCount(), 1, "the honest entry is still the only resident one")
    }

    func testCancelledCallerStopsWaitingWithoutLosingTheSharedAttempt() async throws {
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

        let cancelled = Task { try await cache.thumbnail(sharedRequest, from: source) }
        let survivor = Task { try await cache.thumbnail(sharedRequest, from: source) }
        await ThumbnailTestWait.until("the shared attempt to coalesce") {
            cache.snapshotCounters().coalesced == 1
        }
        cancelled.cancel()
        await gate.open()

        do {
            _ = try await cancelled.value
            XCTFail("a cancelled caller must stop waiting")
        } catch is CancellationError {
            // Expected.
        }
        let image = try await survivor.value
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: image).isDominantlyRed)
        XCTAssertEqual(cache.snapshotCounters().fetches, 1)
        XCTAssertEqual(cache.snapshotCounters().preparations, 1)
        XCTAssertEqual(cache.snapshotCounters().failures, 0, "a caller cancellation is not a cache failure")
        _ = try await cache.thumbnail(sharedRequest, from: source)
        XCTAssertEqual(cache.snapshotCounters().fetches, 1, "the shared attempt still published its result")
    }

    func testAccountScopeNeverServesAnotherAccountsPixelsAndLogoutClearsOnlyThatAccount() async throws {
        let cache = MealThumbnailCache()
        let mine = ThumbnailStubSource(
            bytes: ThumbnailBox(try panorama(red)),
            revision: ThumbnailBox(.remote(epoch: 0)),
            fetches: ThumbnailBox(0)
        )
        let theirs = ThumbnailStubSource(
            bytes: ThumbnailBox(try panorama(blue)),
            revision: ThumbnailBox(.remote(epoch: 0)),
            fetches: ThumbnailBox(0)
        )

        // The SAME object path string under two accounts is two identities.
        let myImage = try await cache.thumbnail(request(), from: mine.source)
        let theirImage = try await cache.thumbnail(request(account: otherAccount), from: theirs.source)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: myImage).isDominantlyRed)
        XCTAssertTrue(ThumbnailPixelProbe.averageColor(of: theirImage).isDominantlyBlue)
        XCTAssertEqual(cache.snapshotCounters().fetches, 2)
        XCTAssertEqual(cache.snapshotCounters().reuses, 0, "no pixels cross accounts")
        XCTAssertEqual(cache.residentEntryCount(), 2)

        let myWarm = try await cache.thumbnail(request(), from: mine.source)
        let theirWarm = try await cache.thumbnail(request(account: otherAccount), from: theirs.source)
        XCTAssertTrue(myWarm === myImage, "each account keeps its own warm image")
        XCTAssertTrue(theirWarm === theirImage)
        XCTAssertEqual(cache.snapshotCounters().fetches, 2)

        // Logout / account switch for ONE account: only that account is dropped.
        cache.removeAll(accountID: account)
        XCTAssertEqual(cache.residentEntryCount(), 1)
        _ = try await cache.thumbnail(request(), from: mine.source)
        XCTAssertEqual(cache.snapshotCounters().fetches, 3, "the signed-out account is re-read, never served")
        let theirStillWarm = try await cache.thumbnail(request(account: otherAccount), from: theirs.source)
        XCTAssertTrue(theirStillWarm === theirImage, "the other account stays warm")
        XCTAssertEqual(cache.snapshotCounters().fetches, 3)
        print(
            "ISSUE-188-COUNTS phase=accounts fetches=\(cache.snapshotCounters().fetches)"
                + " resident=\(cache.residentEntryCount())"
        )
    }

    func testLogoutRetiresAnInFlightAttemptSoNothingPublishesAfterwards() async throws {
        let cache = MealThumbnailCache()
        let gate = ThumbnailLatch()
        let stub = ThumbnailStubSource(
            bytes: ThumbnailBox(try panorama(red)),
            revision: ThumbnailBox(.remote(epoch: 0)),
            fetches: ThumbnailBox(0),
            gate: gate
        )
        let task = Task { try await cache.thumbnail(request(), from: stub.source) }
        await ThumbnailTestWait.until("the attempt to park") { cache.snapshotCounters().fetches == 1 }
        cache.removeAll(accountID: account)
        await gate.open()
        _ = try? await task.value
        XCTAssertEqual(cache.residentEntryCount(), 0, "a retired attempt publishes nothing into a signed-out account")
    }

}

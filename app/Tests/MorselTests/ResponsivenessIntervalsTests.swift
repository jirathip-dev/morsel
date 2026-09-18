import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #196 — AC1: the measured intervals. Every sample is a duration with a
// fixture ID; no content, token or URL is recorded. The two adopted
// provisional targets (AC5) are asserted here as targets on this simulator:
// physical-device acceptance stays human-gated in #172, so these numbers are
// simulator measurements under the documented conditions, never device proof.

@MainActor
final class ResponsivenessIntervalsTests: XCTestCase {
    /// Adopted provisional targets from issue #196 (targets, not results):
    /// <=100 ms first action feedback, <=200 ms cached useful paint,
    /// excluding the intentional hinge duration.
    private static let firstActionFeedbackTargetMs = 100.0
    private static let cachedUsefulPaintTargetMs = 200.0

    private var rigs: [ResponsivenessRig] = []
    private let metrics = ResponsivenessMetrics(run: "intervals")

    override func tearDown() {
        for rig in rigs { rig.unmount() }
        rigs = []
        super.tearDown()
    }

    private func mountRig(marker: Double, cacheDirectory: URL? = nil, hold: [String] = [],
                          mealCount: Int = 1) async throws -> ResponsivenessRig {
        let rig = try await ResponsivenessRigBuilder.make(marker: marker, cacheDirectory: cacheDirectory,
                                                          hold: hold, mealCount: mealCount)
        rigs.append(rig)
        return rig
    }

    /// Bounded 1 ms wait: fine enough to time an app-side leg.
    private func fineWait(_ message: String, timeout: TimeInterval = 3,
                          _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), message)
    }

    // MARK: - Cached useful paint

    func testCachedUsefulPaintIntervalOnAWarmCache() async throws {
        let seed = try await mountRig(marker: 100, mealCount: ResponsivenessFixture.mealCount)
        await fineWait("the seed read writes the cache") {
            seed.viewModel.snapshot?.meals.count == ResponsivenessFixture.mealCount
        }
        seed.unmount()

        let rig = try await mountRig(marker: 200, cacheDirectory: seed.directory,
                                     hold: [ResponsivenessRemote.network])
        await fineWait("the cached snapshot publishes") { rig.viewModel.snapshot != nil }
        let published = ContinuousClock.now
        await fineWait("the cached day paints") { rig.pixels.contentGround().ground == "cached" }
        metrics.record("cache-publish-to-paint", since: published)
        XCTAssertLessThan(metrics.percentile("cache-publish-to-paint", 0.95),
                          Self.cachedUsefulPaintTargetMs,
                          "adopted target: cached useful paint <= 200 ms on the declared device")
        XCTAssertEqual(rig.pixels.contentGround().ground, "cached",
                       "the paint is the cached day, not the parked fresh read")
        metrics.flush("cached-paint")
    }

    // MARK: - Remote refresh

    func testRemoteRefreshIntervalFromReleaseToFreshPaint() async throws {
        let seed = try await mountRig(marker: 100, mealCount: ResponsivenessFixture.mealCount)
        await fineWait("the seed read writes the cache") { seed.viewModel.snapshot != nil }
        seed.unmount()

        let rig = try await mountRig(marker: 200, cacheDirectory: seed.directory,
                                     hold: [ResponsivenessRemote.network])
        await fineWait("the cached day paints first") { rig.pixels.contentGround().ground == "cached" }
        let released = ContinuousClock.now
        await rig.remote.release(ResponsivenessRemote.network)
        await fineWait("the fresh answer paints") { rig.pixels.contentGround().ground == "fresh" }
        metrics.record("refresh-release-to-fresh-paint", since: released)
        metrics.flush("refresh")
    }

    // MARK: - Image preparation

    func testImagePreparationInterval() async throws {
        let preparer = MealThumbnailPreparer()
        let source = ResponsivenessFixture.mealPhotoBytes
        XCTAssertFalse(source.isEmpty, "the synthetic photo fixture must encode")
        metrics.set("image-source-bytes", source.count)
        let start = ContinuousClock.now
        let prepared = try await preparer.prepare(data: source, box: CGSize(width: 64, height: 64),
                                                  displayScale: 3)
        metrics.record("image-preparation", since: start)
        XCTAssertGreaterThan(prepared.size.width, 0, "preparation must produce an image")
        XCTAssertGreaterThan(prepared.size.height, 0)
        metrics.flush("image-prep")
    }

    // MARK: - Health callback

    func testHealthObserverCallbackInterval() async throws {
        let directory = URL(fileURLWithPath: "/tmp/morsel-196-evidence/callback-\(UUID().uuidString)",
                            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = LocalDataStore.storeURL(root: directory, accountID: ResponsivenessFixture.account)
        let reader = ParkedHealthReader()
        let importer = try HealthKitWeightImporter(reader: reader, store: try LocalHealthStore(databaseURL: database))
        importer.startObserving(onSuccess: {}, onError: { _ in })
        let handler = try XCTUnwrap(reader.handlers[.bodyMass], "the body-mass handler must register")

        let start = ContinuousClock.now
        let result = await handler()
        metrics.record("health-observer-callback", since: start)
        if case .failure(let error) = result {
            XCTFail("the observer callback must land: \(error)")
        }
        XCTAssertGreaterThanOrEqual(reader.bodyReads, 1, "the callback must run a body-mass pass")
        metrics.flush("health-callback")
    }
}

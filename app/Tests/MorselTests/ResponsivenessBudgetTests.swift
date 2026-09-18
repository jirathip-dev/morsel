import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #196 — AC3: independent fault injection (network / Storage / Health)
// plus the shell-level lifecycle request budget, both asserted from recorded
// counts. The facade, view model, pager and page area are the real ones; the
// remote is the harness's counting seam, so every number below is a count the
// shell really issued.

@MainActor
final class ResponsivenessBudgetTests: XCTestCase {
    private var rigs: [ResponsivenessRig] = []
    private let metrics = ResponsivenessMetrics(run: "budget")

    override func tearDown() {
        for rig in rigs { rig.unmount() }
        rigs = []
        super.tearDown()
    }

    private func mountRig(marker: Double, cacheDirectory: URL? = nil, hold: [String] = [],
                          mealCount: Int = 1,
                          importer: HealthKitWeightImporter? = nil,
                          healthStore: LocalHealthStore? = nil) async throws -> ResponsivenessRig {
        let rig = try await ResponsivenessRigBuilder.make(
            marker: marker, cacheDirectory: cacheDirectory, hold: hold, mealCount: mealCount,
            importer: importer, healthStore: healthStore)
        rigs.append(rig)
        return rig
    }

    /// Bounded async wait: yields the main actor so SwiftUI updates and
    /// MainActor tasks really run between checks.
    private func wait(_ message: String, timeout: TimeInterval = 5,
                      _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, message)
    }

    // MARK: - Shell lifecycle request budget

    func testShellLifecycleRequestBudgetFromRecordedCounts() async throws {
        let rig = try await mountRig(marker: 100)
        await wait("a cold mount paints the day") { rig.viewModel.snapshot != nil }
        let cold = await rig.remote.counts(for: ResponsivenessRemote.network)
        XCTAssertEqual(cold.calls, 1, "a cold mount issues exactly one day read")
        XCTAssertEqual(cold.peakInFlight, 1, "day reads stay single-flight")
        metrics.set("cold-mount-day-reads", cold.calls)

        rig.scene.phase = .background
        await wait("backgrounding concludes the pass") { !rig.viewModel.isLoading }
        var counts = await rig.remote.counts(for: ResponsivenessRemote.network)
        XCTAssertEqual(counts.calls, 1, "backgrounding must not issue a read")

        rig.scene.phase = .active
        await wait("one day read per foreground activation") {
            await rig.remote.counts(for: ResponsivenessRemote.network).calls == 2
        }
        counts = await rig.remote.counts(for: ResponsivenessRemote.network)
        XCTAssertEqual(counts.peakInFlight, 1, "activations join; they never overlap")
        metrics.set("foreground-return-day-reads", counts.calls - cold.calls)

        rig.pager.select(.history)
        XCTAssertTrue(rig.pump { rig.machine.atRest && rig.pager.selection == .history })
        counts = await rig.remote.counts(for: ResponsivenessRemote.network)
        XCTAssertEqual(counts.calls, 2, "leaving Today must not issue a day read")

        rig.pager.select(.today)
        await wait("returning to Today refreshes exactly once") {
            await rig.remote.counts(for: ResponsivenessRemote.network).calls == 3
        }
        metrics.set("tab-return-day-reads", 1)
        metrics.flush("parked-network")
    }

    // MARK: - Independent fault injection

    func testParkedNetworkKeepsCachedContentAndNavigationUsable() async throws {
        let seed = try await mountRig(marker: 100, mealCount: ResponsivenessFixture.mealCount)
        await wait("the seed read writes the cache") {
            seed.viewModel.snapshot?.meals.count == ResponsivenessFixture.mealCount
        }
        XCTAssertEqual(seed.pixels.contentGround().ground, "cached", "the seeded day must paint")
        seed.unmount()

        let rig = try await mountRig(marker: 200, cacheDirectory: seed.directory,
                                     hold: [ResponsivenessRemote.network])
        await wait("the cached day paints while the network is parked") {
            rig.pixels.contentGround().ground == "cached"
        }
        let parked = await rig.remote.counts(for: ResponsivenessRemote.network)
        XCTAssertEqual(parked.calls, 1, "the parked refresh is the one recorded request")
        XCTAssertEqual(parked.peakInFlight, 1)

        // A second activation while the read is still parked JOINS it: the
        // recorded count must not grow and nothing overlaps. Both transitions
        // are observed by the shell before the next one is requested.
        rig.scene.phase = .inactive
        await wait("the shell observes inactivity") { rig.scene.observed == .inactive }
        rig.scene.phase = .active
        await wait("the shell observes activity") { rig.scene.observed == .active }
        try await Task.sleep(for: .milliseconds(120))
        let joined = await rig.remote.counts(for: ResponsivenessRemote.network)
        XCTAssertEqual(joined.calls, 1, "an activation during a parked read joins it")
        XCTAssertEqual(joined.peakInFlight, 1, "the joined read never overlaps itself")

        rig.pager.select(.history)
        XCTAssertTrue(rig.pump { rig.machine.atRest && rig.pager.selection == .history })
        // Leaving Today cancels the parked pass: releasing it must not publish
        // a fresh answer while the user is away.
        await rig.remote.release(ResponsivenessRemote.network)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.pixels.contentGround().ground, "cached",
                       "a cancelled read must not publish while the user is away")

        await rig.remote.hold(ResponsivenessRemote.network)
        rig.pager.select(.today)
        await wait("returning to Today refreshes exactly once") {
            await rig.remote.counts(for: ResponsivenessRemote.network).calls == 2
        }
        XCTAssertEqual(rig.pixels.contentGround().ground, "cached",
                       "navigation must not lose the painted cached day")
        await rig.remote.release(ResponsivenessRemote.network)
        await wait("the released refresh paints the fresh answer") {
            rig.pixels.contentGround().ground == "fresh"
        }
        let settled = await rig.remote.counts(for: ResponsivenessRemote.network)
        XCTAssertEqual(settled.calls, 2, "one parked read per activation, never more")
        XCTAssertEqual(settled.peakInFlight, 1, "reads never overlap")
        metrics.set("parked-network-reads", settled.calls)
        metrics.flush("parked-storage")
    }

    func testParkedStorageLeavesTheDayReadAndNavigationUsable() async throws {
        let rig = try await mountRig(marker: 100, hold: [ResponsivenessRemote.storage],
                                     mealCount: ResponsivenessFixture.mealCount)
        await wait("the day read completes while Storage is parked") { rig.viewModel.snapshot != nil }
        XCTAssertEqual(rig.pixels.contentGround().ground, "cached", "the day still paints")

        let image = Task {
            try await rig.facade.loadMealImage(userID: ResponsivenessFixture.account, path: "fixture/photo")
        }
        await wait("one requested image is one in-flight Storage read") {
            await rig.remote.counts(for: ResponsivenessRemote.storage).peakInFlight == 1
        }

        rig.pager.select(.history)
        XCTAssertTrue(rig.pump { rig.machine.atRest && rig.pager.selection == .history },
                      "navigation stays usable while Storage is parked")
        rig.pager.select(.today)
        XCTAssertTrue(rig.pump { rig.machine.atRest && rig.pager.selection == .today })

        await rig.remote.release(ResponsivenessRemote.storage)
        let data = try await image.value
        XCTAssertFalse(data.isEmpty, "the released Storage read delivers its bytes")
        let storage = await rig.remote.counts(for: ResponsivenessRemote.storage)
        XCTAssertEqual(storage.calls, 1)
        XCTAssertEqual(storage.peakInFlight, 1, "one requested image is one in-flight read")
        metrics.set("parked-storage-reads", storage.calls)
        metrics.flush("parked-health")
    }

    func testParkedHealthLeavesTheDayReadAndNavigationUsable() async throws {
        let directory = URL(fileURLWithPath: "/tmp/morsel-196-evidence/health-\(UUID().uuidString)",
                            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = LocalDataStore.storeURL(root: directory, accountID: ResponsivenessFixture.account)
        let healthStore = try LocalHealthStore(databaseURL: database)
        let reader = ParkedHealthReader()
        reader.parked = true
        let importer = try HealthKitWeightImporter(reader: reader, store: healthStore)
        let rig = try await mountRig(marker: 100, cacheDirectory: directory,
                                     mealCount: ResponsivenessFixture.mealCount,
                                     importer: importer, healthStore: healthStore)

        await wait("the day read completes while Health is parked") { rig.viewModel.snapshot != nil }
        XCTAssertGreaterThanOrEqual(reader.bodyReads, 1, "the parked Health window was requested")

        rig.pager.select(.history)
        XCTAssertTrue(rig.pump { rig.machine.atRest && rig.pager.selection == .history },
                      "navigation stays usable while Health is parked")
        rig.pager.select(.today)
        XCTAssertTrue(rig.pump { rig.machine.atRest && rig.pager.selection == .today })
        XCTAssertEqual(rig.pixels.contentGround().ground, "cached", "the day stays painted")

        reader.release()
        await wait("the released Health import concludes") { !rig.viewModel.isLoading }
        XCTAssertEqual(reader.energyReads, 0, "the body-mass pass is independent of energy")
        metrics.set("parked-health-body-reads", reader.bodyReads)
        metrics.flush("lifecycle")
    }

    // MARK: - The harness must keep mirroring the shell's triggers

    func testHarnessTriggersMatchTheShellSource() throws {
        let shell = try shellSource()
        for literal in [".task {", "async let health: Void = viewModel.importWeights()",
                        "await viewModel.load()", "if phase == .active {",
                        "Task { await viewModel.load() }", "viewModel.cancelRefresh()",
                        "if oldTab != newTab, newTab == .today {"] {
            XCTAssertTrue(shell.contains(literal), "the shell must still wire \(literal)")
        }
    }

    private func shellSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appDirectory.appendingPathComponent("Sources/Morsel/MorselApp.swift"),
                          encoding: .utf8)
    }
}

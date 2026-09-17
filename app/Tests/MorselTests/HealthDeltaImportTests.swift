import XCTest
@testable import Morsel
import HealthKit

#if canImport(HealthKit)
// Issue #192 — observer imports are incremental: durable per-type cursors
// (opaque HealthKit anchors) bound every read, windows apply atomically with
// the cursor they advance, and energy day totals are recomputed from a durable
// per-sample contribution ledger. These regressions drive the REAL local store
// and the shipped observer/importer path through scripted anchored readers.
@MainActor
final class HealthDeltaImportTests: XCTestCase {
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-health-delta-\\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeHealthStore(calendar: Calendar = .autoupdatingCurrent) throws -> LocalHealthStore {
        try LocalHealthStore(
            databaseURL: LocalDataStore.storeURL(root: directory, accountID: account),
            calendar: calendar
        )
    }

    // MARK: - AC1: no-change notifications are deltas, not rescans

    func testNoChangeObserverNotificationsDoNotRescanOrRewriteHistory() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let measuredAt = Date(timeIntervalSince1970: 30_000)
        let reader = ScriptedDeltaReader()
        // One window with the full history, then explicit no-change windows
        // (nothing added, nothing removed).
        reader.bodyScript = [
            .init(samples: [WeightLog(measuredAt: measuredAt, kilograms: 74, sampleID: UUID())]),
            .init()
        ]
        reader.energyScript = [
            .init(energySamples: [
                EnergyBurnedLog(burnedAt: measuredAt, activeKilocalories: 250, sampleID: UUID())
            ]),
            .init()
        ]
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)
        importer.startObserving(onSuccess: {}, onError: { _ in })
        let bodyHandler = try XCTUnwrap(reader.handlers[.bodyMass])
        let energyHandler = try XCTUnwrap(reader.handlers[.activeEnergyBurned])

        _ = await bodyHandler()
        _ = await energyHandler()
        XCTAssertEqual(reader.bodyAnchors, [nil], "the first pass reads the full history once")
        XCTAssertEqual(reader.bodyRows, [1])
        // Everything is uploaded: a rewrite would surface as a fresh dirty row.
        try health.markWeightSynced(measuredAt: measuredAt)
        try health.markEnergyDaySynced(day: measuredAt)

        _ = await bodyHandler()
        _ = await energyHandler()
        _ = await bodyHandler()

        XCTAssertEqual(reader.bodyAnchors.count, 3)
        XCTAssertNil(reader.bodyAnchors[0])
        XCTAssertNotNil(reader.bodyAnchors[1])
        XCTAssertNotNil(reader.bodyAnchors[2])
        XCTAssertEqual(reader.bodyRows, [1, 0, 0], "a no-change pass processes zero rows")
        XCTAssertEqual(reader.energyRows, [1, 0])
        XCTAssertEqual(reader.energyAnchors.count, 2)
        XCTAssertNotNil(reader.energyAnchors[1])
        XCTAssertTrue(try health.unsyncedWeightSamples().isEmpty,
                      "no rewrite: the uploaded row stays clean")
        XCTAssertTrue(try health.dirtyEnergyDays().isEmpty,
                      "no rewrite: the synced day row stays clean")
        let anchorShape = reader.bodyAnchors.map { $0 == nil ? "full" : "anchored" }
        print("ISSUE192-TRACE ac1 bodyAnchors=\(anchorShape) bodyRows=\(reader.bodyRows)"
              + " energyRows=\(reader.energyRows)")
    }

    // MARK: - AC2: independent advance, success-only advance, safe replay

    func testBodyAndEnergyCursorsAdvanceIndependentlyAndOnlyAfterSuccess() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let measuredAt = Date(timeIntervalSince1970: 31_000)
        let reader = ScriptedDeltaReader()
        reader.bodyScript = [
            .init(failure: NSError(domain: "com.apple.healthkit", code: 5,
                                   userInfo: [NSLocalizedDescriptionKey: "denied"])),
            .init(samples: [WeightLog(measuredAt: measuredAt, kilograms: 73, sampleID: UUID())])
        ]
        reader.energyScript = [.init(energySamples: [
            EnergyBurnedLog(burnedAt: measuredAt, activeKilocalories: 120, sampleID: UUID())
        ])]
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)

        _ = try? await importer.importBodyMassDelta() // fails before persistence
        _ = try await importer.importActiveEnergyDelta()

        XCTAssertNil(try health.bodyMassAnchor(), "a failed pass advances no cursor")
        XCTAssertNotNil(try health.energyAnchor(), "…while the other type advances its own")
        XCTAssertTrue(try health.unsyncedWeightSamples().isEmpty)
        XCTAssertFalse(try health.dirtyEnergyDays().isEmpty)

        let stored = try await importer.importBodyMassDelta()
        XCTAssertEqual(stored.count, 1, "the failed window replays after a success")
        XCTAssertNotNil(try health.bodyMassAnchor())
        XCTAssertEqual(try health.unsyncedWeightSamples().count, 1, "…exactly once")
    }

    func testReplayedWindowLandsOnceWithoutLossOrDuplication() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let day = Calendar.autoupdatingCurrent.startOfDay(for: Date(timeIntervalSince1970: 32_000))
        let first = EnergyBurnedLog(burnedAt: day.addingTimeInterval(60), activeKilocalories: 300, sampleID: UUID())
        let second = EnergyBurnedLog(burnedAt: day.addingTimeInterval(120), activeKilocalories: 420, sampleID: UUID())
        let reader = ScriptedDeltaReader()
        // The same window is served twice: the first pass fails before the
        // cursor advanced, so the replay must rebuild the same totals.
        reader.energyScript = [
            .init(failure: CancellationError()),
            .init(energySamples: [first, second])
        ]
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)

        _ = try? await importer.importActiveEnergyDelta()
        XCTAssertNil(try health.energyAnchor())
        XCTAssertTrue(try health.dirtyEnergyDays().isEmpty, "nothing persisted, nothing claimed")

        let dayRows = try await importer.importActiveEnergyDelta()
        XCTAssertEqual(dayRows.map(\.activeKilocalories), [720])
        XCTAssertEqual(try health.dirtyEnergyDays().map(\.activeKilocalories), [720],
                       "no loss and no duplicate contributions")
    }

    func testCursorAdvancesOnlyAfterTheStorePersistsTheWindow() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let measuredAt = Date(timeIntervalSince1970: 35_000)
        let reader = ScriptedDeltaReader()
        reader.bodyScript = [
            .init(samples: [WeightLog(measuredAt: measuredAt, kilograms: 70, sampleID: UUID())])
        ]
        let store = FailingDeltaStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: store)

        _ = try? await importer.importBodyMassDelta() // the store refuses the write

        XCTAssertNil(try store.bodyMassAnchor(), "a refused persistence advances no cursor")
        XCTAssertTrue(store.appliedWeightRows.isEmpty)

        store.failWindowWrites = false
        let stored = try await importer.importBodyMassDelta()

        XCTAssertEqual(stored.count, 1, "the window replays once persistence succeeds")
        XCTAssertEqual(store.appliedWeightRows.count, 1, "…exactly once")
        XCTAssertNotNil(try store.bodyMassAnchor())
    }

    // MARK: - AC4: coalescing, independence, cancellation

    func testCoalescedCallbacksNeverOverlapPerTypeOrSuppressTheOther() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let measuredAt = Date(timeIntervalSince1970: 33_000)
        let reader = GatedDeltaReader(energySamples: [
            EnergyBurnedLog(burnedAt: measuredAt, activeKilocalories: 90, sampleID: UUID())
        ])
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)
        importer.startObserving(onSuccess: {}, onError: { _ in })
        let bodyHandler = try XCTUnwrap(reader.handlers[.bodyMass])
        let energyHandler = try XCTUnwrap(reader.handlers[.activeEnergyBurned])

        let firstBody = Task { await bodyHandler() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let secondBody = Task { await bodyHandler() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let energyResult = await energyHandler()

        XCTAssertEqual(energyResult.isSuccess, true, "the other type is never suppressed")
        XCTAssertEqual(reader.energyReads, 1)
        XCTAssertEqual(reader.bodyReads, 1, "a second callback never starts a concurrent read")
        XCTAssertEqual(try health.dirtyEnergyDays().count, 1, "energy landed while body was gated")
        reader.release()

        let results = await [firstBody.value, secondBody.value]
        XCTAssertTrue(results.allSatisfy(\.isSuccess))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(reader.bodyReads, 2, "overlapping callbacks coalesce into one follow-up")
    }

    func testCancelledPassLeavesResumableDurableCursorState() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let measuredAt = Date(timeIntervalSince1970: 34_000)
        let reader = CancellingDeltaReader(
            samples: [WeightLog(measuredAt: measuredAt, kilograms: 72, sampleID: UUID())]
        )
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)

        let pass = Task { try await importer.importBodyMassDelta() }
        try await Task.sleep(nanoseconds: 50_000_000)
        pass.cancel()
        _ = try? await pass.value

        XCTAssertNil(try health.bodyMassAnchor(), "a cancelled pass advances no cursor")
        XCTAssertTrue(try health.unsyncedWeightSamples().isEmpty)
        let stored = try await importer.importBodyMassDelta()
        XCTAssertEqual(stored.count, 1, "the cancelled window is still resumable")
        XCTAssertEqual(try health.unsyncedWeightSamples().count, 1)
        XCTAssertNotNil(try health.bodyMassAnchor())
    }
}

private extension Result where Success == Void {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
#endif

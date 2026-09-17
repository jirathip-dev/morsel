import XCTest
@testable import Morsel
import HealthKit

#if canImport(HealthKit)
// Issue #192 base probe — a BASE-COMPATIBLE reproduction of the audited
// mechanism: the shipped observer path issues an UNBOUNDED sample query on a
// no-change notification (HealthKitWeightImporter's observer handlers call the
// import methods with the default `since: nil`).
//
// This file is committed as a runnable artifact for a disposable base archive
// (it only touches the pre-fix API: `WeightSampleReading.samples(since:)` and
// `HealthKitWeightImporter(reader:store:)`). It is NOT part of the head target:
// the fix replaces the `since:`-window reader API with durable anchored
// windows, so this probe cannot compile against the head — its RED is the
// evidence that the base mechanism rescans, and the head's own suite
// (HealthDeltaImportTests) carries the same observable assertions.
@MainActor
final class BoundedObserverProbeTests: XCTestCase {
    func testNoChangeObserverNotificationDoesNotRescanFullHistory() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let sample = Date(timeIntervalSince1970: 30_000)
        let reader = ProbeReader(logs: [WeightLog(measuredAt: sample, kilograms: 74)])
        let store = MockWeightLogStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: store)
        importer.startObserving(onSuccess: {}, onError: { _ in })

        let handler = try XCTUnwrap(reader.handlers[.bodyMass])

        // Initial pass: reading the full history once is expected.
        _ = await handler()
        XCTAssertEqual(reader.windows.count, 1)
        XCTAssertNil(reader.windows[0], "the initial pass reads the full history")

        // A no-change notification must be a bounded delta, not a rescan.
        _ = await handler()
        XCTAssertEqual(reader.windows.count, 2)
        XCTAssertNotNil(
            reader.windows[1],
            "ISSUE192-REPRO: a no-change observer pass must be bounded by the durable cursor, not an unbounded full-history query"
        )
        XCTAssertEqual(
            reader.rowsReturned.last, 0,
            "ISSUE192-REPRO: a no-change observer pass must process zero rows, not the full history"
        )
        print("ISSUE192-PROBE windows=\(reader.windows.map { $0 == nil ? "nil" : "bounded" }) rows=\(reader.rowsReturned)")
    }
}

private final class ProbeReader: WeightSampleReading {
    let logs: [WeightLog]
    private(set) var windows: [Date?] = []
    private(set) var rowsReturned: [Int] = []
    private(set) var handlers: [HealthKitObserverKind: () async -> Result<Void, Error>] = [:]

    init(logs: [WeightLog]) { self.logs = logs }

    func requestAuthorization() async throws {}

    func samples(since: Date?) async throws -> [WeightLog] {
        windows.append(since)
        let result: [WeightLog]
        if let since {
            result = logs.filter { $0.measuredAt > since }
        } else {
            result = logs
        }
        rowsReturned.append(result.count)
        return result
    }

    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] { [] }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {
        handlers[kind] = handler
    }

    func stopObserving() {}
}
#endif

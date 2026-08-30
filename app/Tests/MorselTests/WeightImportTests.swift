import XCTest
@testable import Morsel
import HealthKit

#if canImport(HealthKit)
final class WeightImportTests: XCTestCase {
    func testMockStoreDeduplicatesMeasuredAtAndDropsInvalidValues() async throws {
        let store = MockWeightLogStore()
        let date = Date(timeIntervalSince1970: 1_000)
        try await store.upsert([
            WeightLog(measuredAt: date, kilograms: 80),
            WeightLog(measuredAt: date, kilograms: 81),
            WeightLog(measuredAt: date.addingTimeInterval(1), kilograms: .infinity),
            WeightLog(measuredAt: date.addingTimeInterval(2), kilograms: 0)
        ])

        XCTAssertEqual(store.logs, [WeightLog(measuredAt: date, kilograms: 81)])
    }

    func testImporterReadsThroughReaderAndUpsertsThroughStore() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let reader = MockWeightReader()
        let store = MockWeightLogStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: store)

        try await importer.importBodyMass()

        XCTAssertTrue(reader.authorizationRequested)
        XCTAssertEqual(store.logs, reader.logs)
    }

    func testImporterDropsInvalidSamplesAndDeduplicatesValidSamples() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let date = Date(timeIntervalSince1970: 3_000)
        let reader = MockWeightReader(logs: [
            WeightLog(measuredAt: date, kilograms: 80),
            WeightLog(measuredAt: date, kilograms: 81),
            WeightLog(measuredAt: date.addingTimeInterval(1), kilograms: 0),
            WeightLog(measuredAt: date.addingTimeInterval(2), kilograms: .infinity)
        ])
        let store = MockWeightLogStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: store)

        try await importer.importBodyMass()

        XCTAssertEqual(store.logs, [WeightLog(measuredAt: date, kilograms: 81)])
    }
}

private final class MockWeightReader: WeightSampleReading {
    let logs: [WeightLog]
    var authorizationRequested = false

    init(logs: [WeightLog] = [WeightLog(measuredAt: Date(timeIntervalSince1970: 2_000), kilograms: 75)]) {
        self.logs = logs
    }

    func requestAuthorization() async throws {
        authorizationRequested = true
    }

    func samples(since: Date?) async throws -> [WeightLog] {
        logs
    }

    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] { [] }

    func startObserving(_ handler: @escaping () async -> Result<Void, Error>, onError: @escaping (Error) -> Void) {}

    func stopObserving() {}
}
#endif

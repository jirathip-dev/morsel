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
        let importer = HealthKitWeightImporter(reader: reader, store: store)

        try await importer.importBodyMass()

        XCTAssertTrue(reader.authorizationRequested)
        XCTAssertEqual(store.logs, reader.logs)
    }
}

private final class MockWeightReader: WeightSampleReading {
    let logs = [WeightLog(measuredAt: Date(timeIntervalSince1970: 2_000), kilograms: 75)]
    var authorizationRequested = false

    func requestAuthorization() async throws {
        authorizationRequested = true
    }

    func samples(since: Date?) async throws -> [WeightLog] {
        logs
    }
}
#endif

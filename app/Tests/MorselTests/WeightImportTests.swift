import XCTest
@testable import Morsel
import HealthKit

#if canImport(HealthKit)
@MainActor
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

    func testActiveEnergyImporterFiltersInvalidAndDeduplicates() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let date = Date(timeIntervalSince1970: 4_000)
        let day = Date(timeIntervalSince1970: 0)
        let reader = MockWeightReader(energyLogs: [
            EnergyBurnedLog(burnedAt: date, activeKilocalories: 300),
            EnergyBurnedLog(burnedAt: date, activeKilocalories: 420),
            EnergyBurnedLog(burnedAt: date.addingTimeInterval(86_400), activeKilocalories: 100),
            EnergyBurnedLog(burnedAt: date.addingTimeInterval(1), activeKilocalories: 0),
            EnergyBurnedLog(burnedAt: date.addingTimeInterval(2), activeKilocalories: -1),
            EnergyBurnedLog(burnedAt: date.addingTimeInterval(3), activeKilocalories: .infinity)
        ])
        let store = MockWeightLogStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: store)

        try await importer.importActiveEnergy()

        XCTAssertEqual(store.energyBurnedLogs, [
            EnergyBurnedLog(burnedAt: day, activeKilocalories: 720),
            EnergyBurnedLog(burnedAt: day.addingTimeInterval(86_400), activeKilocalories: 100)
        ])
    }

    func testNetEnergyDayViewOverUnder() async throws {
        let goal = DashboardGoal(calorieTargetKcal: 2_000, proteinG: 0, carbsG: 0, fatG: 0, source: .manual)
        let item = MealItem(itemID: UUID(), name: "oats", quantity: 1, unit: .serving,
                            caloriesKcal: 1_800, proteinG: 0, carbsG: 0, fatG: 0,
                            fiberG: 0, sugarG: 0, confidence: 1, notes: nil, source: .manual)
        let meal = MealRecord(mealLogID: UUID(), mealType: .breakfast, eatenAt: Date(), source: .manual,
                              items: [item])
        let snapshot = DashboardSnapshot(date: Date(), meals: [meal], goal: goal, activeEnergyBurned: 300)
        let repository = MockDashboardRepository(snapshot: snapshot)
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())

        await viewModel.load()

        XCTAssertEqual(viewModel.netEnergy, 1_500)
        XCTAssertEqual(viewModel.netEnergyDeltaFromGoal, -500)
        XCTAssertEqual(NetEnergyNotice.message(net: 1_500, goal: goal), "Net energy: 1,500 kcal · 500 kcal under")

        XCTAssertEqual(NetEnergyNotice.message(net: 2_300, goal: goal), "Net energy: 2,300 kcal · 300 kcal over")
        XCTAssertEqual(NetEnergyNotice.message(net: 2_000, goal: goal), "Net energy: 2,000 kcal · 0 kcal under")
    }

    func testActiveEnergyObserverTriggersImportAndSuccessReload() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let date = Date(timeIntervalSince1970: 5_000)
        let day = Date(timeIntervalSince1970: 0)
        let reader = MockWeightReader(energyLogs: [EnergyBurnedLog(burnedAt: date, activeKilocalories: 250)])
        let store = MockWeightLogStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: store)
        var successes = 0

        importer.startObserving(onSuccess: { successes += 1 }, onError: { _ in XCTFail("unexpected observer error") })
        let result = await reader.observerHandler?()

        XCTAssertEqual(result?.isSuccess, true)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(store.energyBurnedLogs, [EnergyBurnedLog(burnedAt: day, activeKilocalories: 250)])
    }
}

private final class MockWeightReader: WeightSampleReading {
    let logs: [WeightLog]
    let energyLogs: [EnergyBurnedLog]
    var observerHandler: (() async -> Result<Void, Error>)?
    var authorizationRequested = false

    init(
        logs: [WeightLog] = [WeightLog(measuredAt: Date(timeIntervalSince1970: 2_000), kilograms: 75)],
        energyLogs: [EnergyBurnedLog] = []
    ) {
        self.logs = logs
        self.energyLogs = energyLogs
    }

    func requestAuthorization() async throws {
        authorizationRequested = true
    }

    func samples(since: Date?) async throws -> [WeightLog] {
        logs
    }

    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] { energyLogs }

    func startObserving(_ handler: @escaping () async -> Result<Void, Error>, onError: @escaping (Error) -> Void) {
        observerHandler = handler
    }

    func stopObserving() {}
}

private extension Result where Success == Void {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
#endif

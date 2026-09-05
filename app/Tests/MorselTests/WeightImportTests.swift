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
        // Issue #121 — day totals land on the DEVICE'S LOCAL day rows.
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
        let nextDay = Calendar.autoupdatingCurrent.startOfDay(for: date.addingTimeInterval(86_400))
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
            EnergyBurnedLog(burnedAt: nextDay, activeKilocalories: 100)
        ])
    }

    // Issue #94: active energy is a margin note, never an operand of the
    // readout. The legacy "net energy" day-view path is gone; the delta the
    // app displays is eaten minus goal only.
    func testEatenReadoutIgnoresActiveBurn() async throws {
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

        // 1,800 eaten stays 1,800: the 300 kcal burn never becomes a net 1,500.
        XCTAssertEqual(viewModel.totals.caloriesKcal, 1_800)
        XCTAssertEqual(viewModel.snapshot?.activeEnergyBurned, 300)
        XCTAssertEqual(
            DashboardMath.eatenMinusGoal(eaten: viewModel.totals.caloriesKcal, goal: goal.calorieTargetKcal),
            -200
        )
    }

    func testActiveEnergyObserverTriggersImportAndSuccessReload() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let date = Date(timeIntervalSince1970: 5_000)
        // Issue #121 — day totals land on the DEVICE'S LOCAL day rows.
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
        let reader = MockWeightReader(energyLogs: [EnergyBurnedLog(burnedAt: date, activeKilocalories: 250)])
        let store = MockWeightLogStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: store)
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        let viewModel = DashboardViewModel(repository: repository, userID: UUID(), weightImporter: importer)

        await viewModel.importWeights()
        let initialLoads = repository.loadCount
        let result = await reader.observerHandler?()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(reader.observerKinds, [.bodyMass, .activeEnergyBurned])
        XCTAssertEqual(reader.deliveryKinds, [.bodyMass, .activeEnergyBurned])
        XCTAssertEqual(result?.isSuccess, true)
        XCTAssertEqual(repository.loadCount, initialLoads + 1)
        XCTAssertEqual(store.energyBurnedLogs, [EnergyBurnedLog(burnedAt: day, activeKilocalories: 250)])
    }
}

private final class MockWeightReader: WeightSampleReading {
    let logs: [WeightLog]
    let energyLogs: [EnergyBurnedLog]
    var observerHandler: (() async -> Result<Void, Error>)?
    var observerKinds: [HealthKitObserverKind] = []
    var deliveryKinds: [HealthKitObserverKind] = []
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

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {
        observerKinds.append(kind)
        deliveryKinds.append(kind)
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

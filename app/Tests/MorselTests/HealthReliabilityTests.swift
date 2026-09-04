import XCTest
@testable import Morsel
import HealthKit

#if canImport(HealthKit)
// Issue #106 — Apple Health (bodyMass + activeEnergyBurned ONLY): per-type
// independence (one denial never suppresses the other), watermark-advanced
// bounded re-imports, single-flight observer coalescing, per-kind observer
// handlers, calm status copy (never raw entitlement/HK text), and the
// durable local-first upload drain with idempotent remote upserts.
@MainActor
final class HealthReliabilityTests: XCTestCase {
    // New XCTestCase instance per test method: UUID-scoped identity + scratch
    // directory are unique per test without implicitly unwrapped optionals.
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-health-tests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeHealthStore() throws -> LocalHealthStore {
        try LocalHealthStore(
            databaseURL: LocalDataStore.storeURL(root: directory, accountID: account)
        )
    }

    // MARK: - Per-type independence

    func testBodyMassDenialDoesNotSuppressActiveEnergyImport() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let day = Date(timeIntervalSince1970: 0)
        let reader = ScriptedHealthReader(
            energyLogs: [EnergyBurnedLog(burnedAt: day, activeKilocalories: 250)]
        )
        reader.failBodyMassSamples = true
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)

        _ = try? await importer.importBodyMass(since: nil) // fails: raw denial surfaces
        let energy = try await importer.importActiveEnergy(since: nil)

        XCTAssertFalse(energy.isEmpty, "the energy path must still import after a body-mass failure")
        XCTAssertFalse(try health.dirtyEnergyDays().isEmpty)
        XCTAssertEqual(try health.energyAnchor(), nil, "no anchor until a successful pass completes")
    }

    func testImportFailuresSurfaceOnlyMappedCopyThroughViewModel() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let reader = ScriptedHealthReader(
            energyLogs: [EnergyBurnedLog(burnedAt: Date(timeIntervalSince1970: 0), activeKilocalories: 250)]
        )
        reader.failBodyMassSamples = true
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)
        let repository = MockDashboardRepository(
            snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil)
        )
        let viewModel = DashboardViewModel(
            repository: repository, userID: UUID(), weightImporter: importer, healthStore: health
        )

        await viewModel.importWeights()

        XCTAssertEqual(
            viewModel.weightImportError, HealthSyncUserMessage.backgroundSyncUnavailable,
            "raw denial text never reaches the user"
        )
        XCTAssertFalse(viewModel.weightImportError?.contains("HKError") ?? true)
        XCTAssertFalse(viewModel.weightImportError?.contains("entitlement") ?? true)
        XCTAssertEqual(viewModel.healthStatus, .pending, "locally stored energy rows wait to upload")
        XCTAssertFalse(viewModel.healthStatus.copy.contains("com.apple.developer"))
    }

    func testPermissionDeniedMapsToPermissionRequiredCalmStatus() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let reader = ScriptedHealthReader()
        reader.authorized = false
        reader.failBodyMassSamples = true
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)
        let repository = MockDashboardRepository(
            snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil)
        )
        let viewModel = DashboardViewModel(
            repository: repository, userID: UUID(), weightImporter: importer, healthStore: health
        )

        await viewModel.importWeights()

        XCTAssertEqual(viewModel.healthStatus, .permissionRequired)
        let copy = viewModel.healthStatus.copy
        XCTAssertFalse(copy.contains("HKError"))
        XCTAssertFalse(copy.contains("com.apple.developer"))
        XCTAssertFalse(copy.contains("entitlement"))
        XCTAssertTrue(copy.contains("Apple Health access"), "friendly, actionable permission copy")
    }

    // MARK: - Watermark + bounded re-import

    func testWatermarkAdvancesOnlyOnSuccessAndBoundsNextQuery() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let sample = Date(timeIntervalSince1970: 30_000)
        let reader = ScriptedHealthReader(logs: [WeightLog(measuredAt: sample, kilograms: 74)])
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)

        let stored = try await importer.importBodyMass(since: nil)
        let latest = try XCTUnwrap(stored.map(\.measuredAt).max())
        try health.setBodyMassAnchor(latest)
        XCTAssertEqual(try health.bodyMassAnchor(), sample)

        let second = try await importer.importBodyMass(since: try health.bodyMassAnchor())
        XCTAssertTrue(second.isEmpty, "no full-history rescan: the anchor bounds the next query")
    }

    func testDuplicateSampleReimportStaysDeduplicatedAndClean() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let sample = Date(timeIntervalSince1970: 40_000)
        let health = try makeHealthStore()
        try await health.upsert([WeightLog(measuredAt: sample, kilograms: 72)])
        try health.markWeightSynced(measuredAt: sample)

        // Observer re-delivery of the same sample must not dirty the row.
        try await health.upsert([WeightLog(measuredAt: sample, kilograms: 72)])

        XCTAssertTrue(try health.unsyncedWeightSamples().isEmpty)
    }

    // MARK: - Observers

    func testObserversRegisterForBothKindsAndEachHandlerImportsOnlyItsKind() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let sample = Date(timeIntervalSince1970: 50_000)
        let reader = ScriptedHealthReader(
            logs: [WeightLog(measuredAt: sample, kilograms: 73)],
            energyLogs: [EnergyBurnedLog(burnedAt: Date(timeIntervalSince1970: 0), activeKilocalories: 250)]
        )
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)
        var successes = 0
        importer.startObserving(onSuccess: { successes += 1 }, onError: { _ in })

        XCTAssertEqual(reader.registeredKinds, [.bodyMass, .activeEnergyBurned])

        let bodyHandler = try XCTUnwrap(reader.handlers[.bodyMass])
        let bodyResult = await bodyHandler()
        XCTAssertEqual(bodyResult.isSuccess, true)
        XCTAssertFalse(try health.unsyncedWeightSamples().isEmpty, "bodyMass handler imports body mass")
        XCTAssertTrue(try health.dirtyEnergyDays().isEmpty, "…and never the other type")

        let energyHandler = try XCTUnwrap(reader.handlers[.activeEnergyBurned])
        let energyResult = await energyHandler()
        XCTAssertEqual(energyResult.isSuccess, true)
        XCTAssertFalse(try health.dirtyEnergyDays().isEmpty, "energy handler imports its own type")
        XCTAssertEqual(successes, 2)
    }

    func testOverlappingObserverCallbacksCoalesceIntoOneImport() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let reader = GatedHealthReader()
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)
        var successes = 0
        importer.startObserving(onSuccess: { successes += 1 }, onError: { _ in })

        let handler = try XCTUnwrap(reader.handlers[.bodyMass])
        let first = Task { await handler() }
        // Second callback arrives while the first import is still gated.
        let second = Task { await handler() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            reader.samplesCallCount, 1,
            "the second callback must never start a concurrent import"
        )
        reader.release()

        let results = await [first.value, second.value]
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy(\.isSuccess))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(
            reader.samplesCallCount, 2,
            "overlapping callbacks coalesce into exactly ONE follow-up import"
        )
        XCTAssertEqual(successes, 2, "each HealthKit completion handler fires exactly once")
    }

    // MARK: - Durable local-first upload drain

    func testEngineDrainsWeightAndEnergyRowsThroughIdempotentRemoteUpserts() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let health = try makeHealthStore()
        let sample = Date(timeIntervalSince1970: 60_000)
        try await health.upsert([WeightLog(measuredAt: sample, kilograms: 71)])
        let day = Date(timeIntervalSince1970: 0)
        try await health.upsertEnergyBurned([EnergyBurnedLog(burnedAt: day, activeKilocalories: 320)])
        let remote = MockWeightLogStore()
        let engine = LocalSyncEngine(
            userID: account,
            store: try LocalDataStore(databaseURL: LocalDataStore.storeURL(root: directory, accountID: account)),
            healthStore: health,
            healthRemote: remote
        )

        await engine.runPass()

        XCTAssertEqual(remote.logs, [WeightLog(measuredAt: sample, kilograms: 71)])
        XCTAssertEqual(remote.energyBurnedLogs, [EnergyBurnedLog(burnedAt: day, activeKilocalories: 320)])
        XCTAssertTrue(try health.unsyncedWeightSamples().isEmpty)
        XCTAssertTrue(try health.dirtyEnergyDays().isEmpty)
        XCTAssertNotNil(try health.lastSuccessfulUpload())
        XCTAssertFalse(try health.hasPendingUploads())
    }

    func testRemoteUploadFailureKeepsRowsDurableForNextPass() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let health = try makeHealthStore()
        let sample = Date(timeIntervalSince1970: 70_000)
        try await health.upsert([WeightLog(measuredAt: sample, kilograms: 70)])
        let failing = ThrowingRemoteHealthStore()
        let engine = LocalSyncEngine(
            userID: account,
            store: try LocalDataStore(databaseURL: LocalDataStore.storeURL(root: directory, accountID: account)),
            healthStore: health,
            healthRemote: failing
        )

        await engine.runPass()

        XCTAssertEqual(try health.unsyncedWeightSamples().count, 1, "failure never drops local rows")
        XCTAssertNil(try health.lastSuccessfulUpload())
    }
}

private extension Result where Success == Void {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Fakes

private final class ScriptedHealthReader: WeightSampleReading {
    let logs: [WeightLog]
    let energyLogs: [EnergyBurnedLog]
    var authorized = true
    var failBodyMassSamples = false
    private(set) var registeredKinds: [HealthKitObserverKind] = []
    private(set) var handlers: [HealthKitObserverKind: () async -> Result<Void, Error>] = [:]
    private(set) var samplesSince: [Date?] = []

    init(logs: [WeightLog] = [], energyLogs: [EnergyBurnedLog] = []) {
        self.logs = logs
        self.energyLogs = energyLogs
    }

    func requestAuthorization() async throws {}

    func samples(since: Date?) async throws -> [WeightLog] {
        samplesSince.append(since)
        if failBodyMassSamples {
            throw NSError(domain: "com.apple.healthkit", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "denied"])
        }
        if let since {
            return logs.filter { $0.measuredAt > since }
        }
        return logs
    }

    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] { energyLogs }

    func authorizationStatus(for kind: HealthKitObserverKind) -> Bool { authorized }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {
        registeredKinds.append(kind)
        handlers[kind] = handler
    }

    func stopObserving() {}
}

/// Reader whose sample query blocks until released (single-flight probe).
private final class GatedHealthReader: WeightSampleReading {
    private(set) var samplesCallCount = 0
    private(set) var registeredKinds: [HealthKitObserverKind] = []
    private(set) var handlers: [HealthKitObserverKind: () async -> Result<Void, Error>] = [:]
    private var gate: CheckedContinuation<Void, Never>?

    func requestAuthorization() async throws {}

    func samples(since: Date?) async throws -> [WeightLog] {
        samplesCallCount += 1
        await withCheckedContinuation { gate = $0 }
        return []
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] { [] }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {
        registeredKinds.append(kind)
        handlers[kind] = handler
    }

    func stopObserving() {}
}

/// Remote health store that always fails (drain keeps rows durable).
private final class ThrowingRemoteHealthStore: WeightLogStore {
    func upsert(_ logs: [WeightLog]) async throws {
        throw URLError(.notConnectedToInternet)
    }

    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws {
        throw URLError(.notConnectedToInternet)
    }
}
#endif

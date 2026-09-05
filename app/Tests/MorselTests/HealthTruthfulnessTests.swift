import XCTest
@testable import Morsel
import HealthKit

#if canImport(HealthKit)
// Issue #112 — health status truthfulness regressions (device: Settings said
// "Last successful Health sync" while the weight trend had no body-mass
// data). Production-shaped through the importer/store seams:
//   (a) read denied (empty result, NO error — the iOS read-denial shape)
//       → calm status is permissionRequired, never synced;
//   (b) energy uploaded + zero weight → the status names energy only;
//   (c) the same sample as a remote whole-second ISO row + a local
//       sub-second HealthKit row → ONE trend point;
//   (d) 30 daily samples in the trailing window → 30 trend points (older
//       local rows outside the window never paint in).
@MainActor
final class HealthTruthfulnessTests: XCTestCase {
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-health-truth-\(UUID().uuidString)", isDirectory: true)

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

    // MARK: - (a) Read denied → permission required, never "synced"

    func testReadDeniedImportShowsPermissionRequiredNeverSynced() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let health = try makeHealthStore()
        // An earlier energy-only pass stamped a last-successful-upload time —
        // the exact state that used to print a green "synced" lie.
        try health.setLastSuccessfulUpload(Date(timeIntervalSince1970: 99_000))
        let importer = try HealthKitWeightImporter(reader: ReadDeniedReader(), store: health)
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(
                snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil)
            ),
            userID: UUID(), weightImporter: importer, healthStore: health
        )

        // iOS returns an EMPTY result with NO error when read access is
        // denied, so the import succeeds with zero samples.
        await viewModel.importWeights()

        XCTAssertEqual(
            viewModel.healthStatus, .permissionRequired,
            "read-denied (empty result, no error) must never read as synced"
        )
        XCTAssertFalse(viewModel.healthStatus.copy.contains("synced"))
        XCTAssertTrue(
            viewModel.healthStatus.copy.contains("Settings › Health"),
            "actionable read-access guidance"
        )
    }

    // MARK: - (b) Energy uploaded + zero weight → status names energy only

    func testEnergyOnlyUploadNamesEnergyAndNeverClaimsWeight() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let url = LocalDataStore.storeURL(root: directory, accountID: account)
        let health = try LocalHealthStore(databaseURL: url)
        let energyDay = Date(timeIntervalSince1970: 0)
        let reader = EnergyOnlyReader(
            energyLogs: [EnergyBurnedLog(burnedAt: energyDay, activeKilocalories: 250)]
        )
        let importer = try HealthKitWeightImporter(reader: reader, store: health)
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(
                snapshot: DashboardSnapshot(date: energyDay, meals: [], goal: nil)
            ),
            userID: UUID(), weightImporter: importer, healthStore: health
        )
        let engine = LocalSyncEngine(
            userID: account,
            store: try LocalDataStore(databaseURL: url),
            healthStore: health,
            healthRemote: MockWeightLogStore()
        )

        await viewModel.importWeights() // imports the energy day, zero weight
        await engine.runPass() // durable drain uploads energy only
        // Re-import re-derives the calm status from the per-type marks.
        await viewModel.importWeights()

        let copy = viewModel.healthStatus.copy
        XCTAssertTrue(
            copy.contains("energy only"),
            "the status must name the type that actually uploaded"
        )
        XCTAssertFalse(copy.contains("weight"), "zero weight samples must never read as a weight sync")
    }

    // MARK: - (c) Same sample remote (whole second) + local (sub-second) → 1 point

    func testRemoteWholeSecondAndLocalSubSecondSameSampleIsOnePoint() async throws {
        let url = LocalDataStore.storeURL(root: directory, accountID: account)
        let health = try LocalHealthStore(databaseURL: url)
        let sampleDay = Date(timeIntervalSince1970: 1_800_000_000)
        // HealthKit keeps sub-second time…
        try await health.upsert([WeightLog(measuredAt: sampleDay.addingTimeInterval(0.456), kilograms: 72.4)])
        // …the remote ISO round-trip lands on the whole second.
        let remote = MockDashboardRepository(
            snapshot: DashboardSnapshot(
                date: sampleDay, meals: [], goal: nil,
                weightTrend: [WeightTrendPoint(date: sampleDay, kilograms: 72.4)]
            )
        )
        let repository = LocalFirstDashboardRepository(
            remote: remote,
            store: try LocalDataStore(databaseURL: url),
            snapshotCache: try LocalSnapshotCache(databaseURL: url),
            healthStore: health
        )

        let snapshot = try await repository.loadToday(userID: account, date: sampleDay)

        XCTAssertEqual(
            snapshot.weightTrend.count, 1,
            "the same sample at whole-second (remote) and sub-second (local) must render once"
        )
        XCTAssertEqual(snapshot.weightTrend.first?.kilograms, 72.4)
    }

    // MARK: - (d) 30 daily samples → 30 trend points in the 30-day window

    func testThirtyDailySamplesYieldThirtyTrendPointsInWindow() async throws {
        let url = LocalDataStore.storeURL(root: directory, accountID: account)
        let health = try LocalHealthStore(databaseURL: url)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let referenceDay = Date(timeIntervalSince1970: 1_800_000_000)
        let dayStart = calendar.startOfDay(for: referenceDay)

        var local: [WeightLog] = []
        var remotePoints: [WeightTrendPoint] = []
        // 41 daily samples: 11 older than the window + 30 inside it; the
        // remote trend query only ever serves the trailing 30 days.
        for offset in stride(from: -40, through: 0, by: 1) {
            let day = calendar.date(byAdding: .day, value: offset, to: dayStart) ?? dayStart
            let kilograms = 72.0 + Double(offset) * 0.1
            local.append(WeightLog(measuredAt: day.addingTimeInterval(0.456), kilograms: kilograms))
            if offset >= -29 {
                remotePoints.append(WeightTrendPoint(date: day, kilograms: kilograms))
            }
        }
        try await health.upsert(local)
        let remote = MockDashboardRepository(
            snapshot: DashboardSnapshot(
                date: dayStart, meals: [], goal: nil, weightTrend: remotePoints
            )
        )
        let repository = LocalFirstDashboardRepository(
            remote: remote,
            store: try LocalDataStore(databaseURL: url),
            snapshotCache: try LocalSnapshotCache(databaseURL: url),
            healthStore: health
        )

        let snapshot = try await repository.loadToday(userID: account, date: dayStart)

        XCTAssertEqual(
            snapshot.weightTrend.count, 30,
            "30 daily samples in the trailing 30-day window must yield 30 points "
                + "(older local rows never paint into the window)"
        )
        XCTAssertEqual(snapshot.weightTrend.last?.kilograms, 72.0, "today's sample is the newest point")
    }
}

// MARK: - Fakes

/// Read prompt NOT answered (getRequestStatusForAuthorization ==
/// .shouldRequest) and every query returns an empty result with no error —
/// the exact iOS shape for a denied/unanswered read.
private final class ReadDeniedReader: WeightSampleReading {
    func requestAuthorization() async throws {}

    func samples(since: Date?) async throws -> [WeightLog] { [] }

    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] { [] }

    func authorizationStatus(for kind: HealthKitObserverKind) -> Bool { false }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {}

    func stopObserving() {}
}

/// Read prompt answered; body-mass queries return nothing; energy returns
/// one day (the energy-only sync scenario).
private final class EnergyOnlyReader: WeightSampleReading {
    let energyLogs: [EnergyBurnedLog]

    init(energyLogs: [EnergyBurnedLog]) {
        self.energyLogs = energyLogs
    }

    func requestAuthorization() async throws {}

    func samples(since: Date?) async throws -> [WeightLog] { [] }

    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] { energyLogs }

    func authorizationStatus(for kind: HealthKitObserverKind) -> Bool { true }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {}

    func stopObserving() {}
}
#endif

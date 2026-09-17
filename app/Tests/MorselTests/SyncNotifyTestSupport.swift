import Foundation
import HealthKit
import XCTest
@testable import Morsel

// Issue #189 — shared fixtures for the sync-notification witnesses: the REAL
// account-scoped SQLite outbox/Health stores and the local-first facade, with
// only the two remote boundaries scripted. Every pass is driven through the
// shipped `LocalSyncEngine`, and the hook under test is installed with the
// same route `MorselApp`'s `.task` uses (journal day re-read + Health status).

/// One account's scratch root plus the store connections the app opens for it.
/// Main-actor bound: it builds the view models the shipped hook drives.
@MainActor
final class SyncNotifyStores {
    let account = UUID()
    private let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("morsel-189-sync-notify-\(UUID().uuidString)", isDirectory: true)
    }

    func createRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func removeRoot() {
        try? FileManager.default.removeItem(at: root)
    }

    var databaseURL: URL { LocalDataStore.storeURL(root: root, accountID: account) }

    /// A fresh connection over the SAME account file (the restart shape the
    /// first-paint witnesses use, so nothing is proved from process memory).
    func store() throws -> LocalDataStore { try LocalDataStore(databaseURL: databaseURL) }
    func health() throws -> LocalHealthStore { try LocalHealthStore(databaseURL: databaseURL) }
    func cache() throws -> LocalSnapshotCache { try LocalSnapshotCache(databaseURL: databaseURL) }

    /// The production facade over this account's file. No sync request: these
    /// witnesses drive `runPass()` themselves.
    func repository(remote: any DashboardRepository) throws -> LocalFirstDashboardRepository {
        LocalFirstDashboardRepository(
            remote: remote, store: try store(), snapshotCache: try cache(), healthStore: try health()
        )
    }

    /// The engine exactly as `AccountReliabilityServices` builds it.
    func engine(
        mealRemote: RemoteMealWriting?,
        healthRemote: WeightLogStore?,
        now: @escaping () -> Date = Date.init
    ) throws -> LocalSyncEngine {
        LocalSyncEngine(
            userID: account, store: try store(), healthStore: try health(),
            mealRemote: mealRemote, healthRemote: healthRemote, now: now
        )
    }

    /// The calm-status derivation needs an importer (read decision + per-type
    /// upload marks); the scripted reader answers "decided" and imports nothing.
    func viewModel(
        repository: any DashboardRepository, healthStore: LocalHealthStore, date: Date
    ) throws -> DashboardViewModel {
        DashboardViewModel(
            repository: repository, userID: account,
            weightImporter: try HealthKitWeightImporter(reader: SyncNotifyReader(), store: healthStore),
            healthStore: healthStore, dateProvider: { date }
        )
    }

    /// Installs the shipped hook shape and records every event it receives.
    /// The event is recorded BEFORE the model guard, so a witness never
    /// depends on the model outliving the installation call.
    func reconcile(
        _ engine: LocalSyncEngine, model: DashboardViewModel, into events: SyncNotifyEvents
    ) async {
        await engine.startReconciling { [weak model] change in
            events.record(change)
            guard let model else { return }
            if change.changesJournal { await model.invalidateDay() }
            if change.changesHealthStatus { await model.refreshHealthCalmStatus() }
        }
    }
}

/// Ordered record of the reconciliation events one owner received.
@MainActor
final class SyncNotifyEvents {
    private(set) var changes: [SyncPassChange] = []
    var count: Int { changes.count }
    func record(_ change: SyncPassChange) { changes.append(change) }

    /// Nil (never a crash) when the owner received fewer events than expected,
    /// so a regression reports its assertions instead of an index fault.
    func change(at index: Int) -> SyncPassChange? {
        changes.indices.contains(index) ? changes[index] : nil
    }
}

/// Meal writer with a scripted outcome: nil commits and reads back the
/// authoritative result; a refusal is thrown for every attempt.
final class SyncNotifyMealWriter: RemoteMealWriting {
    var refusal: MealDeliveryError?
    private(set) var committedMealIDs: [UUID] = []
    private(set) var uploadedObjectPaths: [String] = []

    func uploadMealPhoto(userID: UUID, mealID: UUID, photo: QueuedMealPhoto) async throws -> String {
        let path = FoodImageStore.bucketPath(userID: userID, imageID: mealID)
        uploadedObjectPaths.append(path)
        return path
    }

    func commitMeal(userID: UUID, meal: QueuedMeal, imagePath: String?) async throws {
        if let refusal { throw refusal }
        committedMealIDs.append(meal.mealID)
    }

    func removeRemotePhoto(userID: UUID, bucketPath: String) async throws {}
}

/// Health remote that records each per-type push and can fail as a whole
/// (the offline shape: both upserts throw, nothing is marked uploaded).
final class SyncNotifyHealthRemote: WeightLogStore {
    var isFailing = false
    private(set) var weightPushes: [[WeightLog]] = []
    private(set) var energyPushes: [[EnergyBurnedLog]] = []

    func upsert(_ logs: [WeightLog]) async throws {
        if isFailing { throw URLError(.notConnectedToInternet) }
        weightPushes.append(logs)
    }

    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws {
        if isFailing { throw URLError(.notConnectedToInternet) }
        energyPushes.append(logs)
    }
}

/// Read prompt answered; the import supplies nothing (these witnesses stage
/// the durable rows directly in the account's SQLite file).
final class SyncNotifyReader: WeightSampleReading {
    func requestAuthorization() async throws {}
    func samples(since: Date?) async throws -> [WeightLog] { [] }
    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] { [] }
    func authorizationStatus(for kind: HealthKitObserverKind) async -> Bool { true }
    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {}
    func stopObserving() {}
}

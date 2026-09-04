import Foundation
import Supabase

// Issue #106 — account-scoped reliability services assembled once per
// authenticated session: per-account SQLite stores (isolation by file),
// the local-first repository facade, the single-flight sync engine and the
// local-first Health importer. Sign-out clears/shuts everything down; a new
// account starts from its own empty store (no cross-account leak of meals,
// goals, weight, energy, photos or sync metadata by construction).
enum LocalAppData {
    /// Application Support/Morsel — the account directories live under it.
    static func rootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Morsel", isDirectory: true) ?? FileManager.default.temporaryDirectory
    }

    static func removeAccountData(accountID: UUID) {
        let directory = LocalDataStore.storeDirectory(root: rootDirectory(), accountID: accountID)
        try? FileManager.default.removeItem(at: directory)
    }
}

final class AccountReliabilityServices {
    let userID: UUID
    let store: LocalDataStore
    let snapshotCache: LocalSnapshotCache
    let healthStore: LocalHealthStore
    let engine: LocalSyncEngine
    let repository: any DashboardRepository
    let importer: HealthKitWeightImporter?

    init?(client: SupabaseClient?, userID: UUID) {
        let directory = LocalDataStore.storeDirectory(root: LocalAppData.rootDirectory(), accountID: userID)
        let url = LocalDataStore.storeURL(root: LocalAppData.rootDirectory(), accountID: userID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try LocalDataStore(databaseURL: url)
            snapshotCache = try LocalSnapshotCache(databaseURL: url)
            healthStore = try LocalHealthStore(databaseURL: url)
        } catch {
            return nil
        }
        self.userID = userID
        let remote = SupabaseDashboardRepository(client: client)
        let remoteWriter = client.map { SupabaseDashboardRepository(client: $0) }
        let remoteHealth = client.map { SupabaseWeightLogStore(client: $0, userID: userID) }
        let engine = LocalSyncEngine(
            userID: userID,
            store: store,
            healthStore: healthStore,
            mealRemote: remoteWriter,
            healthRemote: remoteHealth
        )
        self.engine = engine
        repository = LocalFirstDashboardRepository(
            remote: remote,
            store: store,
            snapshotCache: snapshotCache,
            healthStore: healthStore,
            requestSync: { engine.syncNow() }
        )
        importer = try? HealthKitWeightImporter(store: healthStore)
    }

    /// Sign-out / account switch: cancel this account's worker and wipe its
    /// store so the next account can never read prior rows.
    func shutdownAndClear() {
        engine.shutdown()
        LocalAppData.removeAccountData(accountID: userID)
    }
}

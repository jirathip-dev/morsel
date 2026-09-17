import Combine
import Foundation
import XCTest
@testable import Morsel

// Issue #181 — shared fixtures for the cached-Today first-paint witnesses.
// Every phase opens FRESH store/cache/Health connections over the same
// per-account SQLite file, so the "restart" in these tests throws all process
// memory away and proves a painted row came from durable local state.

/// One account pair's scratch root and the account-scoped database files.
final class FirstPaintStores {
    let account: UUID
    let otherAccount: UUID
    private let root: URL

    init() {
        account = UUID()
        otherAccount = UUID()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("morsel-181-first-paint-\(UUID().uuidString)", isDirectory: true)
    }

    func createRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func removeRoot() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Fresh connections over ONE account's durable file: the outbox, the
    /// snapshot cache and the Health store share the same per-account database.
    struct Instances {
        let store: LocalDataStore
        let cache: LocalSnapshotCache
        let health: LocalHealthStore
    }

    func instances(for accountID: UUID? = nil) throws -> Instances {
        let database = LocalDataStore.storeURL(root: root, accountID: accountID ?? account)
        return Instances(
            store: try LocalDataStore(databaseURL: database),
            cache: try LocalSnapshotCache(databaseURL: database),
            health: try LocalHealthStore(databaseURL: database)
        )
    }

    func makeRepository(
        remote: any DashboardRepository, instances: Instances
    ) -> LocalFirstDashboardRepository {
        LocalFirstDashboardRepository(
            remote: remote, store: instances.store, snapshotCache: instances.cache,
            healthStore: instances.health
        )
    }
}

/// The durable rows a queued-only / cached first paint must carry, plus the
/// facade rebuilt over the same file with every read blocked.
struct QueuedFirstPaintDay {
    let account: UUID
    let instances: FirstPaintStores.Instances
    let remote: FirstPaintRemote
    let repository: LocalFirstDashboardRepository
    /// nil when the day was deliberately left WITHOUT a dashboard cache.
    let remoteMealID: UUID?
    let photoMealID: UUID
    let refusedMealID: UUID
    let photoBytes: Data

    var photoPath: String {
        FoodImageStore.objectPath(userID: account, imageID: photoMealID)
    }
}

extension FirstPaintStores {
    /// Seeds the day through the authoritative read (which writes the cache
    /// through), then queues a photo meal and a refused (needs-attention)
    /// non-photo meal, then rebuilds every connection and BLOCKS the network.
    /// `cachedDay: false` skips the seed so the outbox is the only source.
    func queuedFirstPaintDay(
        day: Date, reference: Date, cachedDay: Bool = true
    ) async throws -> QueuedFirstPaintDay {
        let opened = try instances()
        var remoteMealID: UUID?
        if cachedDay {
            let seededID = UUID()
            remoteMealID = seededID
            let server = FirstPaintRemote(snapshot: DashboardSnapshot(
                date: day, meals: [FirstPaintFixture.meal(id: seededID, at: day.addingTimeInterval(8 * 3_600))],
                goal: nil
            ))
            _ = try await makeRepository(remote: server, instances: opened)
                .loadToday(userID: account, date: reference)
        }
        let seeding = makeRepository(
            remote: FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil)),
            instances: opened
        )
        let photoBytes = Data([0x10, 0x20, 0x30])
        let photoMealID = try await seeding.logMeal(
            userID: account,
            draft: FirstPaintFixture.draft(eatenAt: day.addingTimeInterval(12 * 3_600)),
            photo: FoodImageUpload(data: photoBytes, mimeType: "image/jpeg")
        )
        let refusedMealID = try await seeding.logMeal(
            userID: account,
            draft: FirstPaintFixture.draft(eatenAt: day.addingTimeInterval(18 * 3_600)),
            photo: nil
        )
        try opened.store.recordMealAttempt(mealID: refusedMealID, error: .validation)

        let reopened = try instances()
        let blocked = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        blocked.isBlocked = true
        return QueuedFirstPaintDay(
            account: account, instances: reopened, remote: blocked,
            repository: makeRepository(remote: blocked, instances: reopened),
            remoteMealID: remoteMealID, photoMealID: photoMealID, refusedMealID: refusedMealID,
            photoBytes: photoBytes
        )
    }
}

/// One scripted authoritative day that can be switched OFF (every read fails:
/// the blocked network the acceptance criteria demand) and ON again to stage a
/// later authoritative reconciliation.
final class FirstPaintRemote: DashboardRepository {
    var snapshot: DashboardSnapshot
    var isBlocked = false
    var remoteImage = Data([0xFA, 0xCE])
    private(set) var dayReads = 0

    init(snapshot: DashboardSnapshot) {
        self.snapshot = snapshot
    }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        dayReads += 1
        guard !isBlocked else { throw URLError(.notConnectedToInternet) }
        return snapshot
    }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        guard !isBlocked else { throw URLError(.notConnectedToInternet) }
        return HistoryOverview(days: [], goal: nil)
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {
        guard !isBlocked else { throw URLError(.notConnectedToInternet) }
    }

    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {
        guard !isBlocked else { throw URLError(.notConnectedToInternet) }
    }

    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {
        guard !isBlocked else { throw URLError(.notConnectedToInternet) }
    }

    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        guard !isBlocked else { throw URLError(.notConnectedToInternet) }
        return UUID()
    }

    func loadMealImage(userID: UUID, path: String) async throws -> Data {
        guard !isBlocked else { throw URLError(.notConnectedToInternet) }
        return remoteImage
    }

    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? {
        guard !isBlocked else { throw URLError(.notConnectedToInternet) }
        return nil
    }

    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        guard !isBlocked else { throw URLError(.notConnectedToInternet) }
        return DashboardGoal(
            calorieTargetKcal: 2_000, proteinG: 100, carbsG: 250, fatG: 55, source: .computed
        )
    }

    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {
        guard !isBlocked else { throw URLError(.notConnectedToInternet) }
    }
}

/// A sync-engine writer whose pass always commits and reads back: the
/// successful reconciliation that releases a queued row.
final class CommittingMealWriter: RemoteMealWriting {
    private(set) var committed: [UUID: QueuedMeal] = [:]
    private(set) var uploadedPaths: [String] = []

    func uploadMealPhoto(userID: UUID, mealID: UUID, photo: QueuedMealPhoto) async throws -> String {
        let path = FoodImageStore.bucketPath(userID: userID, imageID: mealID)
        uploadedPaths.append(path)
        return path
    }

    func commitMeal(userID: UUID, meal: QueuedMeal, imagePath: String?) async throws {
        committed[meal.mealID] = meal
    }

    func removeRemotePhoto(userID: UUID, bucketPath: String) async throws {}
}

/// Captures every non-nil dashboard the model publishes, in publish order: the
/// first element IS the model's first paint.
@MainActor
final class FirstPaintRecorder {
    private var cancellable: AnyCancellable?
    private(set) var paints: [DashboardSnapshot] = []

    init(model: DashboardViewModel) {
        cancellable = model.$snapshot.sink { [weak self] snapshot in
            guard let snapshot else { return }
            self?.paints.append(snapshot)
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}

/// Fixture builders shared by the first-paint witnesses.
enum FirstPaintFixture {
    static func draft(eatenAt: Date, type: MealType = .dinner, name: String = "rice") -> MealDraft {
        MealDraft(
            mealType: type, eatenAt: eatenAt,
            items: [MealItemDraft(name: name, quantity: 1, unit: .cup, caloriesKcal: 200, proteinG: 4)]
        )
    }

    static func meal(
        id: UUID, at eatenAt: Date, type: MealType = .lunch, name: String = "remote bowl",
        imagePath: String? = nil
    ) -> MealRecord {
        MealRecord(
            mealLogID: id, mealType: type, eatenAt: eatenAt, source: .manual,
            imagePath: imagePath, image: imagePath.map { MealImage(path: $0) },
            items: [MealItem(
                itemID: UUID(), name: name, quantity: 1, unit: .cup, caloriesKcal: 300,
                proteinG: 6, carbsG: 40, fatG: 5, fiberG: 2, sugarG: 1, confidence: 0.9, notes: nil
            )]
        )
    }

    /// The cached paint the refresh owner publishes first, when there is one.
    static func cachedPaint(_ event: TodayRefreshOwner.Event) -> DashboardSnapshot? {
        if case .cached(let snapshot) = event { return snapshot }
        return nil
    }
}

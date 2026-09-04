import XCTest
@testable import Morsel
// Issue #106 — meal save reliability behind the local-first repository:
// durable offline save with an honest pending marker, cached-first paint,
// cache preservation on remote failure, duplicate-safe retries (timeout
// after server commit), photo retry without orphan/duplicate, permanent
// auth/validation refusals → preserved needs-attention rows, and pending
// delete cancelling the outbox before the server ever sees it.
@MainActor
final class MealReliabilityTests: XCTestCase {
    // New XCTestCase instance per test method: UUID-scoped identity + scratch
    // directory are unique per test without implicitly unwrapped optionals.
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-meal-tests-\(UUID().uuidString)", isDirectory: true)
    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }
    private var databaseURL: URL {
        LocalDataStore.storeURL(root: directory, accountID: account)
    }
    private func makeStores() throws -> (LocalDataStore, LocalSnapshotCache) {
        (try LocalDataStore(databaseURL: databaseURL), try LocalSnapshotCache(databaseURL: databaseURL))
    }
    private func makeRepository(
        remote: any DashboardRepository,
        store: LocalDataStore,
        cache: LocalSnapshotCache
    ) -> LocalFirstDashboardRepository {
        LocalFirstDashboardRepository(remote: remote, store: store, snapshotCache: cache)
    }
    private func draft(eatenAt: Date = Date(timeIntervalSince1970: 60)) -> MealDraft {
        MealDraft(
            mealType: .dinner,
            eatenAt: eatenAt,
            notes: nil,
            items: [MealItemDraft(name: "rice", quantity: 1, unit: .cup,
                                  caloriesKcal: 200, proteinG: 4)]
        )
    }
    private func remoteSnapshot(meals: [MealRecord] = []) -> DashboardSnapshot {
        DashboardSnapshot(
            date: DashboardMath.startOfUTCDay(Date(timeIntervalSince1970: 60)),
            meals: meals,
            goal: nil
        )
    }
    // MARK: - Offline durability + honest state
    func testOfflineAddMealCommitsLocallyAndPaintsPendingRow() async throws {
        let (store, cache) = try makeStores()
        let offline = AlwaysOfflineRepository()
        let repository = makeRepository(remote: offline, store: store, cache: cache)
        let viewModel = DashboardViewModel(
            repository: repository,
            userID: account,
            dateProvider: { Date(timeIntervalSince1970: 60) }
        )
        let upload = FoodImageUpload(data: Data([0x01, 0x02]), mimeType: "image/jpeg")
        let didSave = await viewModel.addMeal(draft: draft(), photo: upload)
        XCTAssertTrue(didSave, "a durable local commit must not be reported as a failed save")
        XCTAssertNil(viewModel.errorMessage)
        let mealID = try XCTUnwrap(try store.queuedMeals().first).mealID
        let direct = try await repository.localMealRecord(userID: account, localMealID: mealID)
        XCTAssertNotNil(direct, "the queued record must be readable right after the local commit")
        let visible = try XCTUnwrap(viewModel.snapshot?.meals.first)
        XCTAssertEqual(visible.items.first?.name, "rice")
        XCTAssertEqual(visible.syncState, .pending, "queued rows carry an honest pending marker")
        XCTAssertEqual(MealSyncState.pending.rowCopy, "pending sync")
        let stored = try XCTUnwrap(try store.queuedMeal(mealID: visible.mealLogID))
        XCTAssertEqual(stored.photo?.data, upload.data, "photo payload rides the same local commit")
    }

    func testRelaunchRecoveryKeepsQueuedMealAndShowsNeedsAttentionAfterRefusal() async throws {
        let (store, _) = try makeStores()
        let repository = makeRepository(remote: AlwaysOfflineRepository(), store: store,
                                        cache: try LocalSnapshotCache(databaseURL: databaseURL))
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: nil)
        try store.recordMealAttempt(mealID: mealID, error: .validation)

        // Relaunch: fresh store instances over the same file.
        let (store2, cache2) = try makeStores()
        let repository2 = makeRepository(remote: AlwaysOfflineRepository(), store: store2, cache: cache2)
        let reopened = try await repository2.localMealRecord(userID: account, localMealID: mealID)
        let row = try XCTUnwrap(reopened)
        XCTAssertEqual(row.syncState, .needsAttention)
        XCTAssertEqual(MealSyncState.needsAttention.rowCopy, "needs attention")
    }

    // MARK: - Cache-first reads

    func testCachedFirstPaintDoesNotTouchNetwork() async throws {
        let (store, cache) = try makeStores()
        let remote = ScriptedRemoteRepository(snapshot: remoteSnapshot())
        let repository = makeRepository(remote: remote, store: store, cache: cache)

        _ = try await repository.loadToday(userID: account, date: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(remote.loadCount, 1, "first read writes the cache through")

        let cached = try await repository.cachedToday(userID: account, date: Date(timeIntervalSince1970: 60))
        XCTAssertNotNil(cached)
        XCTAssertEqual(remote.loadCount, 1, "cached reads never touch the network")
    }

    func testRemoteFailureNeverErasesValidCachedSnapshot() async throws {
        let (store, cache) = try makeStores()
        let remote = ScriptedRemoteRepository(snapshot: remoteSnapshot())
        let repository = makeRepository(remote: remote, store: store, cache: cache)

        _ = try await repository.loadToday(userID: account, date: Date(timeIntervalSince1970: 60))
        remote.failAll = true

        let second = try await repository.loadToday(userID: account, date: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(second.meals.count, 0, "cached snapshot survives the remote failure")
        XCTAssertEqual(second.date, DashboardMath.startOfUTCDay(Date(timeIntervalSince1970: 60)))
        let stillCached = try await repository.cachedToday(userID: account, date: Date(timeIntervalSince1970: 60))
        XCTAssertNotNil(stillCached, "the failed refresh must not erase the cache")
    }

    func testWarmViewModelPaintUsesCacheBeforeRemote() async throws {
        let (store, cache) = try makeStores()
        let remote = ScriptedRemoteRepository(snapshot: remoteSnapshot())
        let repository = makeRepository(remote: remote, store: store, cache: cache)
        _ = try await repository.loadToday(userID: account, date: Date(timeIntervalSince1970: 60))
        remote.failAll = true

        let viewModel = DashboardViewModel(
            repository: repository,
            userID: account,
            dateProvider: { Date(timeIntervalSince1970: 60) }
        )
        await viewModel.load()

        XCTAssertNotNil(viewModel.snapshot)
        XCTAssertEqual(viewModel.snapshot?.date, DashboardMath.startOfUTCDay(Date(timeIntervalSince1970: 60)))
    }

    // MARK: - Duplicate-safe retries (server conflict guard)

    func testTimeoutAfterServerCommitRetriesSameClientIDWithoutDuplicates() async throws {
        let (store, cache) = try makeStores()
        let writer = ScriptedRemoteWriter()
        writer.timeoutAfterCommit = 1 // first RPC commits server-side then "times out"
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = makeRepository(remote: AlwaysOfflineRepository(), store: store, cache: cache)

        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: nil)
        await engine.runPass()
        XCTAssertEqual(writer.insertCalls.count, 1, "first attempt committed on the server")
        XCTAssertEqual(try store.queuedMeals().count, 1, "response lost → row stays queued")

        await engine.runPass()
        XCTAssertEqual(writer.insertCalls.count, 1, "retry never inserts a second meal")
        XCTAssertEqual(writer.committedMeals.count, 1)
        XCTAssertEqual(writer.committedMeals.keys.first, mealID)
        XCTAssertTrue(try store.queuedMeals().isEmpty, "authoritative result read back → row removed")
    }

    func testRepeatedTransientFailuresThenSuccessSingleInsert() async throws {
        let (store, _) = try makeStores()
        let writer = ScriptedRemoteWriter()
        writer.failNextCommits = 2
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = makeRepository(remote: AlwaysOfflineRepository(), store: store,
                                        cache: try LocalSnapshotCache(databaseURL: databaseURL))
        _ = try await repository.logMeal(userID: account, draft: draft(), photo: nil)

        await engine.runPass()
        await engine.runPass()
        let row = try XCTUnwrap(try store.queuedMeals().first)
        XCTAssertEqual(row.attempts, 2)
        XCTAssertEqual(row.state, .pending, "transient failures stay retryable")

        await engine.runPass()
        XCTAssertEqual(writer.insertCalls.count, 1)
        XCTAssertTrue(try store.queuedMeals().isEmpty)
    }

    func testDoubleSyncNowNeverDuplicates() async throws {
        let (store, _) = try makeStores()
        let writer = ScriptedRemoteWriter()
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = makeRepository(remote: AlwaysOfflineRepository(), store: store,
                                        cache: try LocalSnapshotCache(databaseURL: databaseURL))
        _ = try await repository.logMeal(userID: account, draft: draft(), photo: nil)

        engine.syncNow()
        engine.syncNow()
        let drained = expectation(description: "engine drains")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(writer.insertCalls.count, 1, "single-flight + client id must never duplicate")
    }

    // MARK: - Photo reliability

    func testPhotoUploadFailureRetriesSameDeterministicObject() async throws {
        let (store, cache) = try makeStores()
        let writer = ScriptedRemoteWriter()
        writer.failNextUploads = 1
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = makeRepository(remote: AlwaysOfflineRepository(), store: store, cache: cache)
        let photo = FoodImageUpload(data: Data([0x10, 0x20]), mimeType: "image/jpeg")
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: photo)

        await engine.runPass()
        XCTAssertTrue(writer.uploadedPaths.isEmpty)
        XCTAssertEqual(try store.queuedMeal(mealID: mealID)?.photo?.data, photo.data)

        await engine.runPass()
        XCTAssertEqual(writer.uploadedPaths.count, 1, "retry uploads the same meal photo once")
        XCTAssertEqual(writer.uploadedPaths.first, FoodImageStore.bucketPath(userID: account, imageID: mealID))
        XCTAssertEqual(
            writer.commitImagePaths[mealID], writer.uploadedPaths.first,
            "the committed meal row always carries its uploaded photo path"
        )
        XCTAssertTrue(try store.queuedMeals().isEmpty)
    }

    func testPermanentRefusalRemovesOrphanPhotoAndKeepsLocalData() async throws {
        let (store, _) = try makeStores()
        let writer = ScriptedRemoteWriter()
        writer.commitError = MealDeliveryError.permanent(.auth)
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = makeRepository(remote: AlwaysOfflineRepository(), store: store,
                                        cache: try LocalSnapshotCache(databaseURL: databaseURL))
        let photo = FoodImageUpload(data: Data([0x01]), mimeType: "image/jpeg")
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: photo)

        await engine.runPass()

        XCTAssertEqual(writer.removedPaths.count, 1, "no orphaned photo behind a rejected meal")
        XCTAssertEqual(try store.queuedMeal(mealID: mealID)?.state, .needsAttention)
        XCTAssertEqual(try store.queuedMeal(mealID: mealID)?.lastErrorCategory, .auth)
        XCTAssertEqual(try store.queuedMeal(mealID: mealID)?.photo?.data, photo.data,
                       "recoverable payload is preserved for the visible needs-attention state")
    }

    // MARK: - Local deletes + edits of queued rows

    func testDeletingPendingMealCancelsOutboxWithoutNetwork() async throws {
        let (store, cache) = try makeStores()
        let remote = AlwaysOfflineRepository()
        let repository = makeRepository(remote: remote, store: store, cache: cache)
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: nil)

        try await repository.deleteMealLog(userID: account, mealLogID: mealID)

        XCTAssertTrue(try store.queuedMeals().isEmpty)
    }

    func testEditingQueuedItemMutatesLocalDraftOnly() async throws {
        let (store, cache) = try makeStores()
        let remote = ScriptedRemoteRepository(snapshot: remoteSnapshot())
        let repository = makeRepository(remote: remote, store: store, cache: cache)
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: nil)
        let itemID = try XCTUnwrap(try store.queuedMeal(mealID: mealID)?.items.first?.itemID)

        try await repository.updateMealItem(
            userID: account,
            update: MealItemUpdate(itemID: itemID, name: "brown rice", source: .manualEdit)
        )

        let row = try XCTUnwrap(try store.queuedMeal(mealID: mealID))
        XCTAssertEqual(row.items.first?.name, "brown rice")
    }

    func testPendingRowsMergeIntoServedSnapshotWithoutDuplication() async throws {
        let (store, cache) = try makeStores()
        let remote = ScriptedRemoteRepository(snapshot: remoteSnapshot())
        let repository = makeRepository(remote: remote, store: store, cache: cache)
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: nil)

        let snapshot = try await repository.loadToday(userID: account, date: Date(timeIntervalSince1970: 60))
        let matching = snapshot.meals.filter { $0.mealLogID == mealID }
        XCTAssertEqual(matching.count, 1, "queued row merges exactly once")
        XCTAssertEqual(matching.first?.syncState, .pending)
    }
}

// MARK: - Fakes

private final class AlwaysOfflineRepository: DashboardRepository {
    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        throw URLError(.notConnectedToInternet)
    }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        throw URLError(.notConnectedToInternet)
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {
        throw URLError(.notConnectedToInternet)
    }

    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {
        throw URLError(.notConnectedToInternet)
    }

    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {
        throw URLError(.notConnectedToInternet)
    }

    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        throw URLError(.notConnectedToInternet)
    }

    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        throw URLError(.notConnectedToInternet)
    }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {
        throw URLError(.notConnectedToInternet)
    }
}

/// Scriptable remote dashboard (cache tests).
private final class ScriptedRemoteRepository: DashboardRepository {
    let snapshot: DashboardSnapshot
    var failAll = false
    private(set) var loadCount = 0

    init(snapshot: DashboardSnapshot) {
        self.snapshot = snapshot
    }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        loadCount += 1
        if failAll { throw URLError(.timedOut) }
        return snapshot
    }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        HistoryOverview(days: [], goal: nil)
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID { UUID() }
    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        DashboardGoal(calorieTargetKcal: 2_000, proteinG: 100, carbsG: 250, fatG: 55, source: .computed)
    }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
}

private final class ScriptedRemoteWriter: RemoteMealWriting {
    private(set) var committedMeals: [UUID: QueuedMeal] = [:]
    private(set) var insertCalls: [UUID] = []
    private(set) var uploadedPaths: [String] = []
    private(set) var removedPaths: [String] = []
    var commitError: Error?
    var failNextCommits = 0
    var timeoutAfterCommit = 0
    var failNextUploads = 0
    private(set) var commitImagePaths: [UUID: String] = [:]

    func uploadMealPhoto(userID: UUID, mealID: UUID, photo: QueuedMealPhoto) async throws -> String {
        if failNextUploads > 0 {
            failNextUploads -= 1
            throw URLError(.timedOut)
        }
        let path = FoodImageStore.bucketPath(userID: userID, imageID: mealID)
        uploadedPaths.append(path)
        return path
    }

    func commitMeal(userID: UUID, meal: QueuedMeal, imagePath: String?) async throws {
        commitImagePaths[meal.mealID] = imagePath
        if let commitError {
            throw commitError
        }
        if timeoutAfterCommit > 0 {
            timeoutAfterCommit -= 1
            // Server commit lands, then the response is lost (timeout).
            committedMeals[meal.mealID] = meal
            insertCalls.append(meal.mealID)
            throw URLError(.timedOut)
        }
        if failNextCommits > 0 {
            failNextCommits -= 1
            throw URLError(.notConnectedToInternet)
        }
        if committedMeals[meal.mealID] == nil {
            committedMeals[meal.mealID] = meal
            insertCalls.append(meal.mealID)
        }
    }

    func removeRemotePhoto(userID: UUID, bucketPath: String) async throws {
        removedPaths.append(bucketPath)
    }
}

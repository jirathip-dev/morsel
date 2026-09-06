import XCTest
@testable import Morsel

// Issue #153 — attach/replace a photo from the Edit-item flow. Meal photos
// are meal-level (meal_logs.image_path, canonical {user_id}/{meal_id}.jpg),
// so the attach targets the ITEM's parent meal through the SAME durable
// outbox/image pipeline as Add Meal — never a direct storage write:
//  1. A QUEUED meal (pending/needs-attention) keeps the photo in its outbox
//     row: attach replaces the payload, clears a refused upload's stale
//     path/error, resets needs-attention to honest pending sync, and the
//     journal record + local-blob thumbnail pipeline render it immediately.
//  2. The replaced photo uploads at the meal's deterministic canonical
//     object path and the commit carries that path (idempotent retry).
//  3. A SYNCED meal delegates to the authenticated remote attach seam (the
//     ownership-guarded deterministic upload + meal_logs.image_path update)
//     exactly like item edits route through the remote.
//  4. Attach validates the photo BEFORE any durable write (no partial rows).
@MainActor
final class PhotoAttachOnEditRegressionTests: XCTestCase {
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-photo-edit-tests-\\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL {
        LocalDataStore.storeURL(root: directory, accountID: account)
    }

    private func stores() throws -> (LocalDataStore, LocalSnapshotCache) {
        (try LocalDataStore(databaseURL: databaseURL), try LocalSnapshotCache(databaseURL: databaseURL))
    }

    private func draft() -> MealDraft {
        MealDraft(
            mealType: .lunch,
            eatenAt: Date(timeIntervalSince1970: 60),
            notes: nil,
            items: [MealItemDraft(name: "sushi", quantity: 1, unit: .serving)]
        )
    }

    private func upload(bytes: UInt8 = 0xAA) -> FoodImageUpload {
        FoodImageUpload(data: Data([bytes, 0xBB, 0xCC]), mimeType: "image/jpeg")
    }

    private func offlineRepository() -> OfflineAttachRemote {
        OfflineAttachRemote()
    }

    // MARK: - Queued meal: replace photo, honest pending, local render

    func testAttachToRefusedQueuedMealReplacesPhotoAndResetsToPending() async throws {
        let (store, cache) = try stores()
        let writer = AttachScriptedWriter()
        writer.commitError = MealDeliveryError.permanent(.photo)
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = LocalFirstDashboardRepository(
            remote: offlineRepository(), store: store, snapshotCache: cache
        )
        let firstPhoto = upload(bytes: 0x10)
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: firstPhoto)
        let itemID = try XCTUnwrap(try store.queuedMeal(mealID: mealID)?.items.first?.itemID)
        await engine.runPass()

        let refused = try XCTUnwrap(try store.queuedMeal(mealID: mealID))
        XCTAssertEqual(refused.state, .needsAttention, "a permanent photo refusal surfaces needs-attention")
        XCTAssertEqual(refused.lastErrorCategory, .photo)

        let replacement = upload(bytes: 0x55)
        try await repository.attachMealPhoto(userID: account, itemID: itemID, photo: replacement)

        let row = try XCTUnwrap(try store.queuedMeal(mealID: mealID))
        XCTAssertEqual(row.state, .pending, "a fresh photo is honest pending sync again")
        XCTAssertNil(row.lastError)
        XCTAssertNil(row.lastErrorCategory)
        XCTAssertNil(row.imagePath, "the stale uploaded path is cleared so the new bytes upload")
        XCTAssertEqual(row.photo?.data, replacement.data, "the durable payload holds the replaced photo")

        let canonical = FoodImageStore.objectPath(userID: account, imageID: mealID)
        let storedRecord = try await repository.localMealRecord(userID: account, localMealID: mealID)
        let record = try XCTUnwrap(storedRecord)
        XCTAssertEqual(record.imagePath, canonical, "the queued row carries its deterministic canonical path")
        XCTAssertEqual(record.items.first?.mealImage?.path, canonical, "the edit sheet sees the meal photo context")
        XCTAssertEqual(record.syncState, .pending, "pending sync stays honest after the edit")

        let bytes = try await repository.loadMealImage(userID: account, path: canonical)
        XCTAssertEqual(bytes, replacement.data, "the replaced photo renders locally before any upload")
    }

    // MARK: - Outbox drain of a replaced queued photo

    func testAttachedQueuedPhotoDrainsAtCanonicalPath() async throws {
        let (store, cache) = try stores()
        let writer = AttachScriptedWriter()
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = LocalFirstDashboardRepository(
            remote: offlineRepository(), store: store, snapshotCache: cache
        )
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: nil)
        let itemID = try XCTUnwrap(try store.queuedMeal(mealID: mealID)?.items.first?.itemID)

        try await repository.attachMealPhoto(userID: account, itemID: itemID, photo: upload())
        await engine.runPass()

        XCTAssertTrue(try store.queuedMeals().isEmpty, "the attached photo meal drains after upload + commit")
        let canonical = FoodImageStore.objectPath(userID: account, imageID: mealID)
        XCTAssertEqual(writer.uploadedPaths, [canonical], "the attach uploads the deterministic canonical object")
        XCTAssertEqual(writer.commitImagePaths[mealID], canonical, "the commit carries the canonical image path")
    }

    // MARK: - Synced meal: authenticated remote seam

    func testAttachOnSyncedMealDelegatesToTheRemoteSeam() async throws {
        let (store, cache) = try stores()
        let mealID = UUID()
        let itemID = UUID()
        let remote = RecordingAttachRemote(snapshot: DashboardSnapshot(
            date: Date(timeIntervalSince1970: 60),
            meals: [MealRecord(
                mealLogID: mealID,
                mealType: .lunch,
                eatenAt: Date(timeIntervalSince1970: 60),
                source: .manual,
                imagePath: nil,
                items: [MealItem(
                    itemID: itemID, name: "sushi", quantity: 1, unit: .serving,
                    caloriesKcal: nil, proteinG: nil, carbsG: nil, fatG: nil,
                    fiberG: nil, sugarG: nil, confidence: 1, notes: nil
                )]
            )],
            goal: nil
        ))
        let repository = LocalFirstDashboardRepository(remote: remote, store: store, snapshotCache: cache)
        let photo = upload()

        try await repository.attachMealPhoto(userID: account, itemID: itemID, photo: photo)

        XCTAssertEqual(remote.attachments.count, 1, "synced meals route through the authenticated remote attach")
        XCTAssertEqual(remote.attachments.first?.itemID, itemID)
        XCTAssertEqual(remote.attachments.first?.photo, photo)
    }

    // MARK: - Validation before durable writes

    func testAttachValidatesPhotoBeforeTouchingTheQueuedRow() async throws {
        let (store, cache) = try stores()
        let repository = LocalFirstDashboardRepository(
            remote: offlineRepository(), store: store, snapshotCache: cache
        )
        let mealID = try await repository.logMeal(userID: account, draft: draft(), photo: nil)
        let itemID = try XCTUnwrap(try store.queuedMeal(mealID: mealID)?.items.first?.itemID)
        let invalid = FoodImageUpload(data: Data([0x01]), mimeType: "text/plain")

        do {
            try await repository.attachMealPhoto(userID: account, itemID: itemID, photo: invalid)
            XCTFail("an unsupported photo type must be refused")
        } catch let error as FoodImageError {
            XCTAssertEqual(error, .unsupportedMimeType)
        }

        let row = try XCTUnwrap(try store.queuedMeal(mealID: mealID))
        XCTAssertNil(row.photo, "no partial durable write on a refused photo")
        XCTAssertNil(row.imagePath)
        XCTAssertEqual(row.state, .pending)
    }

    // MARK: - View-model surface: queued photo edit stays pending-honest

    func testViewModelAttachKeepsQueuedRowHonestInTheJournalSnapshot() async throws {
        let (store, cache) = try stores()
        let remote = RecordingAttachRemote(snapshot: DashboardSnapshot(
            date: Date(timeIntervalSince1970: 60), meals: [], goal: nil
        ))
        let repository = LocalFirstDashboardRepository(remote: remote, store: store, snapshotCache: cache)
        let viewModel = DashboardViewModel(
            repository: repository,
            userID: account,
            dateProvider: { Date(timeIntervalSince1970: 60) }
        )
        let didSave = await viewModel.addMeal(draft: draft(), photo: nil)
        XCTAssertTrue(didSave)

        let itemID = try XCTUnwrap(
            viewModel.snapshot?.meals.first?.items.first?.itemID,
            "the queued meal paints in the journal immediately"
        )
        let didAttach = await viewModel.attachPhoto(upload(bytes: 0x33), toItem: itemID)
        XCTAssertTrue(didAttach)

        let meal = try XCTUnwrap(viewModel.snapshot?.meals.first)
        XCTAssertEqual(meal.syncState, .pending, "the edited queued row stays honest pending sync")
        XCTAssertEqual(
            meal.imagePath,
            FoodImageStore.objectPath(userID: account, imageID: meal.mealLogID),
            "the attached photo is journal-visible at its canonical path"
        )
    }
}

// MARK: - Fakes

/// Offline remote: every read/write throws a transport error.
private final class OfflineAttachRemote: DashboardRepository {
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

/// Remote serving one authoritative snapshot; records photo attaches.
private final class RecordingAttachRemote: DashboardRepository {
    let snapshot: DashboardSnapshot
    private(set) var attachments: [(itemID: UUID, photo: FoodImageUpload)] = []

    init(snapshot: DashboardSnapshot) {
        self.snapshot = snapshot
    }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot { snapshot }
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

    func attachMealPhoto(userID: UUID, itemID: UUID, photo: FoodImageUpload) async throws {
        attachments.append((itemID, photo))
    }
}

/// Scriptable outbox writer mirroring the production photo delivery seams.
private final class AttachScriptedWriter: RemoteMealWriting {
    private(set) var uploadedPaths: [String] = []
    private(set) var removedPaths: [String] = []
    private(set) var commitImagePaths: [UUID: String] = [:]
    var uploadError: Error?
    var commitError: Error?

    func uploadMealPhoto(userID: UUID, mealID: UUID, photo: QueuedMealPhoto) async throws -> String {
        if let uploadError {
            throw uploadError
        }
        let path = FoodImageStore.objectPath(userID: userID, imageID: mealID)
        uploadedPaths.append(path)
        return path
    }

    func commitMeal(userID: UUID, meal: QueuedMeal, imagePath: String?) async throws {
        commitImagePaths[meal.mealID] = imagePath
        if let commitError {
            throw commitError
        }
    }

    func removeRemotePhoto(userID: UUID, bucketPath: String) async throws {
        removedPaths.append(bucketPath)
    }
}

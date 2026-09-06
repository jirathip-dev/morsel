import XCTest
@testable import Morsel

// Issue #135 — photo-pipeline regression tests. The reported device defect:
// a photo meal stuck on the green 'pending sync' badge with 0 kcal and no
// thumbnail anywhere. These tests pin the app-side data-path fixes:
//  1. The CANONICAL #133 image path (`{user_id}/{meal_id}.jpg`) is accepted
//     by the app's photo path validation and downloads — server-logged photo
//     meals were rejected as invalid before this fix (no thumbnail).
//  2. A permanent photo-upload refusal surfaces the friendly needs-attention
//     state instead of a silent transient retry loop (the old catch-all kept
//     photo meals green-pending forever).
//  3. A permanent commit refusal (photo/server category) also moves the row
//     to needs-attention with the recoverable payload preserved.
//  4. A queued photo meal's journal record carries its deterministic
//     canonical path and its photo bytes render from the local store
//     immediately (online or offline).
//  5. The outbox drain (upload + commit) uses the canonical object path and
//     clears the row once the server commit is authoritative.
@MainActor
final class PhotoPipelineRegressionTests: XCTestCase {
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-photo-pipeline-tests-\(UUID().uuidString)", isDirectory: true)

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

    private func photoDraft(eatenAt: Date = Date(timeIntervalSince1970: 60)) -> MealDraft {
        MealDraft(
            mealType: .lunch,
            eatenAt: eatenAt,
            notes: nil,
            items: [MealItemDraft(name: "sushi", quantity: 1, unit: .serving)]
        )
    }

    private func upload() -> FoodImageUpload {
        FoodImageUpload(data: Data([0xAA, 0xBB, 0xCC]), mimeType: "image/jpeg")
    }

    private func emptySnapshot() -> DashboardSnapshot {
        DashboardSnapshot(date: Date(timeIntervalSince1970: 60), meals: [], goal: nil)
    }

    // MARK: - Canonical path contract (server-logged rows must render)

    func testCanonicalServerStyleImagePathUploadsAndDownloads() async throws {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let userID = account
        let canonical = FoodImageStore.objectPath(userID: userID, imageID: UUID())
        let photo = upload()

        let returned = try await repository.uploadImage(userID: userID, path: canonical, upload: photo)

        XCTAssertEqual(returned, canonical, "uploads must store the canonical object path")
        XCTAssertEqual(repository.uploadedImagePaths, [canonical])
        let bytes = try await repository.loadMealImage(userID: userID, path: canonical)
        XCTAssertEqual(bytes, photo.data, "the thumbnail pipeline must read back a canonical (server-style) path")
    }

    func testLegacyBucketQualifiedImagePathKeepsRendering() async throws {
        let repository = MockDashboardRepository(snapshot: emptySnapshot())
        let userID = account
        let imageID = UUID()
        let legacy = FoodImageStore.bucketPath(userID: userID, imageID: imageID)
        let photo = upload()

        let returned = try await repository.uploadImage(userID: userID, path: legacy, upload: photo)

        XCTAssertEqual(
            returned,
            FoodImageStore.objectPath(userID: userID, imageID: imageID),
            "legacy prefixed inputs are normalized to the canonical object path"
        )
        let bytes = try await repository.loadMealImage(userID: userID, path: legacy)
        XCTAssertEqual(bytes, photo.data, "rows written by older app builds keep rendering")
    }

    // MARK: - No silent green-pending purgatory (issue AC2)

    func testPermanentUploadRefusalSurfacesNeedsAttention() async throws {
        let (store, cache) = try stores()
        let writer = ScriptedPhotoWriter()
        writer.uploadError = MorselError.requestFailed(401, "session expired")
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = LocalFirstDashboardRepository(
            remote: PipelineOfflineRepository(), store: store, snapshotCache: cache
        )
        let photo = upload()
        let mealID = try await repository.logMeal(userID: account, draft: photoDraft(), photo: photo)

        await engine.runPass()

        let row = try XCTUnwrap(try store.queuedMeal(mealID: mealID))
        XCTAssertEqual(
            row.state, .needsAttention,
            "a refused photo upload must surface needs-attention, never a silent green pending loop"
        )
        XCTAssertEqual(row.lastErrorCategory, .auth)
        XCTAssertEqual(row.photo?.data, photo.data, "the recoverable payload survives the refusal")
    }

    func testPermanentPhotoCommitRefusalPreservesPayloadAsNeedsAttention() async throws {
        let (store, cache) = try stores()
        let writer = ScriptedPhotoWriter()
        writer.commitError = MealDeliveryError.permanent(.photo)
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = LocalFirstDashboardRepository(
            remote: PipelineOfflineRepository(), store: store, snapshotCache: cache
        )
        let photo = upload()
        let mealID = try await repository.logMeal(userID: account, draft: photoDraft(), photo: photo)

        await engine.runPass()

        let row = try XCTUnwrap(try store.queuedMeal(mealID: mealID))
        XCTAssertEqual(
            row.state, .needsAttention,
            "a permanent photo refusal must leave the green-pending purgatory"
        )
        XCTAssertEqual(row.lastErrorCategory, .photo)
        XCTAssertEqual(row.photo?.data, photo.data, "the recoverable payload is preserved")
        XCTAssertEqual(writer.removedPaths.count, 1, "no orphaned photo behind the refused meal")
    }

    func testTransientUploadFailureStaysRetryablePending() async throws {
        let (store, cache) = try stores()
        let writer = ScriptedPhotoWriter()
        writer.uploadError = URLError(.timedOut)
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = LocalFirstDashboardRepository(
            remote: PipelineOfflineRepository(), store: store, snapshotCache: cache
        )
        let photo = upload()
        let mealID = try await repository.logMeal(userID: account, draft: photoDraft(), photo: photo)

        await engine.runPass()

        let row = try XCTUnwrap(try store.queuedMeal(mealID: mealID))
        XCTAssertEqual(row.state, .pending, "transport failures stay retryable pending")
        XCTAssertEqual(row.lastErrorCategory, .network)
        XCTAssertEqual(row.photo?.data, photo.data)
    }

    // MARK: - Queued photo row renders immediately (issue AC1 data path)

    func testQueuedPhotoMealServesCanonicalPathAndLocalBytes() async throws {
        let (store, cache) = try stores()
        let repository = LocalFirstDashboardRepository(
            remote: PipelineOfflineRepository(), store: store, snapshotCache: cache
        )
        let photo = upload()
        let mealID = try await repository.logMeal(userID: account, draft: photoDraft(), photo: photo)

        let record = try await repository.localMealRecord(userID: account, localMealID: mealID)
        let queuedRecord = try XCTUnwrap(record)
        let canonical = FoodImageStore.objectPath(userID: account, imageID: mealID)
        XCTAssertEqual(queuedRecord.imagePath, canonical, "queued photo rows carry their deterministic canonical path")
        XCTAssertEqual(queuedRecord.syncState, .pending)

        let bytes = try await repository.loadMealImage(userID: account, path: canonical)
        XCTAssertEqual(bytes, photo.data, "the queued photo renders from the local store without network")
    }

    // MARK: - Drain + reconcile (issue AC3 happy path)

    func testPhotoMealOutboxDrainsWithCanonicalImagePath() async throws {
        let (store, cache) = try stores()
        let writer = ScriptedPhotoWriter()
        let engine = LocalSyncEngine(userID: account, store: store, mealRemote: writer)
        let repository = LocalFirstDashboardRepository(
            remote: PipelineOfflineRepository(), store: store, snapshotCache: cache
        )
        let photo = upload()
        let mealID = try await repository.logMeal(userID: account, draft: photoDraft(), photo: photo)

        await engine.runPass()

        XCTAssertTrue(try store.queuedMeals().isEmpty, "a photo meal drains after upload + commit")
        let canonical = FoodImageStore.objectPath(userID: account, imageID: mealID)
        XCTAssertEqual(writer.uploadedPaths, [canonical], "uploads use the canonical object path")
        XCTAssertEqual(writer.commitImagePaths[mealID], canonical, "the commit carries the canonical image path")
    }
}

// MARK: - Fakes

/// Offline remote: every read/write throws a transport error.
private final class PipelineOfflineRepository: DashboardRepository {
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

/// Scriptable outbox writer that mirrors the fixed production semantics:
/// uploads return the CANONICAL object path.
private final class ScriptedPhotoWriter: RemoteMealWriting {
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

import Foundation
import XCTest
@testable import Morsel

// Issue #191 — shared harness for the targeted-read proofs: a real
// account-scoped SQLite queue with several LARGE photo rows, the local-first
// repository over the same account file, and the byte-budget assertion every
// read path is held to. `LocalDataStore.blobBytes(column:)` counts the BLOB
// bytes the read paths actually materialize, so nothing here is estimated.

struct TargetedReadFixture {
    let mealID: UUID
    let payload: Data
}

@MainActor
struct TargetedReadQueue {
    /// Distinct, large payloads (size AND byte value): a read that materializes
    /// the whole queue is unmistakable against the selected photo's own size.
    static let photoSizes = [300_000, 600_000, 1_200_000]

    let account: UUID
    let store: LocalDataStore
    let repository: LocalFirstDashboardRepository
    let remote: MealThumbnailRemote
    let fixtures: [TargetedReadFixture]

    init(account: UUID, directory: URL) throws {
        let url = LocalDataStore.storeURL(root: directory, accountID: account)
        let store = try LocalDataStore(databaseURL: url)
        let remote = MealThumbnailRemote()
        var fixtures: [TargetedReadFixture] = []
        for (index, size) in Self.photoSizes.enumerated() {
            let meal = QueuedMealFactory.make(
                draft: Self.draft(notes: "queue-\(index)"),
                photo: FoodImageUpload(
                    data: Data(repeating: UInt8(0x40 + index), count: size), mimeType: "image/jpeg"
                ),
                mealID: UUID(),
                now: Date(timeIntervalSince1970: Double(1_000 + index))
            )
            try store.enqueueMeal(meal)
            fixtures.append(TargetedReadFixture(mealID: meal.mealID, payload: meal.photo?.data ?? Data()))
        }
        self.account = account
        self.store = store
        self.remote = remote
        self.fixtures = fixtures
        repository = LocalFirstDashboardRepository(
            remote: remote, store: store, snapshotCache: try LocalSnapshotCache(databaseURL: url)
        )
    }

    static func draft(notes: String?) -> MealDraft {
        MealDraft(
            mealType: .lunch,
            eatenAt: Date(timeIntervalSince1970: 1_000),
            notes: notes,
            items: [MealItemDraft(name: "oats", quantity: 1, unit: .serving,
                                  caloriesKcal: 220, proteinG: 8)]
        )
    }

    var totalQueuedPhotoBytes: Int {
        fixtures.reduce(0) { $0 + $1.payload.count }
    }

    func canonicalPath(_ mealID: UUID) -> String {
        FoodImageStore.objectPath(userID: account, imageID: mealID)
    }
}

/// The two issue #191 suites share these fixtures; the harness lives here so
/// each suite stays inside the lint budgets.
@MainActor
class TargetedReadCase: XCTestCase {
    let account = UUID()
    let foreignAccount = UUID()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-targeted-191-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeQueue() throws -> TargetedReadQueue {
        try TargetedReadQueue(account: account, directory: directory)
    }
}

@MainActor
extension XCTestCase {
    /// Runs `body` and asserts it materialized no `photo_data` bytes at all.
    func assertZeroPhotoBytes(
        _ label: String,
        store: LocalDataStore,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async rethrows {
        let before = store.blobBytes(column: "photo_data")
        try await body()
        XCTAssertEqual(
            store.blobBytes(column: "photo_data") - before, 0,
            "\(label) materialized queued photo bytes", file: file, line: line
        )
    }
}

/// Records what the outbox delivery seam actually received; an optional latch
/// parks `commitMeal` so a pass can be held in flight deterministically.
final class TargetedReadUploadSpy: RemoteMealWriting {
    private let lock = NSLock()
    private var storedUploads: [UUID: QueuedMealPhoto] = [:]
    private var storedCommits: [UUID] = []
    var parkedCommit: ThumbnailLatch?

    var uploads: [UUID: QueuedMealPhoto] {
        lock.lock()
        defer { lock.unlock() }
        return storedUploads
    }

    var commits: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return storedCommits
    }

    func uploadMealPhoto(userID: UUID, mealID: UUID, photo: QueuedMealPhoto) async throws -> String {
        recordUpload(mealID: mealID, photo: photo)
        return FoodImageStore.objectPath(userID: userID, imageID: mealID)
    }

    func commitMeal(userID: UUID, meal: QueuedMeal, imagePath: String?) async throws {
        _ = (userID, imagePath)
        if let parkedCommit {
            await parkedCommit.wait()
        }
        recordCommit(meal.mealID)
    }

    func removeRemotePhoto(userID: UUID, bucketPath: String) async throws {
        _ = (userID, bucketPath)
    }

    // Synchronous writers: `NSLock` is unavailable from async contexts, so the
    // async seam records through these.
    private func recordUpload(mealID: UUID, photo: QueuedMealPhoto) {
        lock.lock()
        defer { lock.unlock() }
        storedUploads[mealID] = photo
    }

    private func recordCommit(_ mealID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        storedCommits.append(mealID)
    }
}

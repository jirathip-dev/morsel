import XCTest
@testable import Morsel

// Issue #135 — the #133 image READ contract on the native read model:
// reconciled rows carry image {path, signed_url, expires_at}, the signed URL
// is only used before expiry (reads re-mint on every refresh), and cached
// snapshots written before this model existed still decode.
@MainActor
final class MealImageContractTests: XCTestCase {
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-image-contract-tests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL {
        LocalDataStore.storeURL(root: directory, accountID: account)
    }

    private func image(at date: Date = Date()) -> MealImage {
        MealImage(
            path: FoodImageStore.objectPath(userID: account, imageID: UUID()),
            signedURL: URL(string: "https://morsel.test/storage/v1/object/sign/food-images/meal.jpg?token=t"),
            expiresAt: date.addingTimeInterval(15 * 60)
        )
    }

    private func record(image: MealImage?) -> MealRecord {
        MealRecord(
            mealLogID: UUID(),
            mealType: .lunch,
            eatenAt: Date(timeIntervalSince1970: 60),
            source: .photoVision,
            imagePath: image?.path,
            image: image,
            items: [
                MealItem(itemID: UUID(), name: "sushi", quantity: 1, unit: .serving,
                         caloriesKcal: nil, proteinG: nil, carbsG: nil, fatG: nil,
                         fiberG: nil, sugarG: nil, confidence: 1, notes: nil)
                    .withMealImage(image)
            ]
        )
    }

    func testSignedURLIsOnlyUsableBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = image(at: now)
        XCTAssertFalse(fresh.isExpired(at: now.addingTimeInterval(60)), "a fresh URL is usable")
        XCTAssertFalse(
            fresh.isExpired(at: now.addingTimeInterval(15 * 60 - 1)),
            "a URL is still usable just before its expiry instant"
        )
        XCTAssertTrue(
            fresh.isExpired(at: now.addingTimeInterval(15 * 60)),
            "expiry is inclusive: the URL stops working at expires_at"
        )
        XCTAssertTrue(fresh.isExpired(at: now.addingTimeInterval(15 * 60 + 1)), "an expired URL is not fetched")
    }

    func testMealImageWithoutExpiryNeverExpires() {
        let image = MealImage(path: "some/path.jpg")
        XCTAssertFalse(image.isExpired(at: .distantFuture))
    }

    func testMealRecordImageRoundTripsThroughSnapshotCoding() throws {
        let image = image()
        let record = record(image: image)

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(MealRecord.self, from: data)

        XCTAssertEqual(decoded.image, image)
        XCTAssertEqual(decoded.imagePath, image.path)
        XCTAssertEqual(decoded.items.first?.mealImage, image, "items carry their parent meal's image context")
    }

    func testLegacyCachedSnapshotWithoutImageKeysStillDecodes() throws {
        // A snapshot encoded by a pre-#135 build has no image/mealImage keys.
        let legacyJSON = """
        {"mealLogID":"\(UUID().uuidString)","mealType":"lunch","eatenAt":60,
         "source":"photo_vision","imagePath":null,"syncState":"synced",
         "items":[{"itemID":"\(UUID().uuidString)","name":"sushi","quantity":1,
         "unit":"serving","caloriesKcal":null,"proteinG":null,"carbsG":null,
         "fatG":null,"fiberG":null,"sugarG":null,"confidence":1,"notes":null,
         "source":"photo_vision"}]}
        """
        let decoded = try JSONDecoder().decode(MealRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.image, "legacy rows decode with no image contract")
        XCTAssertNil(decoded.items.first?.mealImage)
        XCTAssertNil(decoded.imagePath)
    }

    func testReconciledRowCarriesImageContractThroughTheLocalFirstMerge() async throws {
        let store = try LocalDataStore(databaseURL: databaseURL)
        let cache = try LocalSnapshotCache(databaseURL: databaseURL)
        let image = image()
        let reconciled = record(image: image)
        let remote = ScriptedImageRemote(snapshot: DashboardSnapshot(
            date: Date(timeIntervalSince1970: 60), meals: [reconciled], goal: nil
        ))
        let repository = LocalFirstDashboardRepository(remote: remote, store: store, snapshotCache: cache)

        let snapshot = try await repository.loadToday(userID: account, date: Date(timeIntervalSince1970: 60))
        let row = try XCTUnwrap(snapshot.meals.first)
        XCTAssertEqual(row.image, image, "the reconciled row carries image {path, signed_url, expires_at}")
        XCTAssertEqual(row.imagePath, image.path)
        XCTAssertEqual(row.items.first?.mealImage, image)
        XCTAssertEqual(row.syncState, .synced)
    }
}

/// Remote that serves one authoritative snapshot.
private final class ScriptedImageRemote: DashboardRepository {
    let snapshot: DashboardSnapshot

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
}

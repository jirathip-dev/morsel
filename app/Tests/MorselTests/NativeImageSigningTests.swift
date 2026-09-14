import Supabase
import XCTest
@testable import Morsel

// Issue #179 — native dashboard first paint publishes text/totals with ZERO
// photo-signing calls. These tests drive the PRODUCTION
// SupabaseDashboardRepository reads through the real URLSession seam
// (StubTransport): a plan that parks every request for the stored photo object
// stands in for a deliberately blocked signing endpoint, so publication and
// the signing-call count are asserted from real request events and call counts
// — never from sleeps or wall-clock guesses. The download/seam tests cover the
// consumers (Today thumbnail, Edit/view-photo), which keep reading through the
// authenticated `loadMealImage(path:)` seam.

final class NativeImageSigningTests: XCTestCase {
    private let account = UUID()
    private let mealID = UUID()
    private let itemID = UUID()
    /// 2026-09-05 11:00 +07 (the repo's local-day fixture instant).
    private let referenceInstant = ISO8601DateFormatter().date(from: "2026-09-05T04:00:00Z") ?? Date()

    /// The canonical #133 object path, and its legacy bucket-qualified form.
    private var objectPath: String { "\(account.uuidString)/\(mealID.uuidString).jpg" }
    private var bucketPath: String { "\(FoodImageStore.bucket)/\(objectPath)" }
    /// Matches ANY request for the stored object (sign POST or download GET).
    private var photoRequest: String { "\(account.uuidString)/\(mealID.uuidString).jpg" }

    override func setUp() {
        super.setUp()
        StubTransport.reset()
    }

    override func tearDown() {
        StubTransport.release()
        StubTransport.reset()
        super.tearDown()
    }

    // MARK: - The headline claim

    func testFirstPaintPublishesTextWhileEveryPhotoRequestIsBlocked() async throws {
        populatedDay(imagePath: objectPath)
        StubTransport.respond(photoRequest, .init(hold: true)) // the signing endpoint is blocked

        let repository = try await makeRepository()
        let published = SnapshotBox()
        let load = Task { await published.load(repository, account: account, date: referenceInstant) }
        let didPublish = await waitUntil(timeout: 3) { published.value != nil }

        XCTAssertTrue(didPublish, "text/totals must publish while every photo request is parked")
        XCTAssertEqual(signingStarts().count, 0, "native first paint issues zero signing calls")
        XCTAssertEqual(photoStarts().count, 0, "first paint issues no photo request at all")

        let snapshot = try XCTUnwrap(published.value)
        let meal = try XCTUnwrap(snapshot.meals.first)
        XCTAssertEqual(snapshot.meals.count, 1, "the photo meal is in the published snapshot")
        XCTAssertEqual(meal.items.first?.itemID, itemID, "item IDs survive")
        XCTAssertEqual(meal.items.first?.name, "jasmine rice")
        XCTAssertEqual(meal.items.first?.caloriesKcal, 300, "meal totals survive")
        XCTAssertEqual(snapshot.goal?.calorieTargetKcal, 2000, "dashboard totals publish too")
        XCTAssertEqual(meal.imagePath, objectPath, "the canonical path is carried without a URL")
        XCTAssertNil(meal.image?.signedURL, "no signed URL is minted for native reads")
        XCTAssertNil(meal.items.first?.mealImage?.signedURL, "items carry the path-only image context")
        load.cancel()
    }

    // MARK: - Lazy mint boundary

    func testLazyMintServesAUrlConsumerAndTheReadPathNeverMints() async throws {
        populatedDay(imagePath: bucketPath) // legacy bucket-qualified column
        let signed = "https://stub.supabase.test/storage/v1/object/sign/food-images/\(objectPath)?token=stub"
        StubTransport.respond(photoRequest, .init(body: "{\"signedURL\": \"\(signed)\"}"))

        let repository = try await makeRepository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)
        let meal = try XCTUnwrap(snapshot.meals.first)
        XCTAssertEqual(meal.imagePath, objectPath, "legacy paths normalize to the canonical object path")
        XCTAssertEqual(meal.image?.path, objectPath)
        XCTAssertNil(meal.image?.signedURL)
        XCTAssertEqual(signingStarts().count, 0, "the read graph never calls the mint")

        // A consumer that genuinely requires a URL mints on demand.
        let client = try XCTUnwrap(repository.client)
        let row = MealLogResponse(
            id: mealID.uuidString, eatenAt: "2026-09-05T03:30:00.000Z",
            mealType: "lunch", source: "photo_vision", imagePath: bucketPath
        )
        let minted = await repository.mintMealImages(logs: [row], client: client, userID: account)
        let mintedImage = try XCTUnwrap(minted[mealID.uuidString])
        XCTAssertNotNil(mintedImage.signedURL, "the lazy mint serves a real URL consumer")
        XCTAssertNotNil(mintedImage.expiresAt, "the minted URL carries its expiry")
        XCTAssertEqual(mintedImage.path, objectPath)
        XCTAssertEqual(signingStarts().count, 1, "exactly the consumer's one mint, never the read")
    }

    // MARK: - Consumer seams keep working (Today thumbnail, Edit/view-photo)

    func testThumbnailAndEditLoadsDownloadThroughTheAuthenticatedPathSeam() async throws {
        populatedDay(imagePath: bucketPath) // legacy form must still resolve
        StubTransport.respond(photoRequest, .init(body: "meal-photo-bytes"))

        let repository = try await makeRepository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)
        let path = try XCTUnwrap(snapshot.meals.first?.imagePath)
        XCTAssertEqual(path, objectPath, "the thumbnail consumer receives the canonical path")

        // Today thumbnail (canonical) and Edit photo (canonical + legacy).
        let canonicalBytes = try await repository.loadMealImage(userID: account, path: path)
        XCTAssertEqual(canonicalBytes, Data("meal-photo-bytes".utf8))
        let legacyBytes = try await repository.loadMealImage(userID: account, path: bucketPath)
        XCTAssertEqual(legacyBytes, Data("meal-photo-bytes".utf8), "legacy normalized paths still download")

        XCTAssertEqual(signingStarts().count, 0, "authenticated downloads need no signed URL")
        XCTAssertEqual(photoStarts().count, 2, "each load issues its own authenticated GET")
    }

    // MARK: - Independent degradation matrix

    func testForeignPhotoPathKeepsTextAndRejectsTheDownload() async throws {
        let foreign = "\(UUID().uuidString)/\(UUID().uuidString).jpg"
        populatedDay(imagePath: foreign)

        let repository = try await makeRepository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)
        let meal = try XCTUnwrap(snapshot.meals.first)
        XCTAssertNil(meal.image, "a path that belongs to another account carries no image contract")
        XCTAssertEqual(meal.items.first?.itemID, itemID, "meal text and item IDs stay published")
        XCTAssertEqual(meal.items.first?.caloriesKcal, 300, "totals stay published")
        await assertThrows("the download seam still rejects a foreign path") {
            try await repository.loadMealImage(userID: self.account, path: foreign)
        }
        XCTAssertEqual(photoStarts().count, 0, "no request is built for a path that fails validation")
    }

    func testMissingPhotoBytesDegradeWithoutHidingTextOrTotals() async throws {
        populatedDay(imagePath: objectPath)
        StubTransport.respond(photoRequest, .init(status: 404, body: "{\"statusCode\":\"404\"}"))

        let repository = try await makeRepository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)
        let meal = try XCTUnwrap(snapshot.meals.first)
        XCTAssertEqual(meal.imagePath, objectPath, "a missing object still carries its canonical path")
        XCTAssertEqual(meal.items.first?.name, "jasmine rice")
        XCTAssertEqual(meal.items.first?.caloriesKcal, 300)
        await assertThrows("a missing object fails the thumbnail load, never the meal text") {
            try await repository.loadMealImage(userID: self.account, path: self.objectPath)
        }
        XCTAssertEqual(signingStarts().count, 0)
    }

    // MARK: - Replacement at the canonical path

    func testPhotoReplacementAtTheCanonicalPathStaysVisibleWithoutAnyUrlCache() async throws {
        populatedDay(imagePath: objectPath)
        StubTransport.respond(photoRequest, .init(body: "first-bytes"))
        let repository = try await makeRepository()
        let first = try await repository.loadMealImage(userID: account, path: objectPath)
        XCTAssertEqual(first, Data("first-bytes".utf8))

        StubTransport.respond(photoRequest, .init(body: "replaced-bytes"))
        let replaced = try await repository.loadMealImage(userID: account, path: objectPath)
        XCTAssertEqual(replaced, Data("replaced-bytes".utf8), "replacement at the same path is visible")

        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)
        XCTAssertEqual(snapshot.meals.first?.imagePath, objectPath, "the canonical path is stable across a replacement")
        XCTAssertEqual(photoStarts().count, 2, "every load re-reads the object: no URL or byte cache mediates")
        XCTAssertEqual(signingStarts().count, 0)
    }

    // MARK: - Fixtures and support

    private func populatedDay(imagePath: String?) {
        StubTransport.respond("meal_logs", .init(body: mealLogs(imagePath: imagePath)))
        StubTransport.respond("meal_items", .init(body: """
        [{"id": "\(itemID.uuidString)", "meal_log_id": "\(mealID.uuidString)", "name": "jasmine rice", \
        "quantity": 1.5, "unit": "serving", "calories_kcal": 300, "protein_g": 6, "confidence": 0.9}]
        """))
    }

    private func mealLogs(imagePath: String?) -> String {
        let column = imagePath.map { "\"\($0)\"" } ?? "null"
        return """
        [{"id": "\(mealID.uuidString)", "eaten_at": "2026-09-05T03:30:00.000Z", "meal_type": "lunch", \
        "source": "photo_vision", "image_path": \(column)}]
        """
    }

    /// Started requests to the real storage signing endpoint.
    private func signingStarts() -> [StubTransport.Event] {
        StubTransport.snapshot().events
            .filter { $0.phase == .started && $0.url.contains("/object/sign/") }
    }

    /// Started requests for the stored photo object (sign or download).
    private func photoStarts() -> [StubTransport.Event] {
        StubTransport.snapshot().events
            .filter { $0.phase == .started && $0.url.contains(photoRequest) }
    }

    private func assertThrows(_ message: String, _ operation: () async throws -> some Sendable) async {
        do {
            _ = try await operation()
            XCTFail(message)
        } catch {
            // expected: the load failure is reportable, never a silent success
        }
    }

    /// Bounded wait for a real completion event; it only keeps a stuck read
    /// from hanging the suite and never carries an ordering claim.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    private func makeRepository(
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) async throws -> SupabaseDashboardRepository {
        guard let baseURL = URL(string: "https://stub.supabase.test") else {
            preconditionFailure("stub base URL must be valid")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        configuration.urlCache = nil
        let client = SupabaseClient(
            supabaseURL: baseURL, supabaseKey: "stub-anon-key",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: StubSessionStorage(userID: account, expiresAt: expiresAt),
                    storageKey: "sb-stub-auth-token", autoRefreshToken: false
                ),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
        // Exercise the real session seam before the read.
        _ = try await client.auth.session
        return SupabaseDashboardRepository(client: client)
    }
}

/// Captures the first published snapshot from a task, so the test can assert
/// publication while chosen requests are still parked.
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DashboardSnapshot?

    var value: DashboardSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func load(_ repository: SupabaseDashboardRepository, account: UUID, date: Date) async {
        let loaded = try? await repository.loadToday(userID: account, date: date)
        lock.lock()
        stored = loaded
        lock.unlock()
    }
}

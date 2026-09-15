import Supabase
import XCTest
@testable import Morsel

@MainActor
final class ArtworkIdentityReadTests: XCTestCase {
    func testLiveTodayReadProjectsDecodesHydratesAndCachesIdentity() async throws {
        StubTransport.reset()
        defer { StubTransport.release(); StubTransport.reset() }
        let account = try XCTUnwrap(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTransport.self]
        let client = SupabaseClient(
            supabaseURL: try XCTUnwrap(URL(string: "https://artwork.invalid")), supabaseKey: "stub-anon-key",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: StubSessionStorage(userID: account, expiresAt: Date().addingTimeInterval(3_600)),
                    storageKey: "sb-stub-auth-token", autoRefreshToken: false
                ),
                global: .init(session: URLSession(configuration: config))
            )
        )
        let data = try ArtworkIdentityFixture.data(name: "Focaccia bread", identity: "coffee")
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        StubTransport.respond("meal_items", .init(body: "[" + body + "]"))
        StubTransport.respond("meal_logs", .init(body: """
        [{"id":"\(ArtworkIdentityFixture.mealID)","eaten_at":"2026-09-05T03:30:00Z",\
        "meal_type":"lunch","source":"photo_vision","image_path":"\(ArtworkIdentityFixture.photoPath)"}]
        """))
        let snapshot = try await SupabaseDashboardRepository(client: client).loadToday(userID: account, date: Date())
        let select = StubTransport.snapshot().queryValues("meal_items", "select").joined(separator: ",")
        XCTAssertTrue(
            select.split(separator: ",").contains("artwork_id"), "real PostgREST projection must request identity"
        )
        let meal = try XCTUnwrap(snapshot.meals.first)
        let item = try XCTUnwrap(meal.items.first)
        XCTAssertEqual(item.artworkID, "coffee")
        XCTAssertEqual(MealArtworkPresentation.row(items: [item]).asset?.id, "coffee")
        XCTAssertEqual(item.name, "Focaccia bread")
        XCTAssertEqual(item.caloriesKcal, 23)
        XCTAssertEqual(item.mealImage?.path, ArtworkIdentityFixture.photoPath)
        XCTAssertEqual(meal.imagePath, ArtworkIdentityFixture.photoPath)
        let cached = try JSONDecoder().decode(DashboardSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(cached, snapshot, "local Codable snapshots retain the additive optional field")
    }

    func testAbsentAndNullWireIdentityAndOldCacheDecode() throws {
        let data = try ArtworkIdentityFixture.data(name: "Coffee")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for null in [false, true] {
            if null { object["artwork_id"] = NSNull() }
            let response = try JSONDecoder().decode(
                MealItemResponse.self, from: JSONSerialization.data(withJSONObject: object)
            )
            let item = try SupabaseDashboardRepository(client: nil).parseItem(response, source: .manual)
            XCTAssertNil(item.artworkID)
            XCTAssertEqual(MealArtworkPresentation.row(items: [item]).asset?.id, "coffee")
            var cache = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
            )
            cache.removeValue(forKey: "artworkID")
            let old = try JSONDecoder().decode(MealItem.self, from: JSONSerialization.data(withJSONObject: cache))
            XCTAssertEqual(old, item)
        }
    }

    func testAmbiguousAliasesAndCategoriesFailClosed() throws {
        let neutral = try XCTUnwrap(FoodArtworkCatalog.bundled.first { $0.isNeutralFallback })
        let ambiguous = [
            FoodArtworkAsset(id: "one", name: "Other", aliases: ["shared"], category: "grains", kind: .food),
            FoodArtworkAsset(id: "two", name: "Shared", aliases: [], category: "produce", kind: .food), neutral
        ]
        XCTAssertEqual(FoodArtworkResolver.resolve(name: "shared", in: ambiguous), .neutral(neutral))
        let categories = [
            FoodArtworkAsset(id: "one", name: "One", aliases: [], category: "grains", kind: .fallback),
            FoodArtworkAsset(id: "two", name: "Two", aliases: [], category: "grains", kind: .fallback), neutral
        ]
        XCTAssertEqual(FoodArtworkResolver.resolve(name: "grains", in: categories), .neutral(neutral))
        XCTAssertNil(FoodArtworkResolver.categoryFallback(for: "grains", in: categories))
    }
}

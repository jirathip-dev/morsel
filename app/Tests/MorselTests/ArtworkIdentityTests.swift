import SwiftUI
import XCTest
@testable import Morsel

/// The same wire fixture/production parse path compiles on the pre-identity base.
/// No test-only initializer can accidentally bypass the live decoder.
enum ArtworkIdentityFixture {
    static let positives = [
        "Coffee", "black coffee", "กาแฟ", "Americano", "Americano (black, no sugar, homemade)"
    ]
    static let negatives = ["coffee cake", "Coffee with rice and chicken", "Uncatalogued lunar stew"]
    static let mealID = "11111111-1111-4111-8111-111111111111"
    static let itemID = "22222222-2222-4222-8222-222222222222"
    static let photoPath = "33333333-3333-4333-8333-333333333333/11111111-1111-4111-8111-111111111111.jpg"

    static func data(name: String, identity: String? = nil, id: String = itemID) throws -> Data {
        var object: [String: Any] = [
            "id": id, "meal_log_id": mealID, "name": name, "quantity": 1.5, "unit": "cup",
            "calories_kcal": 23, "protein_g": 2, "carbs_g": 3, "fat_g": 1,
            "fiber_g": 0.5, "sugar_g": 0.25, "confidence": 0.9, "source_notes": "Synthetic fixture"
        ]
        if let identity { object["artwork_id"] = identity }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func item(
        name: String, identity: String? = nil, photo: Bool = false, id: String = itemID
    ) throws -> MealItem {
        let response = try JSONDecoder().decode(MealItemResponse.self, from: data(name: name, identity: identity, id: id))
        let item = try SupabaseDashboardRepository(client: nil).parseItem(response, source: .photoVision)
        return item.withMealImage(photo ? MealImage(path: photoPath) : nil)
    }
}

@MainActor
final class ArtworkIdentityTests: JournalRenderingTestCase {
    private let assets = FoodArtworkCatalog.bundled

    func testLegacyCoffeeAndDescriptiveAmericanoResolveWithoutRenaming() throws {
        for name in ArtworkIdentityFixture.positives {
            let item = try ArtworkIdentityFixture.item(name: name, photo: true)
            XCTAssertEqual(JournalRowArtwork.resolve(items: [item]), try library("coffee"), name)
            XCTAssertEqual(item.name, name)
            XCTAssertEqual(item.quantity, 1.5)
            XCTAssertEqual(item.unit, .cup)
            XCTAssertEqual([item.caloriesKcal, item.proteinG, item.carbsG, item.fatG], [23, 2, 3, 1])
            XCTAssertEqual([item.fiberG, item.sugarG, item.confidence], [0.5, 0.25, 0.9])
            XCTAssertEqual(item.notes, "Synthetic fixture")
            XCTAssertEqual(item.mealImage?.path, ArtworkIdentityFixture.photoPath)
        }
    }

    func testExplicitIdentityBeatsContradictoryLibraryAndVariantANames() throws {
        for name in ["Coffee", "Focaccia bread", "Uncatalogued lunar stew"] {
            let item = try ArtworkIdentityFixture.item(name: name, identity: "banana", photo: true)
            XCTAssertEqual(JournalRowArtwork.resolve(items: [item]), try library("banana"), name)
            XCTAssertEqual(MealArtworkPresentation.row(items: [item]).asset?.id, "banana")
            XCTAssertEqual(item.name, name)
            XCTAssertEqual(item.mealImage?.path, ArtworkIdentityFixture.photoPath)
        }
        let neutral = try ArtworkIdentityFixture.item(name: "Coffee", identity: "fallback-neutral")
        XCTAssertEqual(JournalRowArtwork.resolve(items: [neutral]), try library("fallback-neutral"))
    }

    func testUnknownIdentityUsesConservativeFallbackNeverAnArbitraryDish() throws {
        for identity in ["future-study", "", "Coffee", " coffee", "coffee ", "../../coffee"] {
            for name in ArtworkIdentityFixture.positives {
                let item = try ArtworkIdentityFixture.item(name: name, identity: identity)
                XCTAssertEqual(JournalRowArtwork.resolve(items: [item]), try library("coffee"), identity + name)
            }
            for name in ArtworkIdentityFixture.negatives {
                let item = try ArtworkIdentityFixture.item(name: name, identity: identity)
                XCTAssertEqual(JournalRowArtwork.resolve(items: [item]),
                               name == "coffee cake" ? try library("cake") : .study(.unknown), identity + name)
            }
        }
    }

    func testNoSubstringOrUnapprovedDescriptorMayGuessCoffee() throws {
        let names = ArtworkIdentityFixture.negatives + [
            "Americano cake", "Americano (cake)", "Americano (black, chicken)",
            "Americano (black) with toast", "Americano ()", "Americano (black,,homemade)",
            "Americano (black (no sugar))", "coffeeish"
        ]
        for name in names {
            let item = try ArtworkIdentityFixture.item(name: name)
            XCTAssertEqual(JournalRowArtwork.resolve(items: [item]),
                           name == "coffee cake" ? try library("cake") : .study(.unknown), name)
        }
    }

    func testEveryPublishedIdentityAndOldBundleDegradation() throws {
        for asset in assets {
            let item = try ArtworkIdentityFixture.item(name: "Uncatalogued lunar stew", identity: asset.id)
            XCTAssertEqual(JournalRowArtwork.resolve(items: [item]), try library(asset.id))
        }
        let item = try ArtworkIdentityFixture.item(name: "Coffee", identity: "banana")
        XCTAssertEqual(
            JournalRowArtwork.resolve(items: [item], assets: assets.filter { $0.id != "banana" }),
            try library("coffee"), "an older bundle falls back without a missing-asset view"
        )
    }

    func testOldRowsCategoryAndMixedMealCompatibility() throws {
        for asset in assets {
            for name in [asset.name] + asset.aliases {
                // Frozen alias collides with the shipped trailing-qualifier grammar:
                // cold-cuts' "sausage slices" also reduces to sausage. Do not guess.
                let expected = name == "sausage slices" ? "fallback-neutral" : asset.id
                XCTAssertEqual(FoodArtworkResolver.resolve(name: name, in: assets).asset?.id, expected, name)
            }
        }
        let items = try ["Coffee", "Jasmine rice"].map { try ArtworkIdentityFixture.item(name: $0) }
        XCTAssertEqual(JournalRowArtwork.resolve(items: items), .study(.unknown))
        let grains = try ["Jasmine rice", "Toast"].map { try ArtworkIdentityFixture.item(name: $0) }
        XCTAssertEqual(JournalRowArtwork.resolve(items: grains), try library("fallback-grains"))
        XCTAssertEqual(JournalRowArtwork.resolve(items: []), .none)
    }

    func testBothThemesPaintCoffeePixelsAndRowsIgnorePhotos() throws {
        for scheme in [ColorScheme.light, .dark] {
            let reference = try XCTUnwrap(render(
                FoodArtworkImageView(assetID: "coffee", label: "reference", hint: "reference", size: 56),
                scheme: scheme
            ))
            XCTAssertGreaterThan(nonWhitePixels(reference), 64)
            for name in ArtworkIdentityFixture.positives {
                for photo in [false, true] {
                    let item = try ArtworkIdentityFixture.item(name: name, photo: photo)
                    let painted = try XCTUnwrap(render(MealArtworkSlot(items: [item], size: 56), scheme: scheme))
                    try assertPixelsEqual(painted, reference, name)
                    XCTAssertEqual(
                        MealArtworkPresentation.resolve(photoPath: item.mealImage?.path, items: [item]),
                        photo ? .photo(ArtworkIdentityFixture.photoPath) : .illustration(try food("coffee"))
                    )
                }
            }
        }
    }

    private func food(_ identity: String) throws -> FoodArtworkResolution {
        let asset = try XCTUnwrap(assets.first { $0.id == identity })
        if asset.isNeutralFallback { return .neutral(asset) }
        return asset.kind == .food && identity != "stir-fried-greens" ? .food(asset) : .category(asset)
    }

    private func library(_ identity: String) throws -> JournalRowArtwork { .library(try food(identity)) }
}

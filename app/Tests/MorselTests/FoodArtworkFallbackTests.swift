import XCTest
@testable import Morsel

// Issue #199 — offline food-illustration fallbacks; issue #223 — rows are
// ALWAYS illustrated (unknown/mixed meals resolve to the approved neutral
// sign; a stored meal photo never renders in a row — it stays authoritative
// inside detail/edit). These tests run against the REAL production paths and
// the bundled catalog alone: no network, no generation API.

/// A logged food item; `mealImage` marks a photo-present item (issue #223 —
/// its row is illustrated anyway, the photo stays in detail/edit).
private func artworkItem(_ name: String, kcal: Double = 100, mealImage: MealImage? = nil) -> MealItem {
    MealItem(
        itemID: UUID(), name: name, quantity: 1, unit: .serving,
        caloriesKcal: kcal, proteinG: 10, carbsG: 20, fatG: 5,
        fiberG: nil, sugarG: nil, confidence: 0.9, notes: nil, mealImage: mealImage
    )
}

private func catalogAsset(_ id: String) throws -> FoodArtworkAsset {
    try XCTUnwrap(
        FoodArtworkCatalog.bundled.first { $0.id == id },
        "catalog is missing \(id)"
    )
}

/// The four owner food names this lane must reproduce: none is in the
/// catalog, so all four exercise the fallback path.
private let ownerFoodNames = [
    "Focaccia bread", "Mortadella", "Stracciatella cheese", "Grilled vegetable topping"
]

@MainActor
final class FoodArtworkFallbackTests: XCTestCase {
    private let assets = FoodArtworkCatalog.bundled

    // MARK: - Alias / name mapping

    func testApprovedNamesAndAliasesResolveToStableArtworkIDs() {
        let cases: [(String, String)] = [
            ("Jasmine rice", "jasmine-rice"),
            ("white rice", "jasmine-rice"),
            ("ข้าวสวย", "jasmine-rice"),
            ("chicken breast", "grilled-chicken"),
            ("steamed broccoli", "broccoli"),
            ("กล้วย", "banana"),
            ("black coffee", "coffee"),
            ("sunny-side-up egg", "fried-egg")
        ]
        for (name, expected) in cases {
            XCTAssertEqual(
                FoodArtworkResolver.match(name: name, in: assets)?.id, expected,
                "\(name) must map to the approved \(expected) study"
            )
        }
    }

    func testMatchingIsDeterministicAcrossCaseAndWhitespace() {
        XCTAssertEqual(FoodArtworkResolver.match(name: "  JASMINE   rice ", in: assets)?.id, "jasmine-rice")
        XCTAssertEqual(FoodArtworkResolver.match(name: "Avocado Half", in: assets)?.id, "avocado")
        XCTAssertNil(FoodArtworkResolver.match(name: "   ", in: assets))
        XCTAssertNil(FoodArtworkResolver.match(name: "", in: assets))
    }

    func testCategoryAliasesResolveToTheirLabeledFallback() throws {
        struct CategoryCase {
            let alias: String
            let id: String
            let label: String
        }
        let cases = [
            CategoryCase(alias: "produce category", id: "fallback-produce", label: "Produce"),
            CategoryCase(alias: "protein category", id: "fallback-protein", label: "Protein"),
            CategoryCase(alias: "grain category", id: "fallback-grains", label: "Grains"),
            CategoryCase(alias: "beverage category", id: "fallback-drinks", label: "Drinks")
        ]
        for testCase in cases {
            let matched = try XCTUnwrap(FoodArtworkResolver.match(name: testCase.alias, in: assets))
            XCTAssertEqual(matched.id, testCase.id)
            XCTAssertTrue(
                matched.isCategoryFallback,
                "\(testCase.alias) is category artwork, never a detected food"
            )
            XCTAssertFalse(matched.isNeutralFallback, "a category alias never resolves to the neutral sentinel")
            XCTAssertEqual(matched.categoryLabel, testCase.label, "category artwork travels with its category label")
            XCTAssertEqual(FoodArtworkResolver.resolve(name: testCase.alias, in: assets), .category(matched))
        }
    }

    // MARK: - Unknown + composite meals (issue #223)

    func testUnknownFoodResolvesToTheNeutralSignNeverBlank() throws {
        let neutral = try catalogAsset("fallback-neutral")
        XCTAssertNil(FoodArtworkResolver.match(name: "pad thai from the corner stall", in: assets))
        XCTAssertEqual(FoodArtworkResolver.resolve(items: [artworkItem("pad thai")], in: assets), .neutral(neutral))
        XCTAssertEqual(
            MealArtworkPresentation.resolve(photoPath: nil, items: [artworkItem("pad thai")], assets: assets),
            .illustration(.neutral(neutral)),
            "an unknown meal resolves to the approved neutral sign — never blank"
        )
    }

    /// Issue #229 retarget (extension, not a weakening): the four owner foods
    /// are the approved Variant A subjects, so the ROW artwork carries their A
    /// studies while the #199 library resolver itself is unchanged — a food
    /// neither set knows still resolves to the neutral sign.
    func testOwnerFoodNamesCarryApprovedAStudiesWhileTheLibraryIsUnchanged() throws {
        let neutral = try catalogAsset("fallback-neutral")
        for (name, study) in zip(ownerFoodNames, approvedAStudies) {
            XCTAssertNil(FoodArtworkResolver.match(name: name, in: assets), "\(name) stays off the #199 catalog")
            XCTAssertEqual(
                FoodArtworkResolver.resolve(items: [artworkItem(name)], in: assets), .neutral(neutral),
                "the library-only path still answers with the neutral sign for \(name)"
            )
            XCTAssertEqual(
                JournalRowArtwork.resolve(items: [artworkItem(name)], assets: assets), .study(study),
                "\(name)'s row carries its approved A study"
            )
        }
        let ownerMeal = ownerFoodNames.map { artworkItem($0) }
        XCTAssertEqual(
            JournalRowArtwork.resolve(items: ownerMeal, assets: assets), .study(.unknown),
            "the owner's mixed A meal paints the neutral sign, never one arbitrary ingredient"
        )
    }

    private let approvedAStudies: [JournalArtworkStudy] = [.focaccia, .mortadella, .stracciatella, .vegetables]

    func testNeutralStudyIsNeverResolvedAsAnIdentifiedFoodOrCategory() throws {
        let neutral = try catalogAsset("fallback-neutral")
        XCTAssertTrue(neutral.isNeutralFallback)
        XCTAssertFalse(
            neutral.isCategoryFallback,
            "the neutral sentinel travels without a category claim (ART-SPEC)"
        )
        XCTAssertEqual(neutral.category, FoodArtworkAsset.neutralCategory)
        for alias in ["neutral food fallback", "unknown food", "mixed meal"] {
            XCTAssertEqual(
                FoodArtworkResolver.resolve(name: alias, in: assets), .neutral(neutral),
                "\(alias) is a lookup term for the neutral sign, never an identified food"
            )
        }
        XCTAssertEqual(FoodArtworkResolver.match(name: "unknown food", in: assets)?.kind, .fallback)
    }

    func testCompositeMealWithinOneCategoryUsesThatCategorysLabeledFallback() throws {
        let resolution = FoodArtworkResolver.resolve(
            items: [artworkItem("jasmine rice"), artworkItem("toast")], in: assets
        )
        XCTAssertEqual(resolution, .category(try catalogAsset("fallback-grains")))
    }

    func testCompositeMealAcrossCategoriesUsesTheNeutralSignNeverOneArbitraryItem() throws {
        let resolution = FoodArtworkResolver.resolve(
            items: [artworkItem("jasmine rice"), artworkItem("grilled chicken")], in: assets
        )
        XCTAssertEqual(
            resolution, .neutral(try catalogAsset("fallback-neutral")),
            "a mixed meal must not present one ingredient as the whole meal"
        )
        XCTAssertNotEqual(resolution, .food(try catalogAsset("jasmine-rice")))
        XCTAssertNotEqual(resolution, .food(try catalogAsset("grilled-chicken")))
    }

    func testOneUnmatchedItemNeverSuppressesItsSiblings() throws {
        let neutral = try catalogAsset("fallback-neutral")
        // The meal summary of {known, unknown} is the neutral sign…
        XCTAssertEqual(
            FoodArtworkResolver.resolve(
                items: [artworkItem("jasmine rice"), artworkItem("pad thai")], in: assets
            ),
            .neutral(neutral)
        )
        // …while each item still resolves on its own: the matched sibling keeps
        // its approved study, the unmatched one gets the neutral sign.
        XCTAssertEqual(
            FoodArtworkResolver.resolve(items: [artworkItem("jasmine rice")], in: assets),
            .food(try catalogAsset("jasmine-rice"))
        )
        XCTAssertEqual(
            FoodArtworkResolver.resolve(items: [artworkItem("pad thai")], in: assets),
            .neutral(neutral)
        )
    }

    func testSingleItemMealUsesItsOwnApprovedStudy() throws {
        XCTAssertEqual(
            FoodArtworkResolver.resolve(items: [artworkItem("coffee")], in: assets),
            .food(try catalogAsset("coffee"))
        )
        XCTAssertEqual(FoodArtworkResolver.resolve(items: [], in: assets), .none, "no logged food, nothing to depict")
    }

    // MARK: - Row vs detail presentation (issue #223)

    func testStoredMealPhotoStaysAuthoritativeInsideDetail() {
        let path = "\(UUID().uuidString)/\(UUID().uuidString).jpg"
        XCTAssertEqual(
            MealArtworkPresentation.resolve(photoPath: path, items: [artworkItem("jasmine rice")], assets: assets),
            .photo(path),
            "detail/edit still renders the stored meal photo"
        )
    }

    func testRowPresentationNeverShowsTheStoredPhoto() throws {
        let path = "\(UUID().uuidString)/\(UUID().uuidString).jpg"
        // The row decision takes no photo path: a photo-present meal resolves
        // to its illustration, so the photo cannot win a row.
        XCTAssertEqual(
            MealArtworkPresentation.row(items: [artworkItem("jasmine rice", mealImage: MealImage(path: path))]),
            .food(try catalogAsset("jasmine-rice"))
        )
        XCTAssertEqual(
            MealArtworkPresentation.row(items: [artworkItem("pad thai", mealImage: MealImage(path: path))]),
            .neutral(try catalogAsset("fallback-neutral"))
        )
        XCTAssertEqual(MealArtworkPresentation.row(items: []), .none)
    }

    func testMissingPhotoPathFallsToTheOfflineIllustration() throws {
        let rice = try catalogAsset("jasmine-rice")
        XCTAssertEqual(
            MealArtworkPresentation.resolve(photoPath: nil, items: [artworkItem("jasmine rice")], assets: assets),
            .illustration(.food(rice))
        )
        XCTAssertEqual(
            MealArtworkPresentation.resolve(photoPath: "", items: [artworkItem("jasmine rice")], assets: assets),
            .illustration(.food(rice)),
            "an empty path is a missing photo, not a photo"
        )
    }

    // MARK: - No nutrition mutation

    func testResolvingIllustrationsDoesNotMutateLoggedFoodOrNutritionData() throws {
        let meal = MealRecord(
            mealLogID: UUID(), mealType: .lunch, eatenAt: Date(timeIntervalSince1970: 60), source: .manual,
            items: [artworkItem("jasmine rice", kcal: 220), artworkItem("grilled chicken", kcal: 250)]
        )
        let before = meal
        let beforeNutrition = meal.items.map { [$0.caloriesKcal, $0.proteinG, $0.carbsG, $0.fatG] }

        _ = FoodArtworkResolver.resolve(items: meal.items, in: assets)
        _ = MealArtworkPresentation.resolve(photoPath: nil, items: meal.items, assets: assets)

        XCTAssertEqual(
            meal, before,
            "illustration resolution must not touch logged foods, portions or nutrition"
        )
        XCTAssertEqual(meal.items.map(\.name), ["jasmine rice", "grilled chicken"])
        XCTAssertEqual(meal.items.map { [$0.caloriesKcal, $0.proteinG, $0.carbsG, $0.fatG] }, beforeNutrition)
        XCTAssertEqual(meal.items.map(\.quantity), [1, 1])
    }
}

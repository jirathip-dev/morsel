import Foundation
import XCTest
@testable import Morsel

@MainActor
final class FoodArtworkMatcherClosureTests: XCTestCase {
    private let assets = FoodArtworkCatalog.bundled

    func testPortionWordOrderAndHyphenationAcrossFoods() {
        let foods = [("white rice", "jasmine-rice"), ("black coffee", "coffee"), ("linguine", "pasta")]
        for (name, identity) in foods {
            for prefix in ["half-portion ", "half portion ", "small-portion ", "large portion "] {
                for suffix in ["", ", cooked", " (120 g)"] {
                    let input = prefix + name + suffix
                    XCTAssertEqual(FoodArtworkResolver.match(name: input, in: assets)?.id, identity, input)
                }
            }
            for suffix in [" (half-portion)", ", half-portion", " half-portion", ", sugar-free", ", low-fat"] {
                XCTAssertEqual(FoodArtworkResolver.match(name: name + suffix, in: assets)?.id, identity)
            }
        }
    }

    func testNounParentheticalsRequireTwoAliasesOfTheSameAsset() {
        let positives = [
            ("pasta (linguine), cooked", "pasta"), ("linguine (pasta), cooked", "pasta"),
            ("pasta, cooked (spaghetti)", "pasta"), ("pasta (fettuccine) cooked", "pasta"),
            ("half-portion pasta (tagliatelle), cooked", "pasta"),
            ("pork with brown gravy", "braised-pork"), ("pork with brown gravy (moo ob)", "braised-pork"),
            ("braised pork, cooked (moo ob)", "braised-pork"),
            ("Chinese kale, cooked (kana)", "stir-fried-greens")
        ]
        for (name, identity) in positives {
            XCTAssertEqual(FoodArtworkResolver.match(name: name, in: assets)?.id, identity, name)
        }
        // Catalog-driven, not hard-coded to pasta, rice, pork, or the shipped vocabulary.
        let study = FoodArtworkAsset(id: "test-study", name: "Test dish", aliases: ["test synonym"],
                                     category: "prepared", kind: .food)
        XCTAssertEqual(FoodArtworkResolver.match(name: "test dish (test synonym), cooked", in: [study]), study)
        let collision = FoodArtworkAsset(id: "other-study", name: "Test dish", aliases: ["test synonym"],
                                         category: "prepared", kind: .food)
        XCTAssertNil(FoodArtworkResolver.match(name: "test dish (test synonym), cooked", in: [study, collision]))
    }

    func testMalformedCrossFoodAndCompositeNamesStayNeutral() {
        for name in [
            "pasta (coffee), cooked", "pasta (linguine cake), cooked", "pasta (linguine) with chicken",
            "pasta ((linguine)), cooked", "pasta (linguine", "pasta (linguine))", "pasta ()",
            "pasta (linguine, chicken)", "pasta (linguine) (cake)", "rice cake (half-portion)",
            "half-portion coffee cake with rice", "half-portion white rice and pork",
            "milk tea (boba tea)", "pad thai (stir-fried noodles)", "unknown food, cooked",
            "composite/shared restaurant plate", "half-portion white riceish", "fried white rice"
        ] {
            XCTAssertTrue(isNeutral(FoodArtworkResolver.resolve(name: name, in: assets)), name)
        }
        for (name, identity) in [("coffee cake", "cake"), ("milk tea", "milk-tea"), ("pad thai", "pad-thai")] {
            XCTAssertEqual(FoodArtworkResolver.resolve(name: name, in: assets).asset?.id, identity)
        }
    }

    func testGreensAreAnHonestLabelledCategory() throws {
        let greens = try XCTUnwrap(assets.first { $0.id == "stir-fried-greens" })
        for name in ["Chinese kale", "kana", "Chinese kale, cooked (kana)"] {
            XCTAssertEqual(FoodArtworkResolver.resolve(name: name, in: assets), .category(greens))
            let item = try ArtworkIdentityFixture.item(name: name)
            XCTAssertEqual(JournalRowArtwork.resolve(items: [item]), .library(.category(greens)))
        }
        XCTAssertEqual(greens.categoryLabel, "Produce")
    }

    func testLegacyRowsGainArtworkWithoutChangingFoodOrPhotoData() throws {
        for (name, identity) in [
            ("Pasta (linguine), cooked", "pasta"), ("half-portion white rice", "jasmine-rice"),
            ("White rice, cooked (half portion)", "jasmine-rice"), ("pork with brown gravy", "braised-pork")
        ] {
            let item = try ArtworkIdentityFixture.item(name: name, photo: true)
            let before = item
            XCTAssertNil(item.artworkID)
            XCTAssertEqual(FoodArtworkResolver.resolve(items: [item], in: assets).asset?.id, identity)
            XCTAssertEqual(JournalRowArtwork.resolve(items: [item]),
                           .library(FoodArtworkResolver.resolve(name: name, in: assets)))
            XCTAssertEqual(MealArtworkPresentation.resolve(photoPath: item.mealImage?.path, items: [item]),
                           .photo(ArtworkIdentityFixture.photoPath))
            XCTAssertEqual(item, before)
        }
    }

    private func isNeutral(_ resolution: FoodArtworkResolution) -> Bool {
        if case .neutral = resolution { return true }
        return false
    }
}

/// Opt-in private-corpus measurement. No corpus is bundled and no name is printed
/// or attached. The runner creates/removes the path marker under /tmp.
@MainActor
final class FoodArtworkPrivateCoverageTests: XCTestCase {
    func testShippedResolverCoverage() throws {
        let marker = URL(fileURLWithPath: "/tmp/morsel-260-coverage-path")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Private coverage input is not configured")
        }
        let path = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        struct LoggedName: Decodable { let name: String }
        let names = Set(try JSONDecoder().decode([LoggedName].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            .map(\.name))
        XCTAssertFalse(names.isEmpty)
        let assets = FoodArtworkCatalog.bundled
        XCTAssertEqual(assets.count, 130)
        var counts = ["specific": 0, "category": 0, "neutral": 0, "none": 0]
        for name in names {
            let key: String
            switch FoodArtworkResolver.resolve(name: name, in: assets) {
            case .food: key = "specific"
            case .category: key = "category"
            case .neutral: key = "neutral"
            case .none: key = "none"
            }
            counts[key, default: 0] += 1
        }
        XCTAssertEqual(counts.values.reduce(0, +), names.count)
        let result: [String: Any] = ["distinct_names": names.count, "counts": counts]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("ISSUE260_COVERAGE \(try XCTUnwrap(String(data: data, encoding: .utf8)))")
    }
}

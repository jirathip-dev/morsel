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
            let suffixes = [" (half-portion)", ", half-portion", " half-portion", ", sugar-free", ", low-fat",
                            " (small-portion)", ", cooked half portion"]
            for suffix in suffixes {
                XCTAssertEqual(FoodArtworkResolver.match(name: name + suffix, in: assets)?.id, identity)
            }
        }
    }

    func testEveryLeadingDescriptorUsesTheSharedClosedGrammar() {
        let descriptors = [
            "iced", "hot", "cooked", "boiled", "steamed", "grilled", "fried", "raw", "half portion", "half-portion",
            "stir-fried", "stir fried", "roasted", "baked", "toasted", "sauteed", "sautéed", "poached",
            "scrambled", "mashed", "fresh", "homemade", "smoked", "marinated", "reheated", "warm", "cold", "decaf",
            "unsweetened", "unsalted", "no sugar", "sugar-free", "low-fat", "sliced", "diced", "chopped",
            "shredded", "grated", "peeled", "drained", "rinsed", "frozen", "half", "portion", "small", "medium",
            "large", "regular", "single", "double", "triple", "side", "serving", "servings", "slice", "slices",
            "piece", "pieces", "bowl", "plate", "cup", "cups", "glass", "mug", "shot", "helping", "extra", "120 g"
        ]
        let study = FoodArtworkAsset(id: "test-study", name: "Test dish", aliases: [],
                                     category: "prepared", kind: .food)
        for descriptor in descriptors {
            for separator in [" ", ", "] {
                let name = descriptor + separator + "test dish, cooked"
                XCTAssertEqual(FoodArtworkResolver.match(name: name, in: [study]), study, name)
            }
        }
    }

    func testCompleteCookingIdentityWinsBeforeRemovingDescriptors() {
        let fried = FoodArtworkAsset(id: "fried-study", name: "Fried egg", aliases: [],
                                     category: "protein", kind: .food)
        let other = FoodArtworkAsset(id: "other-study", name: "Egg", aliases: [],
                                     category: "protein", kind: .food)
        XCTAssertEqual(FoodArtworkResolver.match(name: "fried egg", in: [fried, other]), fried)
        XCTAssertEqual(FoodArtworkResolver.match(name: "egg", in: [fried, other]), other)
    }

    func testLeadingNegativeNamesNeverCrossIdentitiesInEitherDirection() {
        let pairs = [("coffee cake", "coffee"), ("coffee", "cake"), ("milk tea", "boba-tea"),
                     ("boba tea", "milk-tea"), ("pad thai", "stir-fried-noodles"), ("stir-fried noodles", "pad-thai")]
        let prefixes = ["", "iced ", "hot ", "cooked ", "boiled ", "steamed ",
                        "grilled ", "fried ", "raw ", "half-portion "]
        let unknown = ["Uncatalogued lunar stew", "composite/shared restaurant plate", "coffee with rice and chicken"]
        for prefix in prefixes {
            for (name, wrongIdentity) in pairs {
                XCTAssertNotEqual(FoodArtworkResolver.resolve(name: prefix + name, in: assets).asset?.id,
                                  wrongIdentity, prefix + name)
            }
            for name in unknown {
                XCTAssertTrue(isNeutral(FoodArtworkResolver.resolve(name: prefix + name, in: assets)), prefix + name)
            }
        }
    }

    func testNounParentheticalsRequireTwoAliasesOfTheSameAsset() {
        let positives = [
            ("Iced americano (black, no sugar)", "coffee"),
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
            "composite/shared restaurant plate", "half-portion white riceish"
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

// MARK: - Issue #288 closed secondary-phrase tolerance

/// Issue #288 — a descriptive name may carry ONE trailing secondary phrase from
/// a closed class: an accompaniment after an attachment marker, a `for <use>`
/// purpose, or an `A / B` alternation whose remaining components are themselves
/// closed accompaniments/purposes (see `FoodArtworkSecondary`). The head still
/// has to reach a whole catalog name/alias, an unrecognized tail is never
/// dropped, and a tail naming a second identity fails closed. Behavioural RED
/// ran at the pristine #260 source (every case below fell to
/// `fallback-neutral`); the mutation battery lives in
/// `docs/evidence/issue-288-descriptive-names/README.md`.
@MainActor
final class FoodArtworkSecondaryPhraseTests: XCTestCase {
    private let assets = FoodArtworkCatalog.bundled

    /// The issue's own rows plus one case per tolerated secondary class.
    func testClosedSecondaryPhrasesReachTheirHeadIdentity() {
        let cases: [(String, String)] = [
            ("Satay skewers with peanut sauce", "satay"),
            ("satay skewers", "satay"),
            ("half-portion satay", "satay"),
            ("Olive oil / butter for cooking", "cooking-oil"),
            ("Olive oil for cooking", "cooking-oil"),
            ("Mashed potato with gravy", "mashed-potato"),
            ("Mixed salad with dressing", "green-salad"),
            ("Chili oil drizzle", "chili-oil"),
            ("Chili flakes & herbs", "chili-oil"),
            ("Greek yogurt with honey", "yogurt")
        ]
        for (name, identity) in cases {
            XCTAssertEqual(FoodArtworkResolver.resolve(name: name, in: assets).asset?.id, identity, name)
        }
    }

    /// An out-of-vocabulary tail, a tail naming a second identity and a head
    /// that reaches no whole term all keep the neutral sign.
    func testVetoedTailsAndHeadsNeverReachAnIdentity() {
        for name in [
            "Coffee with rice and chicken", "Coffee with rice and chicken only",
            "Cake with coffee", "Americano (black) with toast", "Som tum with peanuts",
            "chicken skewers", "butter for cooking", "skewers with peanut sauce",
            "coffee / tea", "Egg salad / creamy egg spread", "Fish balls / fish tofu / dumpling assortment"
        ] {
            XCTAssertTrue(isNeutral(FoodArtworkResolver.resolve(name: name, in: assets)), name)
        }
    }

    /// The veto is catalog-derived: the same tail is tolerated while it names no
    /// second identity and refused the moment it does.
    func testToleratedPhraseThatNamesASecondIdentityFailsClosed() {
        let dish = FoodArtworkAsset(id: "test-dish", name: "Test dish", aliases: [],
                                    category: "prepared", kind: .food)
        let fat = FoodArtworkAsset(id: "test-butter", name: "Butter", aliases: [],
                                   category: "dairy", kind: .food)
        XCTAssertEqual(FoodArtworkResolver.match(name: "test dish with butter", in: [dish])?.id, "test-dish")
        XCTAssertNil(FoodArtworkResolver.match(name: "test dish with butter", in: [dish, fat]))
        XCTAssertNil(FoodArtworkResolver.match(name: "test dish with lard and eggs", in: [dish]))
    }

    /// The shipped row seam keeps Variant A precedence and then paints these two
    /// rows with their resolved study, leaving the logged item untouched.
    func testIssueRowsPaintTheirStudyInTheRealRowSeam() throws {
        for (name, identity) in [("Satay skewers with peanut sauce", "satay"),
                                 ("Olive oil / butter for cooking", "cooking-oil")] {
            let item = try ArtworkIdentityFixture.item(name: name)
            let before = item
            XCTAssertEqual(FoodArtworkResolver.resolve(name: name, in: assets).asset?.id, identity, name)
            XCTAssertEqual(JournalRowArtwork.resolve(items: [item]),
                           .library(FoodArtworkResolver.resolve(name: name, in: assets)), name)
            XCTAssertEqual(item, before, "resolution never rewrites the logged name or its nutrition")
        }
    }

    private func isNeutral(_ resolution: FoodArtworkResolution) -> Bool {
        if case .neutral = resolution { return true }
        return false
    }
}

/// Opt-in private-corpus measurement. No corpus is bundled and no name is printed
/// or attached. The runner creates/removes the path marker under /tmp; the #260
/// invocation (`/tmp/morsel-260-coverage-path`) and the #288 one both work.
@MainActor
final class FoodArtworkPrivateCoverageTests: XCTestCase {
    func testShippedResolverCoverage() throws {
        let markers = ["/tmp/rev288-coverage-path", "/tmp/morsel-260-coverage-path"]
            .map { URL(fileURLWithPath: $0) }
        guard let marker = markers.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
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

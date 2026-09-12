import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #199 — offline food-illustration fallbacks. These tests run against
// the REAL production paths: the bundled #197 catalog + bundled PNGs, the
// shared `MealArtworkPresentation` decision the Today/History/detail renderers
// call, and the production `FoodArtworkImageView`/`MealArtworkSlot` renderers.
// Nothing here talks to a network or a generation API.
@MainActor
final class FoodArtworkFallbackTests: XCTestCase {
    private let assets = FoodArtworkCatalog.bundled

    private func item(_ name: String, kcal: Double = 100) -> MealItem {
        MealItem(
            itemID: UUID(), name: name, quantity: 1, unit: .serving,
            caloriesKcal: kcal, proteinG: 10, carbsG: 20, fatG: 5,
            fiberG: nil, sugarG: nil, confidence: 0.9, notes: nil
        )
    }

    private func asset(_ id: String) throws -> FoodArtworkAsset {
        try XCTUnwrap(assets.first { $0.id == id }, "catalog is missing \(id)")
    }

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
            XCTAssertEqual(matched.categoryLabel, testCase.label, "category artwork travels with its category label")
        }
    }

    // MARK: - Unknown + composite meals

    func testUnknownFoodResolvesToNoIllustration() {
        XCTAssertNil(FoodArtworkResolver.match(name: "pad thai from the corner stall", in: assets))
        XCTAssertEqual(FoodArtworkResolver.resolve(items: [item("pad thai")], in: assets), .none)
        XCTAssertEqual(
            MealArtworkPresentation.resolve(photoPath: nil, items: [item("pad thai")], assets: assets),
            .none,
            "an unknown meal keeps the shipped no-photo slot — no invented artwork"
        )
    }

    func testCompositeMealWithinOneCategoryUsesThatCategorysLabeledFallback() throws {
        let resolution = FoodArtworkResolver.resolve(items: [item("jasmine rice"), item("toast")], in: assets)
        XCTAssertEqual(resolution, .category(try asset("fallback-grains")))
    }

    func testCompositeMealAcrossCategoriesNeverDepictsOneArbitraryItem() throws {
        let resolution = FoodArtworkResolver.resolve(items: [item("jasmine rice"), item("grilled chicken")], in: assets)
        XCTAssertEqual(
            resolution, .none,
            "a mixed meal must not present one ingredient as the whole meal"
        )
        XCTAssertNotEqual(resolution, .food(try asset("jasmine-rice")))
        XCTAssertNotEqual(resolution, .food(try asset("grilled-chicken")))
    }

    func testMealWithAnyUnmatchedItemKeepsNoIllustration() {
        XCTAssertEqual(FoodArtworkResolver.resolve(items: [item("jasmine rice"), item("pad thai")], in: assets), .none)
    }

    func testSingleItemMealUsesItsOwnApprovedStudy() throws {
        XCTAssertEqual(FoodArtworkResolver.resolve(items: [item("coffee")], in: assets), .food(try asset("coffee")))
        XCTAssertEqual(FoodArtworkResolver.resolve(items: [], in: assets), .none)
    }

    // MARK: - Photo precedence

    func testRealMealPhotoStaysAuthoritativeOverIllustration() {
        let path = "\(UUID().uuidString)/\(UUID().uuidString).jpg"
        XCTAssertEqual(
            MealArtworkPresentation.resolve(photoPath: path, items: [item("jasmine rice")], assets: assets),
            .photo(path),
            "a stored meal photo always renders through the shipped thumbnail pipeline"
        )
    }

    func testMissingPhotoPathFallsToTheOfflineIllustration() throws {
        let rice = try asset("jasmine-rice")
        XCTAssertEqual(
            MealArtworkPresentation.resolve(photoPath: nil, items: [item("jasmine rice")], assets: assets),
            .illustration(.food(rice))
        )
        XCTAssertEqual(
            MealArtworkPresentation.resolve(photoPath: "", items: [item("jasmine rice")], assets: assets),
            .illustration(.food(rice)),
            "an empty path is a missing photo, not a photo"
        )
    }

    // MARK: - Offline bundle presence, both themes

    func testBundledCatalogIsTheApprovedSeventeenAssetLibrary() {
        XCTAssertEqual(assets.count, 17)
        XCTAssertEqual(assets.filter { $0.kind == .food }.count, 13)
        XCTAssertEqual(assets.filter { $0.kind == .fallback }.count, 4)
        XCTAssertEqual(Set(assets.map(\.id)).count, 17, "stable IDs are unique")
    }

    func testEveryApprovedAssetShipsBothThemesOfflineAt64px() {
        for asset in assets {
            for theme in FoodArtworkTheme.allCases {
                let label = "\(asset.id)-\(theme.rawValue)"
                let data = FoodArtworkImageStore.data(assetID: asset.id, theme: theme)
                XCTAssertNotNil(data, "\(label) must ship in the app bundle")
                let image = FoodArtworkImageStore.image(assetID: asset.id, theme: theme)
                XCTAssertEqual(
                    image?.size, CGSize(width: 64, height: 64),
                    "\(label) must render at the approved 64px export size"
                )
            }
            XCTAssertNotEqual(
                FoodArtworkImageStore.data(assetID: asset.id, theme: .paper),
                FoodArtworkImageStore.data(assetID: asset.id, theme: .night),
                "\(asset.id) carries a real Paper and Night study"
            )
        }
    }

    func testIllustrationThemeFollowsTheJournalTheme() {
        XCTAssertEqual(FoodArtworkTheme.resolve(.light), .paper)
        XCTAssertEqual(FoodArtworkTheme.resolve(.dark), .night)
        XCTAssertEqual(FoodArtworkTheme.paper.resourceName(assetID: "coffee"), "coffee-paper-64")
        XCTAssertEqual(FoodArtworkTheme.night.resourceName(assetID: "coffee"), "coffee-night-64")
    }

    // MARK: - No nutrition mutation

    func testResolvingIllustrationsDoesNotMutateLoggedFoodOrNutritionData() throws {
        let meal = MealRecord(
            mealLogID: UUID(), mealType: .lunch, eatenAt: Date(timeIntervalSince1970: 60), source: .manual,
            items: [item("jasmine rice", kcal: 220), item("grilled chicken", kcal: 250)]
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

    // MARK: - Production renderer paths

    func testProductionIllustrationRendererDrawsTheBundledStudy() throws {
        let image = try render(
            FoodArtworkImageView(assetID: "fallback-grains", label: "Grains category illustration", hint: "hint")
        )
        XCTAssertGreaterThan(
            nonWhitePixelCount(image), 64,
            "the bundled study must paint real ink through the production renderer"
        )
    }

    func testProductionIllustrationRendererStaysBlankForAnUnbundledStudy() throws {
        let image = try render(
            FoodArtworkImageView(assetID: "not-in-the-199-library", label: "unknown", hint: "hint")
        )
        XCTAssertEqual(nonWhitePixelCount(image), 0, "nothing is drawn for a study the bundle does not carry")
    }

    func testSharedArtworkSlotRendersTheIllustrationForAPhotoLessMeal() throws {
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil))
        let slot = MealArtworkSlot(
            repository: repository, userID: UUID(), photoPath: nil, items: [item("jasmine rice")]
        )
        let image = try render(slot)
        XCTAssertGreaterThan(
            nonWhitePixelCount(image), 64,
            "the shared Today/History/detail slot must draw the offline illustration"
        )
    }

    func testSharedArtworkSlotDrawsNothingForAnUnknownMeal() throws {
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil))
        let slot = MealArtworkSlot(
            repository: repository, userID: UUID(), photoPath: nil, items: [item("pad thai")]
        )
        let image = try render(slot)
        XCTAssertEqual(nonWhitePixelCount(image), 0)
    }

    func testIllustrationRendersWhileEveryNetworkRequestIsDenied() throws {
        DenyingURLProtocol.reset()
        URLProtocol.registerClass(DenyingURLProtocol.self)
        defer { URLProtocol.unregisterClass(DenyingURLProtocol.self) }

        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil))
        let slot = MealArtworkSlot(
            repository: repository, userID: UUID(), photoPath: nil, items: [item("jasmine rice")]
        )
        let image = try render(slot)

        XCTAssertGreaterThan(
            nonWhitePixelCount(image), 64,
            "the bundled illustration must render while every network request is denied"
        )
        XCTAssertEqual(
            DenyingURLProtocol.requestCount, 0,
            "the illustration path performs no fetch at all"
        )
    }

    // MARK: - Render helpers

    /// Renders a production view on a white ground so painted pixels are
    /// countable (the approved PNGs are transparent RGBA studies).
    private func render(_ view: some View) throws -> UIImage {
        let renderer = ImageRenderer(
            content: view.frame(width: 64, height: 64).background(Color.white)
        )
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage)
    }

    private func nonWhitePixelCount(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index] < 240 || pixels[index + 1] < 240 || pixels[index + 2] < 240 {
                count += 1
            }
        }
        return count
    }
}

/// Issue #199 offline proof: a URLProtocol that denies — and counts — every
/// request, so a render can be shown to complete with the network path closed.
private class DenyingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var intercepted = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return intercepted
    }

    static func reset() {
        lock.lock()
        intercepted = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.intercepted += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

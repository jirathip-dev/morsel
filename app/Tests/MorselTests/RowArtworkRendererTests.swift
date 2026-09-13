import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #199/#223 — bundled-bytes and production-renderer proofs: every
// approved study ships offline at 64px in both themes, and the real renderers
// (`FoodArtworkImageView`, the shared `MealArtworkSlot` row slot) paint ink
// without a network. The behavioural RED for these assertions ran at the
// pristine base in the lane's scratch worktree (see
// `docs/evidence/issue-223-row-illustrations/README.md`).
@MainActor
final class RowArtworkRendererTests: XCTestCase {
    private let assets = FoodArtworkCatalog.bundled

    private func item(_ name: String, mealImage: MealImage? = nil) -> MealItem {
        MealItem(
            itemID: UUID(), name: name, quantity: 1, unit: .serving,
            caloriesKcal: 100, proteinG: 10, carbsG: 20, fatG: 5,
            fiberG: nil, sugarG: nil, confidence: 0.9, notes: nil, mealImage: mealImage
        )
    }

    // MARK: - Offline bundle presence, both themes

    func testBundledCatalogIsTheApprovedEighteenAssetLibrary() {
        XCTAssertEqual(assets.count, 18)
        XCTAssertEqual(assets.filter { $0.kind == .food }.count, 13)
        XCTAssertEqual(assets.filter { $0.kind == .fallback }.count, 5)
        XCTAssertEqual(Set(assets.map(\.id)).count, 18, "stable IDs are unique")
        XCTAssertEqual(assets.filter { $0.isCategoryFallback }.count, 4, "four labeled category fallbacks")
        XCTAssertEqual(assets.filter { $0.isNeutralFallback }.count, 1, "exactly one neutral sentinel")
        XCTAssertEqual(
            assets.first { $0.isNeutralFallback }?.name, "Food · fallback",
            "the neutral sentinel keeps the catalog's approved fallback name"
        )
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

    func testSharedRowSlotRendersTheIllustrationForAPhotoLessMeal() throws {
        let image = try render(MealArtworkSlot(items: [item("jasmine rice")]))
        XCTAssertGreaterThan(
            nonWhitePixelCount(image), 64,
            "the shared Today/History/day-detail row slot must draw the offline illustration"
        )
    }

    func testSharedRowSlotRendersTheNeutralSignForAnUnknownOrMixedMeal() throws {
        let unknown = try render(MealArtworkSlot(items: [item("Focaccia bread")]))
        XCTAssertGreaterThan(
            nonWhitePixelCount(unknown), 64,
            "an off-catalog food row must render the neutral eating sign, never blank"
        )
        let mixed = try render(MealArtworkSlot(items: [item("jasmine rice"), item("grilled chicken")]))
        XCTAssertEqual(
            pixels(mixed), pixels(unknown),
            "a mixed meal uses the same neutral sign as an unknown one"
        )
    }

    func testPhotoPresentRowRendersTheIllustrationNotTheStoredPhoto() throws {
        let path = "\(UUID().uuidString)/\(UUID().uuidString).jpg"
        let row = try render(MealArtworkSlot(items: [item("jasmine rice", mealImage: MealImage(path: path))]))
        XCTAssertEqual(
            pixels(row),
            pixels(try render(FoodArtworkImageView(assetID: "jasmine-rice", label: "row", hint: "row"))),
            "a photo-present row renders the approved illustration, never the thumbnail pipeline"
        )
    }

    func testIllustrationRendersWhileEveryNetworkRequestIsDenied() throws {
        DenyingURLProtocol.reset()
        URLProtocol.registerClass(DenyingURLProtocol.self)
        defer { URLProtocol.unregisterClass(DenyingURLProtocol.self) }

        let image = try render(MealArtworkSlot(items: [item("jasmine rice")]))
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

    private func pixels(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func nonWhitePixelCount(_ image: UIImage) -> Int {
        guard let buffer = pixels(image) else { return 0 }
        var count = 0
        for index in stride(from: 0, to: buffer.count, by: 4) {
            if buffer[index] < 240 || buffer[index + 1] < 240 || buffer[index + 2] < 240 {
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

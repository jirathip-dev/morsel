import SwiftUI
import UIKit
import XCTest
@testable import Morsel

@MainActor
final class FoodLibraryIntegrationTests: XCTestCase {
    private struct Fixture {
        let key: String
        let names: [String]
        let desired: String
    }

    private let fixtures: [Fixture] = [
        .init(key: "pork-gravy", names: ["pork gravy"], desired: "braised-pork"),
        .init(key: "brown-gravy", names: ["pork with brown gravy"], desired: "braised-pork"),
        .init(key: "chinese-kale", names: ["Chinese kale"], desired: "stir-fried-greens"),
        .init(key: "kana", names: ["kana"], desired: "stir-fried-greens"),
        .init(key: "linguine", names: ["linguine"], desired: "pasta"),
        .init(key: "qualified-pasta", names: ["pasta (linguine), cooked"], desired: "pasta"),
        .init(key: "white-rice", names: ["white rice"], desired: "jasmine-rice"),
        .init(key: "half-rice", names: ["half-portion white rice"], desired: "jasmine-rice"),
        .init(key: "americano", names: ["Americano (black, no sugar, homemade)"], desired: "coffee"),
        .init(key: "coffee-cake", names: ["coffee cake"], desired: "cake"),
        .init(key: "milk-tea", names: ["milk tea"], desired: "milk-tea"),
        .init(key: "boba-tea", names: ["boba tea"], desired: "boba-tea"),
        .init(key: "pad-thai", names: ["pad thai"], desired: "pad-thai"),
        .init(key: "noodles", names: ["stir-fried noodles"], desired: "stir-fried-noodles"),
        .init(key: "generic-noodles", names: ["generic stir-fried noodles"], desired: "stir-fried-noodles"),
        .init(key: "unknown", names: ["Uncatalogued lunar stew"], desired: "fallback-neutral"),
        .init(key: "shared-plate", names: ["composite/shared restaurant plate"], desired: "fallback-neutral"),
        .init(key: "composite", names: ["white rice", "braised pork"], desired: "fallback-neutral"),
        .init(key: "dairy", names: ["Dairy"], desired: "fallback-dairy"),
        .init(key: "sweets", names: ["Sweets"], desired: "fallback-sweets"),
        .init(key: "prepared", names: ["Prepared"], desired: "fallback-prepared"),
        .init(key: "condiments", names: ["Condiments"], desired: "fallback-condiments")
    ]

    func testRealResolverNamedCasesAndProductionRowsInBothThemes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for (theme, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            for fixture in fixtures {
                try await capture(fixture, window: window, theme: theme, scheme: scheme)
            }
        }
    }

    private func capture(_ fixture: Fixture, window: UIWindow, theme: String, scheme: ColorScheme) async throws {
        let items = try fixture.names.map { try ArtworkIdentityFixture.item(name: $0) }
        let resolution = FoodArtworkResolver.resolve(items: items, in: FoodArtworkCatalog.bundled)
        let rowResolution = JournalRowArtwork.resolve(items: items)
        let actual = resolution.asset?.id ?? "none"
        let record: [String: Any] = [
            "case": fixture.key, "theme": theme, "names": fixture.names,
            "desired": fixture.desired, "actual": actual, "kind": kind(resolution),
            "row": rowDescription(rowResolution), "status": actual == fixture.desired ? "PASS" : "FINDING"
        ]
        let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("ISSUE266_RESOLVER \(try XCTUnwrap(String(data: json, encoding: .utf8)))")
        // This is an observation gate, not a matcher rewrite. Missing named positives
        // remain explicit FINDINGs in the raw report rather than being tuned to pass.
        XCTAssertNotEqual(rowResolution, .none, "every named case must paint honest artwork")
        let page = JournalPage(date: Date(timeIntervalSince1970: 1_783_200_000)) {
            VStack(alignment: .leading, spacing: 16) {
                JournalPageHeader(title: "Food log", leadingTitle: "Back", leadingAction: {})
                SectionHeading(title: "Lunch")
                if items.count == 1, let item = items.first {
                    MealItemRow(item: item, onEdit: { _ in })
                } else {
                    MealGroupView(
                        group: MealGroup(type: .lunch, meals: [
                            MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: Date(),
                                       source: .manual, items: items)
                        ]),
                        onEdit: { _ in }, onDelete: { _ in }, confirmationFor: { _ in nil }
                    )
                }
            }
        }
        window.rootViewController = UIHostingController(rootView: page.preferredColorScheme(scheme))
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 10_000)
        let attachment = XCTAttachment(image: image)
        attachment.name = "266-\(theme)-\(fixture.key)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(items.map(\.name), fixture.names)
    }

    func testNewCategoryLabelsAndUnknownCategoryRemainHonest() throws {
        let assets = FoodArtworkCatalog.bundled
        for category in ["dairy", "sweets", "prepared", "condiments"] {
            let fallback = try XCTUnwrap(assets.first { $0.id == "fallback-\(category)" })
            XCTAssertEqual(fallback.categoryLabel, category.capitalized)
            XCTAssertEqual(FoodArtworkResolver.resolve(name: category, in: assets), .category(fallback))
        }
        let neutral = try XCTUnwrap(assets.first { $0.isNeutralFallback })
        XCTAssertEqual(FoodArtworkResolver.resolve(name: "future-category", in: assets), .neutral(neutral))
        let unknown = FoodArtworkAsset(id: "future-fallback", name: "Future category", aliases: [],
                                       category: "future-category", kind: .fallback)
        XCTAssertEqual(unknown.categoryLabel, "Future-Category")
        XCTAssertEqual(FoodArtworkResolver.resolve(name: unknown.name, in: assets + [unknown]), .category(unknown))
        XCTAssertEqual(FoodArtworkResolver.resolve(name: "milk tea", in: assets).asset?.id, "milk-tea")
        XCTAssertEqual(FoodArtworkResolver.resolve(name: "boba tea", in: assets).asset?.id, "boba-tea")
        XCTAssertEqual(FoodArtworkResolver.resolve(name: "pad thai", in: assets).asset?.id, "pad-thai")
        XCTAssertEqual(FoodArtworkResolver.resolve(name: "stir-fried noodles", in: assets).asset?.id,
                       "stir-fried-noodles")
        XCTAssertNotEqual(FoodArtworkResolver.resolve(name: "coffee cake", in: assets).asset?.id, "coffee")
    }

    private func kind(_ resolution: FoodArtworkResolution) -> String {
        switch resolution {
        case .food: return "food"
        case .category: return "category"
        case .neutral: return "neutral"
        case .none: return "none"
        }
    }

    private func rowDescription(_ resolution: JournalRowArtwork) -> String {
        switch resolution {
        case let .study(study): return "study:\(study.rawValue)"
        case let .library(result): return "library:\(kind(result)):\(result.asset?.id ?? "none")"
        case .none: return "none"
        }
    }

    override func tearDown() async throws {
        try await Task.sleep(for: .milliseconds(500))
        try await super.tearDown()
    }
}

/// Resource-only A/B: run this identical compiled test/app with the original
/// 18-identity resources and the approved 130. No network or live account.
@MainActor
final class FoodLibraryCostTests: XCTestCase {
    func testCatalogLoadAndInitialTodayRenderingCost() async throws {
        var loads: [Double] = []
        for _ in 0..<31 {
            let start = CACurrentMediaTime()
            let assets = FoodArtworkCatalog.loadBundled(bundle: .main)
            loads.append((CACurrentMediaTime() - start) * 1_000)
            XCTAssertFalse(assets.isEmpty)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let item = try ArtworkIdentityFixture.item(name: "white rice")
        let snapshot = DashboardSnapshot(date: Date(), meals: [
            MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: Date(), source: .manual, items: [item])
        ], goal: nil)
        var renders: [Double] = []
        for index in 0..<11 {
            let model = DashboardViewModel(repository: MockDashboardRepository(snapshot: snapshot), userID: UUID())
            await model.load()
            let start = CACurrentMediaTime()
            window.rootViewController = UIHostingController(rootView:
                TodayView(viewModel: model, showSettings: {}, addMeal: {}).preferredColorScheme(.light))
            window.makeKeyAndVisible()
            window.rootViewController?.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            renders.append((CACurrentMediaTime() - start) * 1_000)
            XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 10_000)
            if index == 10 {
                let attachment = XCTAttachment(image: image)
                attachment.name = "266-today-\(FoodArtworkCatalog.bundled.count)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let record: [String: Any] = ["identities": FoodArtworkCatalog.bundled.count,
                                    "catalog_load_ms": loads, "today_mount_draw_ms": renders]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("ISSUE266_COST \(try XCTUnwrap(String(data: data, encoding: .utf8)))")
    }

    override func tearDown() async throws {
        try await Task.sleep(for: .milliseconds(500))
        try await super.tearDown()
    }
}

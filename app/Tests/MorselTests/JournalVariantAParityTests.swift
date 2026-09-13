import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #229 — the approved Variant A artwork + row contract, pinned at the
// runtime seam: the bundled A studies ship for both themes and resolve
// offline, the real food row measures/paints the A row (56pt artwork, name +
// portion, energy column with the chevron, macro line, hairline), and the
// saved-edit confirmation only paints on the row that saved. Shared render
// helpers live in `JournalRenderingTestCase`.
//
// The behavioural RED for the base-compatible assertions in this file was
// produced in a scratch copy of the pristine base (raw exits in the lane
// report; the probe carried the same assertions and failed there).
@MainActor
final class JournalVariantAParityTests: JournalRenderingTestCase {
    // MARK: - Fixtures

    func item(
        _ name: String,
        quantity: Double = 100,
        unit: FoodUnit = .gram,
        kcal: Double = 300,
        protein: Double? = 8,
        carbs: Double? = 46,
        fat: Double? = 9,
        confidence: Double? = 0.82,
        notes: String? = "Illustrative estimate; oil and bread thickness are uncertain.",
        source: MealSource = .photoVision,
        mealImage: MealImage? = nil
    ) -> MealItem {
        MealItem(
            itemID: UUID(), name: name, quantity: quantity, unit: unit,
            caloriesKcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat,
            fiberG: nil, sugarG: nil, confidence: confidence, notes: notes,
            source: source, mealImage: mealImage
        )
    }

    // MARK: - Approved A artwork: bundled, offline, both themes

    func testEveryApprovedAStudyShipsBothThemesOffline() {
        for study in JournalArtworkStudy.allCases {
            for theme in FoodArtworkTheme.allCases {
                let label = "\(study.rawValue)-\(theme.rawValue)"
                let data = JournalArtworkImageStore.data(study: study, theme: theme)
                XCTAssertNotNil(data, "\(label) must ship in the app bundle")
                let image = JournalArtworkImageStore.image(study: study, theme: theme)
                let expected = CGSize(
                    width: JournalArtworkImageStore.pixelSize,
                    height: JournalArtworkImageStore.pixelSize
                )
                XCTAssertEqual(image?.size, expected, "\(label) must ship at the rasterised export size")
            }
            XCTAssertNotEqual(
                JournalArtworkImageStore.data(study: study, theme: .paper),
                JournalArtworkImageStore.data(study: study, theme: .night),
                "\(study.rawValue) carries a real Paper and Night export"
            )
        }
        XCTAssertEqual(
            JournalArtworkImageStore.resourceName(study: .focaccia, theme: .night),
            "a-night-focaccia"
        )
    }

    func testApprovedAStudiesResolveByNameAndAlias() {
        let cases: [(String, JournalArtworkStudy)] = [
            ("Focaccia bread", .focaccia),
            ("focaccia", .focaccia),
            ("MORTADELLA", .mortadella),
            ("Stracciatella cheese", .stracciatella),
            ("Grilled vegetables", .vegetables),
            ("Grilled vegetable topping", .vegetables)
        ]
        for (name, expected) in cases {
            XCTAssertEqual(JournalArtworkCatalog.study(forName: name), expected, "\(name) maps to \(expected)")
            XCTAssertEqual(
                JournalRowArtwork.resolve(items: [item(name)]), .study(expected),
                "\(name)'s row must carry the approved A study"
            )
        }
        XCTAssertNil(JournalArtworkCatalog.study(forName: "jasmine rice"))
    }

    func testMixedAStudiesResolveToTheNeutralSignNeverOneArbitrarySubject() {
        let mixed = JournalRowArtwork.resolve(items: [item("Focaccia bread"), item("Mortadella")])
        XCTAssertEqual(mixed, .study(.unknown))
        XCTAssertEqual(
            JournalRowArtwork.resolve(items: [item("Mortadella"), item("Focaccia bread")]),
            mixed,
            "the mixed-meal answer cannot depend on item order"
        )
    }

    func testFoodsOutsideTheASetKeepTheirApprovedLibraryStudy() {
        let rice = JournalRowArtwork.resolve(items: [item("jasmine rice")])
        guard case let .library(.food(asset)) = rice else {
            return XCTFail("jasmine rice must keep its approved library study, got \(rice)")
        }
        XCTAssertEqual(asset.id, "jasmine-rice")
        let produce = JournalRowArtwork.resolve(items: [item("produce category")])
        guard case let .library(.category(fallback)) = produce else {
            return XCTFail("a category alias must keep its approved library fallback, got \(produce)")
        }
        XCTAssertEqual(fallback.id, "fallback-produce")
    }

    func testUnknownFoodResolvesToTheApprovedANeutralStudy() {
        XCTAssertEqual(
            JournalRowArtwork.resolve(items: [item("pad thai from the corner stall")]),
            .study(.unknown),
            "an unmatched food paints the approved neutral A study, never nothing"
        )
        XCTAssertEqual(JournalRowArtwork.resolve(items: []), JournalRowArtwork.none)
    }

    func testRowArtworkNeverTakesTheStoredMealPhoto() {
        let path = "\(UUID().uuidString)/\(UUID().uuidString).jpg"
        XCTAssertEqual(
            JournalRowArtwork.resolve(items: [item("Focaccia bread", mealImage: MealImage(path: path))]),
            .study(.focaccia),
            "a stored photo is not an input to the row decision (#223)"
        )
    }

    func testFoodRowGrowsWithDynamicTypeInsteadOfClipping() {
        let defaultHeight = fittedSize(of: MealItemRow(item: item("Focaccia bread"), onEdit: { _ in })).height
        XCTAssertEqual(defaultHeight, JournalRowMetrics.rowMinHeight, accuracy: 0.5)
        let accessible = fittedSize(
            of: MealItemRow(item: item("Focaccia bread"), onEdit: { _ in })
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        print("ISSUE229-MEASURE row ax3 width=\(accessible.width) height=\(accessible.height)")
        XCTAssertGreaterThan(
            accessible.height, JournalRowMetrics.rowMinHeight,
            "the row must grow at accessibility text sizes rather than clipping its content"
        )
        XCTAssertEqual(accessible.width, Self.phone.width, accuracy: 0.5, "the row keeps the journal width")
    }

    // MARK: - Row geometry + paint

    func testFoodRowMatchesTheVariantARowGeometry() {
        let row = fittedSize(of: MealItemRow(item: item("Focaccia bread"), onEdit: { _ in }))
        print("ISSUE229-MEASURE food row width=\(row.width) height=\(row.height)")
        XCTAssertEqual(row.width, Self.phone.width, accuracy: 0.5, "the row spans the journal column")
        XCTAssertEqual(
            row.height, JournalRowMetrics.rowMinHeight, accuracy: 0.5,
            "the row must measure the design's 87pt (56pt artwork + 10pt padding + the macro line)"
        )
        XCTAssertLessThanOrEqual(row.height, 90, "the #227 row-height ceiling still holds")
    }

    /// The design's row: the 56pt A study at the leading edge, the name, the
    /// portion, the macro line, and the right-aligned energy column.
    func testFoodRowPaintsTheApprovedAArtworkAtTheRowSize() throws {
        for (name, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            let painted = try XCTUnwrap(
                render(MealArtworkSlot(items: [item("Focaccia bread")], size: Self.artworkPoints), scheme: scheme),
                "the \(name) artwork must render"
            )
            let source = try XCTUnwrap(
                JournalArtworkImageStore.image(
                    study: .focaccia, theme: scheme == .dark ? .night : .paper
                )
            )
            let reference = draw(source, at: Self.artworkPoints)
            let diff = try pixelDifference(painted, reference)
            print("ISSUE229-MEASURE artwork \(name) meanDiff=\(diff.mean) maxDiff=\(diff.max)")
            XCTAssertLessThan(
                diff.mean, 12,
                "the \(name) row artwork must render the bundled export, not a substitute"
            )
            let paintedBounds = inkBounds(painted)
            let referenceBounds = inkBounds(reference)
            print("ISSUE229-MEASURE artwork \(name) bounds=\(paintedBounds) reference=\(referenceBounds)")
            XCTAssertEqual(
                paintedBounds.width, referenceBounds.width, accuracy: 2,
                "the \(name) study must keep its proportions at the row size"
            )
            XCTAssertEqual(
                paintedBounds.height, referenceBounds.height, accuracy: 2,
                "the \(name) study must keep its proportions at the row size"
            )
        }
    }

    func testRowArtworkPaintsEachApprovedSubjectDistinctly() throws {
        let rowSize = CGSize(width: Self.artworkPoints, height: Self.artworkPoints)
        let subject = try XCTUnwrap(render(MealArtworkSlot(items: [item("Focaccia bread")], size: rowSize.width)))
        let unknown = try XCTUnwrap(
            render(MealArtworkSlot(items: [item("pad thai from the corner stall")], size: rowSize.width))
        )
        try assertPixelsDiffer(subject, unknown, "an approved A subject must not paint the neutral placeholder")
        let mixed = try XCTUnwrap(
            render(MealArtworkSlot(items: [item("Focaccia bread"), item("Mortadella")], size: rowSize.width))
        )
        try assertPixelsEqual(mixed, unknown, "a mixed A meal paints the same neutral sign as an unknown food")
    }

    func testRowPaintFollowsTheItemThroughTheRealFoodRow() throws {
        let rowSize = CGSize(width: 326, height: 87)
        let rice = try XCTUnwrap(
            render(AnyView(JournalFoodRow(item: item("jasmine rice", kcal: 156))), size: rowSize)
        )
        XCTAssertGreaterThan(nonWhitePixels(rice), 200, "the real row must paint its content")
        let noMacros = try XCTUnwrap(
            render(
                AnyView(JournalFoodRow(item: item("jasmine rice", protein: nil, carbs: nil, fat: nil))),
                size: rowSize
            )
        )
        try assertPixelsDiffer(rice, noMacros, "the macro line must paint what the item carries")
    }

    func testSavedConfirmationPaintsOnlyTheSavedRow() throws {
        let saved = item("Mortadella")
        let other = item("Focaccia bread")
        let model = JournalPresentationModel()
        XCTAssertNil(model.savedConfirmation(for: saved.itemID))
        model.noteSaved(saved.itemID)
        XCTAssertEqual(model.savedConfirmation(for: saved.itemID), "Updated")
        XCTAssertNil(model.savedConfirmation(for: other.itemID), "no other row may claim the save")
        model.requestEdit(other)
        XCTAssertNil(model.savedConfirmation(for: saved.itemID), "opening another row clears the confirmation")

        let rowSize = CGSize(width: 326, height: 110)
        let plain = try XCTUnwrap(render(AnyView(JournalFoodRow(item: saved)), size: rowSize))
        let confirmed = try XCTUnwrap(
            render(AnyView(JournalFoodRow(item: saved, confirmation: "Updated")), size: rowSize)
        )
        try assertPixelsDiffer(plain, confirmed, "the confirmation line must paint inside the saved row")
    }

    func testVariantAReadoutsUseTheDesignsOwnForms() {
        // The design's `.evidence` confidence is a whole percentage and the
        // row's macro line is `P 8g · C 46g · F 9g`.
        XCTAssertEqual(MorselFormat.confidence(0.82), "82%")
        XCTAssertEqual(MorselFormat.confidence(0.35), "35%")
        XCTAssertEqual(MorselFormat.confidence(nil), "—")
        XCTAssertEqual(MorselFormat.macroLine(for: item("Focaccia bread")), "P 8g · C 46g · F 9g")
        XCTAssertEqual(
            MorselFormat.macroLine(for: item("Unknown", protein: nil, carbs: 10, fat: nil)), "C 10g"
        )
    }
}

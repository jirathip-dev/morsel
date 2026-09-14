import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #229 — the bundled journal fonts at the RUNTIME seam: every family the
// approved Variant A design uses must resolve to its bundled face (a wrong
// name silently falls back to a system font — the fidelity trap this AC
// targets), the EB Garamond `[wght]` variable axis the row's 18pt/500 name
// needs must be live, the italic face must render as a real italic, and the
// mono figures must be tabular. Shared render helpers live in
// `JournalRenderingTestCase`.
@MainActor
final class JournalFontRenderingTests: JournalRenderingTestCase {
    func testBundledJournalFamiliesResolveWithoutSubstitution() throws {
        // The app process registered the bundled OFL files at launch; each
        // family must resolve to a real face.
        let expected: [(String, String)] = [
            ("Caveat", "Caveat"),
            ("EB Garamond", "EB Garamond"),
            ("EBGaramond-Italic", "EB Garamond"),
            ("IBM Plex Mono", "IBM Plex Mono"),
            ("IBM Plex Mono Medium", "IBM Plex Mono Medium")
        ]
        for (probe, family) in expected {
            let font = try XCTUnwrap(UIFont(name: probe, size: 18), "\(probe) must be registered")
            XCTAssertEqual(font.familyName, family, "\(probe) must be the bundled family, not a fallback")
        }
        XCTAssertNil(UIFont(name: "This-Family-Does-Not-Exist", size: 18))
    }

    func testSerifVariableWeightAxisIsLiveAtTheRowsFiveHundredWeight() throws {
        // The registered family really exposes the wght axis…
        let base = try XCTUnwrap(UIFont(name: "EB Garamond", size: 18))
        let variedDescriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base as CTFont),
            [kCTFontVariationAttribute: [MorselFontCatalog.weightAxisKey: 500]] as CFDictionary
        )
        let varied = CTFontCreateWithFontDescriptor(variedDescriptor, 18, nil)
        let applied = (CTFontCopyVariation(varied) as? [NSNumber: NSNumber])?[MorselFontCatalog.weightAxisKey]
        XCTAssertEqual(applied?.doubleValue, 500, "the family must accept the wght axis value")
        XCTAssertEqual(
            CTFontCopyPostScriptName(varied) as String, "EBGaramond-Medium",
            "wght 500 is the family's own Medium instance, not a synthesized one"
        )
        // …and the app's own serif helper renders that axis, so the row's
        // 18pt/500 name is the bundled face at the approved weight.
        let medium = try XCTUnwrap(MorselFontCatalog.variableSerif(size: 18, weight: 500))
        let regular = try XCTUnwrap(MorselFontCatalog.variableSerif(size: 18, weight: 400))
        XCTAssertNotEqual(
            CTFontCopyPostScriptName(medium as CTFont) as String,
            CTFontCopyPostScriptName(regular as CTFont) as String,
            "the shipped helper must resolve two different faces for 400 and 500"
        )
        try assertPixelsDiffer(
            try render(font: medium, text: "Focaccia bread", size: 18, width: 200, height: 30),
            try render(font: regular, text: "Focaccia bread", size: 18, width: 200, height: 30),
            "weight 500 must render as a heavier face than 400"
        )
    }

    func testItalicFaceIsTheBundledItalicAndRendersApartFromUpright() throws {
        let italic = try XCTUnwrap(UIFont(name: "EBGaramond-Italic", size: 14))
        let upright = try XCTUnwrap(UIFont(name: "EB Garamond", size: 14))
        XCTAssertTrue(
            italic.fontDescriptor.symbolicTraits.contains(.traitItalic),
            "the italic face must carry the italic trait"
        )
        XCTAssertFalse(upright.fontDescriptor.symbolicTraits.contains(.traitItalic))
        try assertPixelsDiffer(
            try render(font: italic, text: "source: manual", size: 14, width: 160, height: 24),
            try render(font: upright, text: "source: manual", size: 14, width: 160, height: 24),
            "the italic face must render a different shape"
        )
    }

    func testMonoNumeralsAreTabularAndPaint() throws {
        let mono = try XCTUnwrap(UIFont(name: "IBM Plex Mono", size: 14))
        let wide = "1111".size(withAttributes: [.font: mono])
        let narrow = "8888".size(withAttributes: [.font: mono])
        XCTAssertEqual(wide.width, narrow.width, accuracy: 0.01, "Plex figures are tabular")
        let digits = try render(font: mono, text: "300", size: 14, width: 48, height: 20)
        XCTAssertGreaterThan(nonWhitePixels(digits), 8, "the mono digits must actually paint")
    }
}

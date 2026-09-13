import SwiftUI
import UIKit

// Issue #229 — the approved Variant A ("ink-wash") journal artwork, ported
// from design commit 68be41d1 (`docs/design/tactile-journal/assets/`) and
// preserved in this checkout at
// `docs/evidence/issue-229-native-parity-a/reference/assets/`. The approved
// studies are the five A subjects (focaccia, mortadella, stracciatella,
// grilled vegetables, and the neutral unknown sign) in Paper and Night
// variants.
//
// FORMAT DECISION (issue #229): Variant A ships the studies as SVG, which
// SwiftUI cannot render. They are bundled as RASTERISED PNG exports at 224×224
// (`docs/evidence/issue-229-native-parity-a/tools/render-a-art.mjs`, resvg-js,
// deterministic — see the README in
// the evidence directory), which is 4× the 56pt row target and ≥3× the 64pt
// summary placement, so every bundled placement DOWNSAMPLES at 1x/2x/3x device
// scales and stays crisp at the row size in both themes. A vector (PDF) port
// would have added a second asset pipeline for no measurable gain at 56pt.
//
// Lookup is offline and stable: a normalized name/alias table plus a bundled
// `Bundle.url(forResource:)` read. No network, no generation service, no
// logged-value reads — the resolver only ever takes item NAMES.

/// One approved A study. `unknown` is the neutral sign (an eating sign for an
/// unknown or mixed meal), never an identified food.
enum JournalArtworkStudy: String, CaseIterable, Sendable {
    case focaccia
    case mortadella
    case stracciatella
    case vegetables
    case unknown

    /// Detail/edit stand-in title (ART-SPEC: labels the depicted subject; the
    /// neutral sign keeps the library's fallback name and is never presented
    /// as an identified food).
    var displayName: String {
        switch self {
        case .focaccia: return "Focaccia bread"
        case .mortadella: return "Mortadella"
        case .stracciatella: return "Stracciatella cheese"
        case .vegetables: return "Grilled vegetables"
        case .unknown: return "Food · fallback"
        }
    }

    /// The neutral eating sign (never an identified food).
    var isNeutralSign: Bool { self == .unknown }

    /// ART-SPEC label contract: a food study is labeled with its name; the
    /// neutral sign is labeled as a fallback and never claims a food.
    var accessibilityLabel: String {
        switch self {
        case .focaccia: return "Focaccia bread illustration"
        case .mortadella: return "Mortadella illustration"
        case .stracciatella: return "Stracciatella cheese illustration"
        case .vegetables: return "Grilled vegetables illustration"
        case .unknown: return "Food fallback illustration"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .unknown:
            return "Neutral eating sign for an unknown or mixed meal, not a meal photo"
        case .focaccia, .mortadella, .stracciatella, .vegetables:
            return "Generic artwork, not a meal photo"
        }
    }
}

/// The approved A study library: normalized lookup terms → study.
enum JournalArtworkCatalog {
    /// Lookup terms as authored (the design fixture's names plus the owner's
    /// logged names from the #223 record). Matching is trimmed, lowercased and
    /// inner-whitespace collapsed through the shared #199 normalizer.
    static let terms: [String: JournalArtworkStudy] = [
        "focaccia": .focaccia,
        "focaccia bread": .focaccia,
        "mortadella": .mortadella,
        "stracciatella": .stracciatella,
        "stracciatella cheese": .stracciatella,
        "vegetables": .vegetables,
        "grilled vegetables": .vegetables,
        "grilled vegetable topping": .vegetables,
        "unknown": .unknown,
        "unknown food": .unknown,
        "mixed meal": .unknown
    ]

    static func study(forName name: String) -> JournalArtworkStudy? {
        terms[FoodArtworkCatalog.normalize(name)]
    }

    /// All items carry an approved A study: one unique study → it; more than
    /// one → the neutral sign (never one arbitrary ingredient, per #223).
    static func study(for items: [MealItem]) -> JournalArtworkStudy? {
        let studies = items.map { study(forName: $0.name) }
        guard !items.isEmpty, studies.allSatisfy({ $0 != nil }) else { return nil }
        let unique = Set(studies.compactMap { $0 })
        return unique.count == 1 ? unique.first : .unknown
    }
}

/// What a scoped row/detail surface may paint for an item list.
enum JournalRowArtwork: Equatable, Sendable {
    /// An approved A study (including the neutral unknown sign).
    case study(JournalArtworkStudy)
    /// The #199/#223 library outcome (food study or labeled category
    /// fallback) — used for foods outside the approved A set.
    case library(FoodArtworkResolution)
    /// Nothing to depict (no items, or no bundled library).
    case none

    /// Issue #229 resolution order, mirroring the #199/#223 semantics:
    ///  1. every item carries an approved A study → that study (or the
    ///     neutral sign when the studies disagree);
    ///  2. otherwise the #199/#223 library rules run; a neutral outcome is
    ///     painted with the approved A `unknown` study, food/category
    ///     outcomes keep their approved library artwork;
    ///  3. an empty item list resolves to nothing.
    static func resolve(
        items: [MealItem],
        assets: [FoodArtworkAsset] = FoodArtworkCatalog.bundled
    ) -> JournalRowArtwork {
        guard !items.isEmpty, !assets.isEmpty else { return .none }
        if let study = JournalArtworkCatalog.study(for: items) {
            return .study(study)
        }
        switch FoodArtworkResolver.resolve(items: items, in: assets) {
        case .none:
            return .none
        case .neutral:
            return .study(.unknown)
        case let resolution:
            return .library(resolution)
        }
    }
}

/// Offline bundle reads for the approved A exports. A `Bundle` lookup only:
/// no URLSession, no image host, nothing to wait for.
enum JournalArtworkImageStore {
    /// The bundled export size (see the FORMAT DECISION above).
    static let pixelSize = 224
    /// The approved A row placement (design: `.row img` 56×56).
    static let displaySize: CGFloat = 56

    private static let cache = NSCache<NSString, UIImage>()

    static func resourceName(study: JournalArtworkStudy, theme: FoodArtworkTheme) -> String {
        "a-\(theme.rawValue)-\(study.rawValue)"
    }

    static func data(
        study: JournalArtworkStudy,
        theme: FoodArtworkTheme,
        bundle: Bundle = .main
    ) -> Data? {
        guard let url = bundle.url(
            forResource: resourceName(study: study, theme: theme), withExtension: "png"
        ) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    static func image(
        study: JournalArtworkStudy,
        theme: FoodArtworkTheme,
        bundle: Bundle = .main
    ) -> UIImage? {
        let key = "\(study.rawValue)-\(theme.rawValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let data = data(study: study, theme: theme, bundle: bundle),
              let image = UIImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Draws one bundled A study at the row placement with the label contract.
struct JournalArtworkImageView: View {
    let study: JournalArtworkStudy
    var size: CGFloat = JournalArtworkImageStore.displaySize

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = JournalArtworkImageStore.image(
                study: study, theme: FoodArtworkTheme.resolve(colorScheme)
            ) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text(study.accessibilityLabel))
        .accessibilityHint(Text(study.accessibilityHint))
    }
}

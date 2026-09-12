import Foundation

// Issue #199 — offline food illustrations.
//
// The approved #197 ink/wash library (`docs/art/food-library-v2/`) ships in the
// app bundle as fixed 64px Paper/Night PNGs (byte-identical copies of the
// approved exports — no re-render, no runtime generation) plus its committed
// `catalog.json`. This file resolves a logged food name to ONE stable artwork
// ID with no network asset dependency and no added per-log latency: the lookup
// is a pure in-memory match over the catalog.
//
// Mapping rules (deterministic, catalog order, documented in the lane evidence):
//  1. exact name match first, then exact alias match — both normalized by
//     trimming, lowercasing and collapsing inner whitespace. First match in
//     catalog order wins, so a stable ID is returned for every input.
//  2. a catalog category alias (`produce category`, …) resolves to that
//     category's labeled fallback.
//  3. a meal with two or more distinct food artworks never depicts one
//     arbitrary ingredient: when every matched food shares ONE category the
//     meal shows that category's labeled fallback; across categories the meal
//     shows no illustration.
//  4. an unmatched item ("unknown food") shows no illustration at all: the
//     approved library carries no unknown/other study, and deriving a category
//     from a free-text name would be an inference this feature must not make.
//     The row keeps its existing no-photo rendering.
//
// Nothing here reads or writes logged food or nutrition values — the resolver
// only ever takes item NAMES and returns an artwork ID.

/// Catalog `kind` — a specific food study vs. a category fallback study.
enum FoodArtworkKind: String, Decodable, Equatable, Sendable {
    case food
    case fallback
}

/// One approved catalog entry (the fields the resolver needs; the rest of the
/// committed catalog.json — provenance, exports, dimensions — is not decoded).
struct FoodArtworkAsset: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let aliases: [String]
    let category: String
    let kind: FoodArtworkKind

    var isCategoryFallback: Bool { kind == .fallback }

    /// ART-SPEC: category artwork always travels with its category label.
    var categoryLabel: String {
        FoodArtworkAsset.categoryLabels[category] ?? category.capitalized
    }

    static let categoryLabels: [String: String] = [
        "produce": "Produce",
        "drinks": "Drinks",
        "grains": "Grains",
        "protein": "Protein",
        "soup": "Soup"
    ]
}

/// The bundled issue #197 catalog: the single source of truth for IDs, names,
/// aliases, categories and kinds.
enum FoodArtworkCatalog {
    static let bundledFileName = "catalog"
    static let bundledFileExtension = "json"

    /// Decoded once per process from the bundled catalog.json (offline).
    static let bundled: [FoodArtworkAsset] = loadBundled(bundle: .main)

    static func loadBundled(bundle: Bundle) -> [FoodArtworkAsset] {
        guard let url = bundle.url(forResource: bundledFileName, withExtension: bundledFileExtension),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode(CatalogFile.self, from: data))?.assets ?? []
    }

    /// Matching key: trimmed, lowercased, inner whitespace collapsed. Locale
    /// independent so the same food always maps to the same artwork ID.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private struct CatalogFile: Decodable {
        let assets: [FoodArtworkAsset]
    }
}

/// What a photo-less meal is allowed to show.
enum FoodArtworkResolution: Equatable, Sendable {
    /// One specific approved food study.
    case food(FoodArtworkAsset)
    /// A labeled category fallback (never presented as an identified food).
    case category(FoodArtworkAsset)
    /// No honest illustration exists for this meal.
    case none

    var asset: FoodArtworkAsset? {
        switch self {
        case let .food(asset), let .category(asset): return asset
        case .none: return nil
        }
    }
}

enum FoodArtworkResolver {
    /// First exact name match, then exact alias match, in catalog order.
    static func match(name: String, in assets: [FoodArtworkAsset]) -> FoodArtworkAsset? {
        let key = FoodArtworkCatalog.normalize(name)
        guard !key.isEmpty else { return nil }
        if let byName = assets.first(where: { FoodArtworkCatalog.normalize($0.name) == key }) {
            return byName
        }
        return assets.first { asset in
            asset.aliases.contains { FoodArtworkCatalog.normalize($0) == key }
        }
    }

    /// Meal-level resolution (rules 1–4 in the file header).
    static func resolve(items: [MealItem], in assets: [FoodArtworkAsset]) -> FoodArtworkResolution {
        guard !items.isEmpty, !assets.isEmpty else { return .none }
        let matches = items.map { match(name: $0.name, in: assets) }
        guard matches.allSatisfy({ $0 != nil }) else {
            // An unmatched item means the meal contains food this library
            // cannot honestly depict: draw nothing rather than a partial meal.
            return .none
        }
        let resolved = matches.compactMap { $0 }
        let foods = uniqueByID(resolved.filter { $0.kind == .food })
        if foods.count == 1 {
            return .food(foods[0])
        }
        if foods.count > 1 {
            // Composite meal: never one arbitrary ingredient. A single shared
            // category may show that category's labeled fallback; otherwise
            // nothing at all.
            guard let category = foods.first?.category,
                  foods.allSatisfy({ $0.category == category }),
                  let fallback = categoryFallback(for: category, in: assets) else {
                return .none
            }
            return .category(fallback)
        }
        let categorised = uniqueByID(resolved.filter { $0.kind == .fallback })
        return categorised.count == 1 ? .category(categorised[0]) : .none
    }

    /// First occurrence per stable ID — catalog order stays the tiebreaker.
    private static func uniqueByID(_ assets: [FoodArtworkAsset]) -> [FoodArtworkAsset] {
        var seen = Set<String>()
        return assets.filter { seen.insert($0.id).inserted }
    }

    static func categoryFallback(for category: String, in assets: [FoodArtworkAsset]) -> FoodArtworkAsset? {
        assets.first { $0.kind == .fallback && $0.category == category }
    }
}

/// The renderer decision shared by Today, History and the item/detail sheet:
/// a stored meal photo is always authoritative; the illustration appears only
/// for missing-photo entries; unknown meals keep today's empty slot.
enum MealArtworkPresentation: Equatable, Sendable {
    case photo(String)
    case illustration(FoodArtworkResolution)
    case none

    static func resolve(
        photoPath: String?,
        items: [MealItem],
        assets: [FoodArtworkAsset] = FoodArtworkCatalog.bundled
    ) -> MealArtworkPresentation {
        if let photoPath, !photoPath.isEmpty {
            return .photo(photoPath)
        }
        switch FoodArtworkResolver.resolve(items: items, in: assets) {
        case .none:
            return .none
        case let resolution:
            return .illustration(resolution)
        }
    }
}

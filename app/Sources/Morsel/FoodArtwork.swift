import Foundation

// Issue #199 — offline food illustrations; issue #223 — food rows are ALWAYS
// illustrated and a real meal photo appears only inside meal/item detail.
//
// The approved #197 ink/wash library (`docs/art/food-library-v2/`) ships in the
// app bundle as fixed 64px Paper/Night PNGs (byte-identical copies of the
// approved exports — no re-render, no runtime generation) plus its committed
// `catalog.json`. This file resolves a logged food name to ONE stable artwork
// ID with no network asset dependency and no added per-log latency: the lookup
// is a pure in-memory match over the catalog.
//
// Issue #241 precedence (offline and read-only):
//  1. exact, case-sensitive explicit ID membership in this bundled catalog;
//  2. unambiguous normalized full name/alias, including the closed Americano
//     descriptor grammar below (never substring/ingredient matching);
//  3. unambiguous catalog category name/alias;
//  4. approved neutral sign. Unsupported IDs take steps 2–4, never a file path.
// Composite meals keep the existing shared-category/neutral rules; empty
// lists have nothing to depict. No logged name, nutrition or photo is changed.

/// Catalog `kind` — a specific food study vs. a fallback study.
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

    /// Issue #223 — the catalog's neutral sentinel (`category: neutral`). It
    /// is an eating sign for unknown/mixed meals, not a nutritional category
    /// and never an identified food.
    var isNeutralFallback: Bool { kind == .fallback && category == Self.neutralCategory }

    /// A labeled category fallback (Produce / Grains / …). The neutral
    /// sentinel is deliberately excluded: it travels without a category claim.
    var isCategoryFallback: Bool { kind == .fallback && !isNeutralFallback }

    static let neutralCategory = "neutral"

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

/// What a photo-less meal or item is allowed to show.
enum FoodArtworkResolution: Equatable, Sendable {
    /// One specific approved food study.
    case food(FoodArtworkAsset)
    /// A labeled category fallback (never presented as an identified food).
    case category(FoodArtworkAsset)
    /// Issue #223 — the approved neutral eating sign for an unknown food or a
    /// mixed meal. It is a fallback: never an identified food, and it carries
    /// no category claim.
    case neutral(FoodArtworkAsset)
    /// Nothing to depict at all (no items).
    case none

    var asset: FoodArtworkAsset? {
        switch self {
        case let .food(asset), let .category(asset), let .neutral(asset): return asset
        case .none: return nil
        }
    }
}

enum FoodArtworkResolver {
    /// Explicit IDs are never normalized: an older bundle ignores unknown IDs.
    static func explicitAsset(_ identity: String?, in assets: [FoodArtworkAsset]) -> FoodArtworkAsset? {
        guard let identity else { return nil }
        return assets.first { $0.id == identity }
    }

    /// Whole terms only. Colliding names/aliases cannot select an arbitrary dish.
    static func match(name: String, in assets: [FoodArtworkAsset]) -> FoodArtworkAsset? {
        let key = FoodArtworkCatalog.normalize(name)
        guard !key.isEmpty else { return nil }
        let matches = assets.filter { asset in
            FoodArtworkCatalog.normalize(asset.name) == key
                || asset.aliases.contains { FoodArtworkCatalog.normalize($0) == key }
        }
        guard matches.count <= 1 else { return nil }
        if let match = matches.first { return match }
        if isAmericano(key) { return explicitAsset("coffee", in: assets) }
        return categoryFallback(for: key, in: assets)
    }

    /// Only an entire Americano name, optionally followed by a closed list of
    /// preparation descriptors. Unknown tokens, nested/trailing text and empty
    /// components fail closed: "Americano (cake)" is not a drink identification.
    private static func isAmericano(_ key: String) -> Bool {
        if key == "americano" { return true }
        let prefix = "americano ("
        guard key.hasPrefix(prefix), key.hasSuffix(")") else { return false }
        let descriptors = key.dropFirst(prefix.count).dropLast().split(separator: ",", omittingEmptySubsequences: false)
        let allowed: Set<String> = ["black", "no sugar", "homemade", "unsweetened", "iced", "hot", "decaf"]
        return !descriptors.isEmpty && descriptors.allSatisfy {
            allowed.contains(FoodArtworkCatalog.normalize(String($0)))
        }
    }

    static func resolve(
        name: String, artworkID: String? = nil, in assets: [FoodArtworkAsset]
    ) -> FoodArtworkResolution {
        guard let matched = explicitAsset(artworkID, in: assets) ?? match(name: name, in: assets) else {
            return neutral(in: assets)
        }
        if matched.kind == .food {
            return .food(matched)
        }
        return matched.isNeutralFallback ? .neutral(matched) : .category(matched)
    }

    /// Meal-level resolution (rules 1–5 in the file header). One food shows its
    /// own study; several foods that share one category show that category's
    /// labeled fallback; anything unknown or mixed shows the neutral sign.
    static func resolve(items: [MealItem], in assets: [FoodArtworkAsset]) -> FoodArtworkResolution {
        guard !items.isEmpty, !assets.isEmpty else { return .none }
        let resolved = items.map { resolve(name: $0.name, artworkID: $0.artworkID, in: assets) }
        if resolved.contains(where: { if case .neutral = $0 { true } else { false } }) {
            return neutral(in: assets)
        }
        let foods = uniqueByID(resolved.compactMap { if case let .food(asset) = $0 { asset } else { nil } })
        let categories = uniqueByID(resolved.compactMap { if case let .category(asset) = $0 { asset } else { nil } })
        if categories.isEmpty {
            if foods.count == 1, let food = foods.first {
                return .food(food)
            }
            // Composite meal: one shared category may show that category's
            // labeled fallback; mixed categories never depict a single item.
            guard let category = foods.first?.category,
                  foods.allSatisfy({ $0.category == category }),
                  let fallback = categoryFallback(for: category, in: assets) else {
                return neutral(in: assets)
            }
            return .category(fallback)
        }
        if foods.isEmpty, categories.count == 1 {
            // The meal itself was logged at category level.
            return .category(categories[0])
        }
        return neutral(in: assets)
    }

    /// The approved neutral eating sign, when the bundle carries it.
    static func neutral(in assets: [FoodArtworkAsset]) -> FoodArtworkResolution {
        assets.first(where: { $0.isNeutralFallback }).map(FoodArtworkResolution.neutral) ?? .none
    }

    /// First occurrence per stable ID — catalog order stays the tiebreaker.
    private static func uniqueByID(_ assets: [FoodArtworkAsset]) -> [FoodArtworkAsset] {
        var seen = Set<String>()
        return assets.filter { seen.insert($0.id).inserted }
    }

    static func categoryFallback(for category: String, in assets: [FoodArtworkAsset]) -> FoodArtworkAsset? {
        let matches = assets.filter { $0.isCategoryFallback && $0.category == category }
        return matches.count == 1 ? matches.first : nil
    }
}

/// The renderer decision shared by the item/detail sheet and the rows.
enum MealArtworkPresentation: Equatable, Sendable {
    case photo(String)
    case illustration(FoodArtworkResolution)
    case none

    /// DETAIL/EDIT presentation (issue #199 semantics, kept by #223): a stored
    /// meal photo is authoritative for the food the user is inspecting; the
    /// illustration stands in only when no photo exists.
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

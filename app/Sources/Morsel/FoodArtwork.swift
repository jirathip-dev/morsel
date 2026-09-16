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
//
// Issue #260 keeps that order and adds ONE bounded tolerance: before each step a
// recognized TRAILING qualifier (a parenthetical, a cooking method, a
// portion/size token, a metric quantity) may be dropped, one at a time. The
// closed grammar below holds no food nouns, so a distinct compound food keeps
// its whole meaning (`coffee cake` is never a coffee) and ambiguity still
// resolves to neutral instead of a guess.

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
    /// Issue #260: a name may additionally carry recognized trailing qualifiers
    /// (see below). Those are dropped one at a time and every remaining whole
    /// term is tried in the same precedence, so a descriptive name reaches the
    /// entry it describes without ever matching a substring.
    static func match(name: String, in assets: [FoodArtworkAsset]) -> FoodArtworkAsset? {
        let key = FoodArtworkCatalog.normalize(name)
        guard !key.isEmpty else { return nil }
        let terms = [key] + qualifiedTerms(of: key)
        let matches = uniqueByID(terms.flatMap { term in assets.filter { matchesWholeTerm($0, term) } })
        guard matches.count <= 1 else { return nil }
        if let match = matches.first { return match }
        if terms.contains(where: isAmericano) { return explicitAsset("coffee", in: assets) }
        for term in terms {
            if let fallback = categoryFallback(for: term, in: assets) { return fallback }
        }
        return nil
    }

    private static func matchesWholeTerm(_ asset: FoodArtworkAsset, _ term: String) -> Bool {
        FoodArtworkCatalog.normalize(asset.name) == term
            || asset.aliases.contains { FoodArtworkCatalog.normalize($0) == term }
    }

    // MARK: - Issue #260 trailing qualifiers

    /// Cooking/preparation descriptors and portion/size tokens a logging agent
    /// may append to an otherwise whole food name. Deliberately a closed list of
    /// NON-food words: a distinct compound food keeps its whole meaning, because
    /// `cake`, `juice`, `bread` and every other noun are absent here and can
    /// never be dropped (`coffee cake` stays whole and unresolved).
    private static let trailingDescriptors: Set<String> = [
        "cooked", "steamed", "grilled", "fried", "stir-fried", "stir fried", "boiled", "roasted",
        "baked", "toasted", "sauteed", "sautéed", "poached", "scrambled", "mashed", "raw", "fresh",
        "homemade", "smoked", "marinated", "reheated", "warm", "hot", "iced", "cold", "decaf",
        "unsweetened", "unsalted", "no sugar", "sugar-free", "low-fat", "sliced", "diced", "chopped",
        "shredded", "grated", "peeled", "drained", "rinsed", "frozen", "half", "half portion",
        "portion", "small", "medium", "large", "regular", "single", "double", "triple", "side",
        "serving", "servings", "slice", "slices", "piece", "pieces", "bowl", "plate", "cup", "cups",
        "glass", "mug", "shot", "helping", "extra"
    ]

    /// Metric/imperial measures for a quantity qualifier ("120 g", "1.5 cups").
    private static let quantityUnits: Set<String> = [
        "g", "gram", "grams", "kg", "ml", "l", "oz", "lb", "lbs", "kcal", "cal", "tbsp", "tsp",
        "cup", "cups"
    ]

    /// One recognized qualifier phrase: a comma-separated list of known
    /// descriptors or quantities. Empty components, unknown words ("cake") and
    /// unknown units fail closed, so nothing is dropped from a name that does
    /// not end in the closed grammar.
    private static func isQualifierPhrase(_ text: String) -> Bool {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            let token = FoodArtworkCatalog.normalize(String(part))
            return !token.isEmpty
                && (trailingDescriptors.contains(token) || isQuantity(token))
        }
    }

    /// "120 g", "1.5 cups": a number plus a measure. A bare number or a bare
    /// unit is not a qualifier.
    private static func isQuantity(_ token: String) -> Bool {
        let parts = token.split(separator: " ").map(String.init)
        if parts.count == 2, Double(parts[0]) != nil { return quantityUnits.contains(parts[1]) }
        guard parts.count == 1, parts[0].count > 1, Double(parts[0].dropLast()) != nil else { return false }
        return quantityUnits.contains(String(parts[0].suffix(1)))
    }

    /// Drops the longest recognized descriptor suffix of a comma-free name —
    /// never the whole name, so the head term always survives.
    private static func droppingTrailingDescriptor(_ text: String) -> String? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        for length in stride(from: min(2, words.count - 1), through: 1, by: -1) where
            isQualifierPhrase(words.suffix(length).joined(separator: " ")) {
            return FoodArtworkCatalog.normalize(words.dropLast(length).joined(separator: " "))
        }
        return nil
    }

    /// The same name with ONE trailing qualifier removed: a trailing
    /// parenthetical group, a trailing comma-separated descriptor, or a bare
    /// trailing descriptor. `nil` when the name ends in no recognized qualifier.
    private static func strippingTrailingQualifier(_ key: String) -> String? {
        if key.hasSuffix(")"), let open = key.lastIndex(of: "("), open > key.startIndex {
            let head = FoodArtworkCatalog.normalize(String(key[key.startIndex..<open]))
            let inner = String(key[key.index(after: open)..<key.index(before: key.endIndex)])
            guard !head.isEmpty, !head.contains("("), !head.contains(")"),
                  !inner.contains("("), !inner.contains(")"), isQualifierPhrase(inner) else { return nil }
            return head
        }
        if let comma = key.lastIndex(of: ",") {
            let tail = FoodArtworkCatalog.normalize(String(key[key.index(after: comma)...]))
            guard isQualifierPhrase(tail) else { return nil }
            let head = FoodArtworkCatalog.normalize(String(key[key.startIndex..<comma]))
            return head.isEmpty ? nil : head
        }
        return droppingTrailingDescriptor(key)
    }

    /// Successive qualifier removals, longest first, bounded: a name can carry
    /// at most a handful of trailing descriptors.
    private static func qualifiedTerms(of key: String) -> [String] {
        var terms: [String] = []
        var current = key
        while terms.count < 4, let stripped = strippingTrailingQualifier(current) {
            guard stripped != current else { break }
            if !terms.contains(stripped) { terms.append(stripped) }
            current = stripped
        }
        return terms
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

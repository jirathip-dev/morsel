import Foundation

// Issue #288 — the closed SECONDARY-PHRASE policy for descriptive logged names.
//
// The shipped #260 grammar removes only NON-FOOD descriptors: cooking methods,
// portion/size tokens and quantities. A logging agent also writes what an item
// came WITH, or what it is used FOR ("satay skewers with peanut sauce",
// "olive oil / butter for cooking"), and such a name describes ONE item — its
// head — rather than a shared plate. #288 tolerates that class without ever
// falling back to an "ignore the tail" rule: nothing is dropped unless the tail
// matches one of the closed forms below.
//
// TOLERATED TRAILING CLASSES (the head must still reach a whole catalog
// name/alias on its own; an unrecognized tail is never dropped):
//  1. CONTAINER/FORMAT — a word that names how the item is served, never a food
//     (`skewers`, `slice`, `bowl`, `drizzle`; see `FoodArtworkResolver`).
//  2. ACCOMPANIMENT — an attachment marker (`with`, `with a side of`,
//     `on the side`, `topped with`, `served with`, `plus`, `and`, `&`, `+`)
//     plus a phrase from the closed condiment/sauce/fat/garnish vocabulary
//     below. Safe: a sauce, seasoning or cooking fat served alongside is not
//     the dish, and the vocabulary is positively enumerated.
//  3. PURPOSE — `for <use>` with a use from the closed non-food set below
//     (`for cooking`, `for dipping`). Safe: it states the item's ROLE; no food
//     can be named there.
//  4. ALTERNATION — `A / B`: the first component names the item and every
//     remaining component must itself be a closed accompaniment or purpose.
//     Safe: the `/` asserts the writer means the same thing twice, and the
//     remaining components are still restricted to classes 2 and 3.
//  (Portion/size and quantity remain the shipped #260 classes.)
//
// VETOED — the name keeps its whole, unresolved meaning (neutral sign) when:
//  - any tail word is outside these closed lists; this is what refuses the
//    generic-ingredient compound `coffee with rice and chicken` (`rice`,
//    `and`, `chicken` are none of them) — an unbounded tail-drop is exactly
//    what #260 rejected;
//  - a tolerated phrase names a catalog identity OUTSIDE the condiments class:
//    a second dairy/protein/sweets/… identity means a shared plate, not a
//    description (`coffee with peanut butter`, `cake with coffee`);
//  - the head never reaches a whole catalog term (`chicken skewers`);
//  - two identities survive: ordinary ambiguity still resolves to neutral.
enum FoodArtworkSecondary {
    /// Longest first: `with a side of` must be matched before `with`.
    static let attachmentMarkers = [
        "with a side of", "topped with", "served with", "on the side", "with", "plus", "and", "&", "+"
    ]

    /// The closed accompaniment vocabulary: condiments, sauces, cooking fats,
    /// seasonings and garnishes a name may carry without changing what the item
    /// is. Deliberately phrase-exact and deliberately free of dish nouns.
    static let accompaniments: Set<String> = [
        // sauces, gravies and dressings
        "sauce", "sauces", "gravy", "brown gravy", "pan gravy", "dressing", "salad dressing",
        "vinaigrette", "vinegar", "mayo", "mayonnaise", "ketchup", "mustard", "sriracha",
        "hot sauce", "soy sauce", "fish sauce", "oyster sauce", "chili sauce", "sweet chili sauce",
        "tomato sauce", "peanut sauce", "satay sauce", "dipping sauce", "nam jim", "nam jim jaew",
        "jaew", "salsa", "pesto", "chutney", "tahini", "harissa", "sambal", "gochujang", "wasabi",
        "horseradish", "soy", "tamari", "mirin", "dashi",
        // cooking fats
        "oil", "olive oil", "sesame oil", "chili oil", "cooking oil", "ghee", "butter", "margarine", "lard",
        // seasonings and garnishes
        "salt", "pepper", "peppercorn", "peppercorns", "chili", "chili flakes", "chili crisp",
        "chili powder", "sesame", "sesame seeds", "garlic", "ginger", "herbs", "cilantro",
        "coriander", "parsley", "mint", "basil", "dill", "chives", "scallions", "shallots",
        "lime", "lemon", "sugar", "honey", "tobiko"
    ]

    /// The closed purpose grammar: `for <use>`. Non-food uses only, so the
    /// phrase can state a role but can never smuggle in a second ingredient.
    static let purposes: Set<String> = [
        "for cooking", "for frying", "for stir frying", "for deep frying", "for grilling",
        "for roasting", "for baking", "for steaming", "for boiling", "for sauteing",
        "for dipping", "for dressing", "for garnish", "for topping", "for seasoning", "for basting"
    ]

    /// The head of a name whose trailing secondary phrase is tolerated, or
    /// `nil` when the name carries no recognized secondary. Callers then keep
    /// the name whole: an unrecognized tail is never dropped.
    static func head(_ key: String, in assets: [FoodArtworkAsset]) -> String? {
        alternationHead(key, in: assets) ?? attachmentHead(key, in: assets) ?? purposeHead(key)
    }

    /// `olive oil / butter for cooking`: the first component names the item,
    /// every remaining component must be a closed accompaniment or purpose.
    private static func alternationHead(_ key: String, in assets: [FoodArtworkAsset]) -> String? {
        let parts = key.components(separatedBy: " / ")
        guard parts.count >= 2, let head = nonEmpty(parts[0]) else { return nil }
        guard parts.dropFirst().allSatisfy({ isSecondary($0, in: assets) }) else { return nil }
        return head
    }

    /// `satay skewers with peanut sauce`: an attachment marker plus a closed
    /// accompaniment. The longest head wins, so the tail stays the shortest
    /// phrase the vocabulary can explain.
    private static func attachmentHead(_ key: String, in assets: [FoodArtworkAsset]) -> String? {
        let words = key.split(separator: " ").map(String.init)
        guard words.count >= 3 else { return nil }
        for start in 1..<words.count {
            for marker in attachmentMarkers where matchesMarker(words, at: start, marker: marker) {
                let length = marker.split(separator: " ").count
                let tail = words[(start + length)...].joined(separator: " ")
                if isSecondary(tail, in: assets) { return nonEmpty(words[..<start].joined(separator: " ")) }
            }
        }
        return nil
    }

    /// `olive oil for cooking`: the same closed purpose grammar at the tail.
    private static func purposeHead(_ key: String) -> String? {
        guard let range = key.range(of: " for "), purposes.contains("for " + key[range.upperBound...]) else {
            return nil
        }
        return nonEmpty(String(key[key.startIndex..<range.lowerBound]))
    }

    /// A closed accompaniment, optionally stating its use (`butter for cooking`).
    static func isSecondary(_ phrase: String, in assets: [FoodArtworkAsset]) -> Bool {
        let key = hyphenless(FoodArtworkCatalog.normalize(phrase))
        guard !key.isEmpty else { return false }
        if purposes.contains(key) { return true }
        guard let accompaniment = droppingPurpose(key), accompaniments.contains(accompaniment) else {
            return false
        }
        return !namesSecondIdentity(accompaniment, in: assets)
    }

    /// `butter for cooking` → `butter`; `butter` → `butter`; a `for …` that is
    /// not a closed purpose → `nil` (fails closed).
    private static func droppingPurpose(_ key: String) -> String? {
        guard let range = key.range(of: " for ") else { return key }
        guard purposes.contains("for " + key[range.upperBound...]) else { return nil }
        return nonEmpty(String(key[key.startIndex..<range.lowerBound]))
    }

    /// The veto: a tolerated phrase may name a condiment (that is the class it
    /// comes from), never a second catalog identity — a dairy, protein, grains,
    /// drinks, produce, soup, sweets or prepared identity in the tail means the
    /// name lists a second dish, not a description of the first one.
    private static func namesSecondIdentity(_ phrase: String, in assets: [FoodArtworkAsset]) -> Bool {
        assets.contains { asset in
            guard asset.category != condimentCategory else { return false }
            return ([asset.name] + asset.aliases).contains { FoodArtworkCatalog.normalize($0) == phrase }
        }
    }

    private static func matchesMarker(_ words: [String], at start: Int, marker: String) -> Bool {
        let parts = marker.split(separator: " ").map(String.init)
        guard start + parts.count < words.count else { return false }
        return Array(words[start..<(start + parts.count)]) == parts
    }

    private static func hyphenless(_ key: String) -> String {
        key.replacingOccurrences(of: "-", with: " ")
    }

    private static func nonEmpty(_ key: String) -> String? {
        key.isEmpty ? nil : key
    }

    private static let condimentCategory = "condiments"
}

import Foundation

// Issue #288 case probe — the resolved identity of every named case in this
// lane's contract, compiled against the SAME sources and the SAME bundled
// catalog as the app (no simulator, no XCTest):
//
//   cd docs/evidence/issue-288-descriptive-names/probe
//   swiftc -O -o /tmp/rev288-probe CaseProbe.swift \
//     ../../../../app/Sources/Morsel/FoodArtwork.swift \
//     ../../../../app/Sources/Morsel/FoodArtworkSecondary.swift
//   /tmp/rev288-probe ../../../../app/Resources/FoodArt/catalog.json
//
// `MealItem` is a minimal stand-in for the app type (the resolver reads only
// `name` and `artworkID`). The durable assertions live in the app-hosted
// XCTest suites; this probe exists so the case inventory can be re-measured
// without a simulator. It prints public test/issue fixtures only — never a
// logged name.

struct MealItem {
    let name: String
    let artworkID: String?
}

struct AssetRow: Decodable {
    let id: String
    let name: String
    let aliases: [String]?
    let category: String
    let kind: String
}

struct Catalog: Decodable {
    let assets: [AssetRow]
}

@main
struct CaseProbe {
    static func out(_ line: String) { FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!) }

    static func main() {
        guard CommandLine.arguments.count > 1,
              let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
              let file = try? JSONDecoder().decode(Catalog.self, from: data) else {
            out("FATAL catalog unreadable"); return
        }
        let assets = file.assets.compactMap { row in
            FoodArtworkKind(rawValue: row.kind).map {
                FoodArtworkAsset(id: row.id, name: row.name, aliases: row.aliases ?? [],
                                 category: row.category, kind: $0)
            }
        }
        out("CATALOG_ASSETS \(assets.count)")

        // Tolerated classes: the head identity must be reached.
        let positives: [(String, String)] = [
            ("Satay skewers with peanut sauce", "satay"),
            ("satay skewers", "satay"),
            ("half-portion satay", "satay"),
            ("Olive oil / butter for cooking", "cooking-oil"),
            ("Olive oil for cooking", "cooking-oil"),
            ("Mashed potato with gravy", "mashed-potato"),
            ("Mixed salad with dressing", "green-salad"),
            ("Chili oil drizzle", "chili-oil"),
            ("Chili flakes & herbs", "chili-oil"),
            ("Greek yogurt with honey", "yogurt")
        ]
        var missed = 0
        for (name, identity) in positives {
            let got = resolvedID(of: name, in: assets)
            if got != identity { missed += 1 }
            out("\(got == identity ? "PASS" : "FAIL") | \(name) -> \(got) want=\(identity)")
        }
        out("POSITIVES missed=\(missed) of \(positives.count)")

        // Vetoes: the whole name keeps its neutral sign.
        let vetoes = [
            "Coffee with rice and chicken", "Coffee with rice and chicken only",
            "Cake with coffee", "Americano (black) with toast", "Som tum with peanuts",
            "chicken skewers", "butter for cooking", "skewers with peanut sauce",
            "coffee / tea", "Egg salad / creamy egg spread", "Fish balls / fish tofu / dumpling assortment",
            "Rice cake", "banana bread", "coffee ice cream", "Uncatalogued lunar stew",
            "composite/shared restaurant plate", "half-portion coffee cake with rice",
            "pasta (linguine) with chicken", "milk tea (boba tea)", "half-portion white riceish",
            "pasta (coffee), cooked", "pasta (linguine", "rice cake (half-portion)", "coffee, 1/2 cup",
            "Americano (black (no sugar))", "White rice (half portion), cake", "coffeeish",
            "Coffee custard (homemade)", "pad thai from the corner stall", "half-portion white rice and pork"
        ]
        var neutral = 0
        for name in vetoes {
            let got = resolvedID(of: name, in: assets)
            if got == "fallback-neutral" { neutral += 1 }
            out("\(got == "fallback-neutral" ? "NEUTRAL" : "  RESOLVED") | \(name) -> \(got)")
        }
        out("VETOES neutral=\(neutral) of \(vetoes.count)")

        // Shipped #260 positives that must not move.
        let shipped: [(String, String)] = [
            ("coffee cake", "cake"), ("milk tea", "milk-tea"), ("boba tea", "boba-tea"),
            ("pad thai", "pad-thai"), ("stir-fried noodles", "stir-fried-noodles"),
            ("Iced americano (black, no sugar)", "coffee"), ("iced americano", "iced-coffee"),
            ("Americano (black, no sugar, homemade)", "coffee"), ("white rice", "jasmine-rice"),
            ("half-portion white rice", "jasmine-rice"), ("white rice, cooked (half portion)", "jasmine-rice"),
            ("Pasta (linguine), cooked", "pasta"), ("linguine", "pasta"), ("Chinese kale", "stir-fried-greens"),
            ("kana", "stir-fried-greens"), ("pork with brown gravy", "braised-pork"), ("Dairy", "fallback-dairy")
        ]
        var moved = 0
        for (name, identity) in shipped {
            let got = resolvedID(of: name, in: assets)
            if got != identity { moved += 1 }
            out("\(got == identity ? "PASS" : "FAIL") | \(name) -> \(got) want=\(identity)")
        }
        out("SHIPPED missed=\(moved) of \(shipped.count)")
    }

    static func resolvedID(of name: String, in assets: [FoodArtworkAsset]) -> String {
        switch FoodArtworkResolver.resolve(name: name, in: assets) {
        case let .food(asset), let .category(asset), let .neutral(asset): return asset.id
        case .none: return "none"
        }
    }
}

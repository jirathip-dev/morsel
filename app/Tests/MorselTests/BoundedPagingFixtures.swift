import Foundation
import XCTest
@testable import Morsel

/// One fixture row: its primary key, the value a parent-id filter matches
/// (`nil` for a table that is not filtered by a parent), and the raw JSON the
/// server delivers.
struct CappedRow {
    let id: String
    let parent: String?
    let json: String
}

/// The synthetic tables one capped read runs against. Tables that are not
/// collections answer a fixed body (the read graph's goals/profile/energy
/// rows).
struct CappedFixture {
    var meals: [CappedRow] = []
    var items: [CappedRow] = []
    var weights: [CappedRow] = []
    var menus: [CappedRow] = []
    var menuItems: [CappedRow] = []
    var bodies: [String: String] = [
        "goals": "[{\"calorie_target_kcal\": 2000, \"protein_g\": 150, \"carbs_g\": 200, \"fat_g\": 60, "
            + "\"source\": \"manual\", \"updated_at\": \"2026-09-05T00:00:00.000Z\"}]",
        "profiles": "[]",
        "energy_burned_logs": "[{\"burned_at\": \"2026-09-05T03:00:00.000Z\", \"active_kcal\": 320}]"
    ]
}

extension CappedFixture {
    // Every id is a valid UUID (`8-4-4-4-12`) for any fixture size: the
    // variable part is a zero-padded hex suffix.
    static func mealID(_ number: Int) -> String { uuid(0x1111_0000, number) }
    static func itemID(_ number: Int) -> String { uuid(0x2222_0000, number) }
    static func weightID(_ number: Int) -> String { uuid(0x3333_0000, number) }
    static func menuID(_ number: Int) -> String { uuid(0x4444_0000, number) }
    static func menuItemID(_ number: Int) -> String { uuid(0x5555_0000, number) }

    private static func uuid(_ base: Int, _ number: Int) -> String {
        String(format: "%08x-1111-4111-8111-111111111111", base + number)
    }

    static func meal(_ number: Int, at eatenAt: String) -> CappedRow {
        CappedRow(
            id: mealID(number), parent: nil,
            json: "{\"id\":\"\(mealID(number))\",\"eaten_at\":\"\(eatenAt)\",\"meal_type\":\"lunch\","
                + "\"source\":\"manual\",\"image_path\":null}"
        )
    }

    static func item(_ number: Int, meal: Int, kcal: Double?) -> CappedRow {
        let calories = kcal.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "null"
        return CappedRow(
            id: itemID(number), parent: mealID(meal),
            json: "{\"id\":\"\(itemID(number))\",\"meal_log_id\":\"\(mealID(meal))\","
                + "\"name\":\"Synthetic bowl \(number)\",\"quantity\":1.5,\"unit\":\"serving\","
                + "\"calories_kcal\":\(calories),\"protein_g\":6,\"carbs_g\":31,\"fat_g\":12,\"fiber_g\":4,"
                + "\"sugar_g\":6,\"confidence\":0.9,\"source_notes\":\"synthetic\",\"menu_group_id\":null,"
                + "\"menu_name\":null,\"artwork_id\":null}"
        )
    }

    /// A trend sample at a distinct whole second inside the 30-day window of
    /// the repo's fixture instant.
    static func weight(_ number: Int, kilograms: Double) -> CappedRow {
        let base = MorselDate.date("2026-09-01T04:00:00Z") ?? Date()
        let measuredAt = MorselDate.iso8601(base.addingTimeInterval(Double(number)))
        return CappedRow(
            id: weightID(number), parent: nil,
            json: "{\"measured_at\":\"\(measuredAt)\",\"kg\":\(kilograms)}"
        )
    }

    static func menu(_ number: Int, name: String) -> CappedRow {
        CappedRow(id: menuID(number), parent: nil, json: "{\"id\":\"\(menuID(number))\",\"name\":\"\(name)\"}")
    }

    static func menuItem(_ number: Int, menu: Int, kcal: Double?) -> CappedRow {
        let calories = kcal.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "null"
        return CappedRow(
            id: menuItemID(number), parent: menuID(menu),
            json: "{\"id\":\"\(menuItemID(number))\",\"menu_id\":\"\(menuID(menu))\",\"name\":\"Template \(number)\","
                + "\"quantity\":1,\"unit\":\"serving\",\"calories_kcal\":\(calories),\"protein_g\":null,"
                + "\"carbs_g\":null,\"fat_g\":null,\"fiber_g\":null,\"sugar_g\":null}"
        )
    }

    /// `meals` meals (one instant, so the fixture is in the same local day in
    /// any host zone) with `itemsPerMeal` items each, `weights` trend samples
    /// (distinct whole seconds), and `menus` menus with `itemsPerMenu` items
    /// each. Synthetic only.
    static func dense(meals mealCount: Int, itemsPerMeal: Int, weights weightCount: Int = 0,
                      menus menuCount: Int = 0, itemsPerMenu: Int = 0) -> CappedFixture {
        var fixture = CappedFixture()
        var itemNumber = 0
        for number in 1...max(mealCount, 1) where number <= mealCount {
            fixture.meals.append(meal(number, at: "2026-09-05T04:00:00.000Z"))
            for offset in 0..<itemsPerMeal {
                itemNumber += 1
                fixture.items.append(item(itemNumber, meal: number, kcal: Double(100 + offset * 10)))
            }
        }
        for number in 1...max(weightCount, 1) where number <= weightCount {
            fixture.weights.append(weight(number, kilograms: 80 + Double(number) / 10))
        }
        var menuItemNumber = 0
        for number in 1...max(menuCount, 1) where number <= menuCount {
            fixture.menus.append(menu(number, name: "Menu \(String(format: "%02d", number))"))
            for offset in 0..<itemsPerMenu {
                menuItemNumber += 1
                fixture.menuItems.append(menuItem(menuItemNumber, menu: number, kcal: Double(50 + offset)))
            }
        }
        return fixture
    }
}

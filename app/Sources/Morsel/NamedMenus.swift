import SwiftUI

// Issue #152 — named menus: reusable meal-type-free templates plus snapshot
// display grouping. A logged menu copies its items into the meal (every item
// carries menu_name + a shared menu_group_id); loose items carry neither.
// Editing a menu NEVER changes past meals.

/// One template item of a named menu (mirrors the server menu_items row).
struct MenuTemplateItem: Identifiable, Equatable, Sendable, Codable {
    let itemID: UUID
    let name: String
    let quantity: Double
    let unit: FoodUnit
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fiberG: Double?
    let sugarG: Double?

    var id: UUID { itemID }

    init(
        itemID: UUID = UUID(),
        name: String,
        quantity: Double = 1,
        unit: FoodUnit = .serving,
        caloriesKcal: Double? = nil,
        proteinG: Double? = nil,
        carbsG: Double? = nil,
        fatG: Double? = nil,
        fiberG: Double? = nil,
        sugarG: Double? = nil
    ) {
        self.itemID = itemID
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.sugarG = sugarG
    }
}

/// A reusable named menu (mirrors the server meal_menus + menu_items read).
struct NamedMenu: Identifiable, Equatable, Sendable, Codable {
    let menuID: UUID
    let name: String
    let items: [MenuTemplateItem]

    var id: UUID { menuID }

    var totalCalories: Double {
        items.reduce(0) { total, item in total + (item.caloriesKcal ?? 0) }
    }

    /// One-line list summary for the picker and Menus rows.
    var summaryLine: String {
        let itemsLabel = items.count == 1 ? "1 item" : "\(items.count) items"
        return "\(itemsLabel) · \(MorselFormat.number(totalCalories)) kcal"
    }
}

// MARK: - Display grouping (Today / History)

/// One visible row group inside a meal: a logged set (menu name header +
/// nested items) or a single loose item. Consecutive items sharing the same
/// snapshot group id coalesce; loose items render flat beside sets (A3).
enum LoggedItemRow: Equatable, Sendable {
    case set(name: String, groupID: UUID, items: [MealItem])
    case loose(MealItem)

    /// Stable view identity: the set group id, or the loose item's own id.
    var rowID: String {
        switch self {
        case let .set(_, groupID, _):
            return "set-\(groupID.uuidString)"
        case let .loose(item):
            return "loose-\(item.itemID.uuidString)"
        }
    }

    /// All items rendered by this row group, in display order.
    var items: [MealItem] {
        switch self {
        case let .set(_, _, members):
            return members
        case let .loose(item):
            return [item]
        }
    }
}

enum MealDisplayGrouping {
    /// Builds the ordered row groups of one meal's items. Only CONSECUTIVE
    /// items with the same non-nil menu_group_id form a set; the set header
    /// uses the item snapshot's menu name copy.
    static func rows(from items: [MealItem]) -> [LoggedItemRow] {
        var rows: [LoggedItemRow] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            guard let groupID = item.menuGroupID, let name = item.menuName else {
                rows.append(.loose(item))
                index += 1
                continue
            }
            var members = [item]
            index += 1
            while index < items.count,
                  items[index].menuGroupID == groupID {
                members.append(items[index])
                index += 1
            }
            rows.append(.set(name: name, groupID: groupID, items: members))
        }
        return rows
    }

    /// The nested display label of a logged set ('Menu name (set)').
    static func setLabel(name: String) -> String {
        "\(name) (set)"
    }
}

// MARK: - Draft conversion (menus screen + log-from-menu share these shapes)

extension MenuTemplateItem {
    /// A template item as a meal item draft (snapshot stamp applied by the
    /// caller when logging from a menu).
    func draft(menuGroupID: UUID? = nil, menuName: String? = nil) -> MealItemDraft {
        MealItemDraft(
            name: name,
            quantity: quantity,
            unit: unit,
            caloriesKcal: caloriesKcal,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            fiberG: fiberG,
            sugarG: sugarG,
            menuGroupID: menuGroupID,
            menuName: menuName
        )
    }
}

/// A menu edit captured on the Menus screen before it is saved remotely.
struct MenuEditorDraft: Equatable {
    var name: String
    var items: [MenuTemplateItem]

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !trimmedName.isEmpty && !items.isEmpty
    }

    var totalCalories: Double {
        items.reduce(0) { total, item in total + (item.caloriesKcal ?? 0) }
    }
}

import Foundation
import Supabase

// Issue #152 — named-menu repository seams on the authenticated Supabase
// path. Menus are account templates in meal_menus/menu_items (RLS-guarded);
// save = the atomic upsert_menu RPC (create or full item-list replace in ONE
// call); delete = an owner-scoped meal_menus delete (FK cascade removes the
// items). Logs are snapshots, so these writes never touch past meals.

private struct MealMenuRow: Decodable {
    let id: String
    let name: String
}

private struct MenuItemRow: Decodable {
    let id: String
    let menuId: String
    let name: String
    let quantity: Double
    let unit: String
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fiberG: Double?
    let sugarG: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case menuId = "menu_id"
        case name
        case quantity
        case unit
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case sugarG = "sugar_g"
    }
}

private struct UpsertMenuResponse: Decodable {
    let menuID: String

    enum CodingKeys: String, CodingKey {
        case menuID = "menu_id"
    }
}

private struct UpsertMenuParameters: Encodable {
    let userID: String
    let menuID: String?
    let name: String
    let items: [UpsertMenuItemParameters]

    enum CodingKeys: String, CodingKey {
        case userID = "p_user_id"
        case menuID = "p_menu_id"
        case name = "p_name"
        case items = "p_items"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userID, forKey: .userID)
        try container.encodeIfPresent(menuID, forKey: .menuID)
        try container.encode(name, forKey: .name)
        try container.encode(items, forKey: .items)
    }
}

private struct UpsertMenuItemParameters: Encodable {
    let name: String
    let quantity: Double
    let unit: String
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fiberG: Double?
    let sugarG: Double?
    let barcode: String?
    let foodRefID: String?

    init(_ item: MenuTemplateItem) {
        name = item.name
        quantity = item.quantity
        unit = item.unit.rawValue
        caloriesKcal = item.caloriesKcal
        proteinG = item.proteinG
        carbsG = item.carbsG
        fatG = item.fatG
        fiberG = item.fiberG
        sugarG = item.sugarG
        barcode = nil
        foodRefID = nil
    }

    enum CodingKeys: String, CodingKey {
        case name
        case quantity
        case unit
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case sugarG = "sugar_g"
        case barcode
        case foodRefID = "food_ref_id"
    }
}

private let menuItemColumns = [
    "id", "menu_id", "name", "quantity", "unit", "calories_kcal", "protein_g",
    "carbs_g", "fat_g", "fiber_g", "sugar_g"
].joined(separator: ",")

extension SupabaseDashboardRepository {
    func listMenus(userID: UUID) async throws -> [NamedMenu] {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        let menuRows: [MealMenuRow] = try await client
            .from("meal_menus")
            .select("id,name")
            .eq("user_id", value: authenticatedUserID.uuidString)
            .order("name", ascending: true)
            .execute()
            .value
        guard !menuRows.isEmpty else {
            return []
        }
        let menuIDs = menuRows.map(\.id)
        let itemRows: [MenuItemRow] = try await client
            .from("menu_items")
            .select(menuItemColumns)
            .in("menu_id", values: menuIDs)
            .execute()
            .value
        let itemsByMenu = Self.itemsByMenu(itemRows)
        return menuRows.compactMap { row in
            guard let menuID = UUID(uuidString: row.id) else {
                return nil
            }
            let items = itemsByMenu[row.id] ?? []
            guard !items.isEmpty else {
                return nil
            }
            return NamedMenu(menuID: menuID, name: row.name, items: items)
        }
    }

    func createMenu(userID: UUID, editor: MenuEditorDraft) async throws -> NamedMenu {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        guard editor.isValid else {
            throw MorselError.invalidInput("Give the menu a name and at least one item.")
        }
        let response: [UpsertMenuResponse] = try await client
            .rpc(
                "upsert_menu",
                params: UpsertMenuParameters(
                    userID: authenticatedUserID.uuidString,
                    menuID: nil,
                    name: editor.trimmedName,
                    items: editor.items.map(UpsertMenuItemParameters.init)
                )
            )
            .execute()
            .value
        guard let menuID = response.first.flatMap({ UUID(uuidString: $0.menuID) }) else {
            throw MorselError.decodingFailed
        }
        return NamedMenu(
            menuID: menuID,
            name: editor.trimmedName,
            items: editor.items.map { item in
                MenuTemplateItem(
                    name: item.name,
                    quantity: item.quantity,
                    unit: item.unit,
                    caloriesKcal: item.caloriesKcal,
                    proteinG: item.proteinG,
                    carbsG: item.carbsG,
                    fatG: item.fatG,
                    fiberG: item.fiberG,
                    sugarG: item.sugarG
                )
            }
        )
    }

    func updateMenu(userID: UUID, menuID: UUID, editor: MenuEditorDraft) async throws {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        guard editor.isValid else {
            throw MorselError.invalidInput("Give the menu a name and at least one item.")
        }
        let response: [UpsertMenuResponse] = try await client
            .rpc(
                "upsert_menu",
                params: UpsertMenuParameters(
                    userID: authenticatedUserID.uuidString,
                    menuID: menuID.uuidString,
                    name: editor.trimmedName,
                    items: editor.items.map(UpsertMenuItemParameters.init)
                )
            )
            .execute()
            .value
        guard response.first?.menuID == menuID.uuidString else {
            throw MorselError.decodingFailed
        }
    }

    func deleteMenu(userID: UUID, menuID: UUID) async throws {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        let response = try await client
            .from("meal_menus")
            .delete()
            .eq("id", value: menuID.uuidString)
            .eq("user_id", value: authenticatedUserID.uuidString)
            .execute()
        _ = response
    }
}

// Issue #152 — groups fetched menu_items rows under their menu_id, dropping
// rows that cannot be a template item (parse or validation refusal).
extension SupabaseDashboardRepository {
    private static func itemsByMenu(_ rows: [MenuItemRow]) -> [String: [MenuTemplateItem]] {
        var grouped: [String: [MenuTemplateItem]] = [:]
        for row in rows {
            guard let itemID = UUID(uuidString: row.id),
                  let unit = FoodUnit(rawValue: row.unit),
                  row.quantity.isFinite, row.quantity > 0,
                  !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            grouped[row.menuId, default: []].append(MenuTemplateItem(
                itemID: itemID,
                name: row.name,
                quantity: row.quantity,
                unit: unit,
                caloriesKcal: row.caloriesKcal,
                proteinG: row.proteinG,
                carbsG: row.carbsG,
                fatG: row.fatG,
                fiberG: row.fiberG,
                sugarG: row.sugarG
            ))
        }
        return grouped
    }
}

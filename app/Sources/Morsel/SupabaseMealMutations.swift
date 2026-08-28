import Foundation
import Supabase

extension SupabaseDashboardRepository {
    func confirmMealItem(userID: UUID, itemID: UUID) async throws {
        guard let client else {
            throw MorselError.configurationMissing
        }
        _ = try await requireSession(client, userID: userID)
        let updated: [MealItemResponse] = try await client
            .from("meal_items")
            .update(MealItemReviewUpdate(confidence: 1.0))
            .eq("id", value: itemID.uuidString)
            .select(mealItemColumns)
            .execute()
            .value
        guard updated.count == 1, let item = updated.first else {
            throw MorselError.invalidData("The meal item could not be reviewed.")
        }
        _ = try parseItem(item, source: .manualEdit)
    }

    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        try MealItemUpdateValidation.validate(update)

        let ownershipResponse: [MealItemOwnershipResponse] = try await client
            .from("meal_items")
            .select("meal_log_id")
            .eq("id", value: update.itemID.uuidString)
            .limit(1)
            .execute()
            .value
        guard let ownership = ownershipResponse.first else {
            throw MorselError.invalidData("The meal item could not be updated.")
        }

        let parentResponse: [MealLogOwnershipResponse] = try await client
            .from("meal_logs")
            .select("id")
            .eq("id", value: ownership.mealLogID)
            .eq("user_id", value: authenticatedUserID.uuidString)
            .limit(1)
            .execute()
            .value
        guard !parentResponse.isEmpty else {
            throw MorselError.invalidData("The meal item could not be updated.")
        }

        let updated: [MealItemResponse] = try await client
            .from("meal_items")
            .update(MealItemUpdatePayload(update: update))
            .eq("id", value: update.itemID.uuidString)
            .eq("meal_log_id", value: ownership.mealLogID)
            .select(mealItemColumns)
            .execute()
            .value
        guard updated.count == 1, let item = updated.first else {
            throw MorselError.invalidData("The meal item could not be updated.")
        }
        _ = try parseItem(item, source: update.source)
    }

    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        let deleted: [MealLogOwnershipResponse] = try await client
            .from("meal_logs")
            .delete()
            .eq("id", value: mealLogID.uuidString)
            .eq("user_id", value: authenticatedUserID.uuidString)
            .select("id")
            .execute()
            .value
        guard deleted.count == 1 else {
            throw MorselError.invalidData("The meal could not be deleted.")
        }
    }

    func requireSession(_ client: SupabaseClient, userID: UUID) async throws -> UUID {
        let session = try await client.auth.session
        guard session.user.id == userID else {
            throw MorselError.invalidInput("The Supabase session does not match this user.")
        }
        return session.user.id
    }
}

private struct MealItemOwnershipResponse: Decodable {
    let mealLogID: String

    enum CodingKeys: String, CodingKey {
        case mealLogID = "meal_log_id"
    }
}

private struct MealLogOwnershipResponse: Decodable {
    let id: String
}

struct MealItemUpdatePayload: Encodable {
    let update: MealItemUpdate

    enum CodingKeys: String, CodingKey {
        case name
        case quantity
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case sourceNotes = "source_notes"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(update.name, forKey: .name)
        try container.encodeIfPresent(update.quantity, forKey: .quantity)
        try container.encodeIfPresent(update.caloriesKcal, forKey: .caloriesKcal)
        try container.encodeIfPresent(update.proteinG, forKey: .proteinG)
        try container.encodeIfPresent(update.carbsG, forKey: .carbsG)
        try container.encodeIfPresent(update.fatG, forKey: .fatG)
        if update.source == .manualEdit {
            try container.encode(MealSource.manualEdit.rawValue, forKey: .sourceNotes)
        }
    }
}

private struct MealItemReviewUpdate: Encodable {
    let confidence: Double
}

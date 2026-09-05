import Foundation
import Supabase

extension SupabaseDashboardRepository {
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? {
        guard let client else { throw MorselError.configurationMissing }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        let rows: [GoalResponse] = try await client.from("goals")
            .select("calorie_target_kcal,protein_g,carbs_g,fat_g,source,updated_at")
            .eq("user_id", value: authenticatedUserID.uuidString)
            .limit(1).execute().value
        return try rows.first.map(parseStoredGoal)
    }

    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        guard let profile = try await loadProfileForGoals(userID: userID) else {
            throw MorselError.invalidData("A profile is required to compute goals.")
        }
        let dietGoal: ProfileDietGoal = switch direction {
        case .cut: .lose
        case .maintain: .maintain
        case .bulk: .gain
        }
        guard let client else { throw MorselError.configurationMissing }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        let response: [ComputeTargetsResponse] = try await client
            .rpc(
                "compute_targets",
                params: ComputeTargetsRPCParams(
                    input: ComputeTargetsFunctionInput(
                        userID: authenticatedUserID, profile: profile, dietGoal: dietGoal
                    )
                )
            )
            .execute().value
        guard let computed = response.first, response.count == 1 else {
            throw MorselError.invalidData("Supabase returned an invalid computed goal.")
        }
        return DashboardGoal(
            calorieTargetKcal: computed.calorieTargetKcal, proteinG: computed.proteinG,
            carbsG: computed.carbsG, fatG: computed.fatG, source: .computed
        )
    }

    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {
        guard let client else { throw MorselError.configurationMissing }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        let normalizedGoal = Self.normalizedGoal(goal)
        let response: GoalResponse = try await client.from("goals")
            .upsert(GoalPayload(userID: authenticatedUserID, goal: normalizedGoal))
            .select("calorie_target_kcal,protein_g,carbs_g,fat_g,source")
            .single().execute().value
        guard Self.savedGoalMatches(response, goal: normalizedGoal) else {
            throw MorselError.invalidData("Supabase returned a different saved goal.")
        }
    }

    // MARK: - One-decimal precision contract

    /// Rounds half-up to one decimal place (the 0.1 grid), matching the DB's
    /// coarsest column scale `numeric(10,1)` for `calorie_target_kcal`
    /// (migration 0009) and the one-decimal normalization the editor applies to
    /// every field. Goals at one decimal are nutritionally sufficient for this
    /// screen, and normalizing at the persistence boundary keeps the response
    /// guard comparing like-for-like: the app sends exactly what Postgres
    /// stores, so exact equality no longer fails on a rounded write.
    static func normalizedOneDecimal(_ value: Double) -> Double {
        var decimal = Decimal(string: String(value)) ?? Decimal(value)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 1, .plain)
        return NSDecimalNumber(decimal: rounded).doubleValue
    }

    static func normalizedGoal(_ goal: DashboardGoal) -> DashboardGoal {
        DashboardGoal(
            calorieTargetKcal: normalizedOneDecimal(goal.calorieTargetKcal),
            proteinG: normalizedOneDecimal(goal.proteinG),
            carbsG: normalizedOneDecimal(goal.carbsG),
            fatG: normalizedOneDecimal(goal.fatG),
            source: goal.source
        )
    }

    static func savedGoalMatches(_ response: GoalResponse, goal: DashboardGoal) -> Bool {
        response.calorieTargetKcal == goal.calorieTargetKcal
            && response.proteinG == goal.proteinG
            && response.carbsG == goal.carbsG
            && response.fatG == goal.fatG
            && response.source == goal.source.rawValue
    }

    private func loadProfileForGoals(userID: UUID) async throws -> DashboardProfile? {
        guard let client else { throw MorselError.configurationMissing }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        let rows: [ProfileResponse] = try await client.from("profiles")
            .select("sex,age_years,height_cm,weight_kg,activity_level,diet_goal,goal_weight_kg,updated_at")
            .eq("user_id", value: authenticatedUserID.uuidString).limit(1).execute().value
        return try rows.first.map(parseProfile)
    }

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

struct GoalPayload: Encodable {
    let userID: UUID
    let calorieTargetKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let source: String

    init(userID: UUID, goal: DashboardGoal) {
        self.userID = userID
        calorieTargetKcal = goal.calorieTargetKcal
        proteinG = goal.proteinG
        carbsG = goal.carbsG
        fatG = goal.fatG
        source = goal.source.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case calorieTargetKcal = "calorie_target_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case source
    }
}

private struct MealItemReviewUpdate: Encodable {
    let confidence: Double
}

struct ComputeTargetsRPCParams: Encodable {
    let input: ComputeTargetsFunctionInput

    enum CodingKeys: String, CodingKey {
        case input = "p"
    }
}

struct ComputeTargetsFunctionInput: Encodable {
    let userID: UUID
    let sex: String
    let ageYears: Int
    let heightCm: Double
    let weightKg: Double
    let activityLevel: String
    let dietGoal: String
    let goalWeightKg: Double?
    let updatedAt: String

    init(userID: UUID, profile: DashboardProfile, dietGoal: ProfileDietGoal) {
        self.userID = userID
        sex = profile.sex.rawValue
        ageYears = profile.ageYears
        heightCm = profile.heightCm
        weightKg = profile.weightKg
        activityLevel = profile.activityLevel.rawValue
        self.dietGoal = dietGoal.rawValue
        goalWeightKg = profile.goalWeightKg
        updatedAt = MorselDate.iso8601(Date())
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case sex
        case ageYears = "age_years"
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case activityLevel = "activity_level"
        case dietGoal = "diet_goal"
        case goalWeightKg = "goal_weight_kg"
        case updatedAt = "updated_at"
    }
}

private struct ComputeTargetsResponse: Decodable {
    let calorieTargetKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    enum CodingKeys: String, CodingKey {
        case calorieTargetKcal = "calorie_target_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }
}

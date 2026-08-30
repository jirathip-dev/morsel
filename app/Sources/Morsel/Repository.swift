import Foundation
import Supabase

let mealItemColumns = [
    "id", "meal_log_id", "name", "quantity", "unit", "calories_kcal", "protein_g",
    "carbs_g", "fat_g", "fiber_g", "sugar_g", "confidence", "source_notes"
].joined(separator: ",")

protocol DashboardRepository {
    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot
    func confirmMealItem(userID: UUID, itemID: UUID) async throws
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID
    func loadMealImage(userID: UUID, path: String) async throws -> Data
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal?
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws
}

struct SupabaseDashboardRepository: DashboardRepository {
    let client: SupabaseClient?

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let start = utcCalendar.startOfDay(for: date)
        guard let end = utcCalendar.date(byAdding: .day, value: 1, to: start),
              let trendStart = utcCalendar.date(byAdding: .day, value: -29, to: start) else {
            throw MorselError.invalidData("The dashboard date could not be calculated.")
        }

        let logs = try await loadMealLogs(client, userID: authenticatedUserID, start: start, end: end)
        let items = try await loadMealItems(client, logs: logs)
        let goalRows = try await loadGoals(client, userID: authenticatedUserID)
        let profileRows = try await loadProfiles(client, userID: authenticatedUserID)
        let weightRows = try await loadWeightTrend(
            client, userID: authenticatedUserID, start: trendStart, end: end
        )
        let energyRows = try await loadEnergyBurned(client, userID: authenticatedUserID, start: start, end: end)

        var itemsByMealID: [String: [MealItem]] = [:]
        var sourcesByMealID: [String: MealSource] = [:]
        for log in logs {
            guard let source = MealSource(rawValue: log.source) else {
                throw MorselError.invalidData("Supabase returned an invalid meal log.")
            }
            sourcesByMealID[log.id] = source
        }
        for item in items {
            guard let source = sourcesByMealID[item.mealLogID] else {
                throw MorselError.invalidData("Supabase returned an item for an unknown meal.")
            }
            itemsByMealID[item.mealLogID, default: []].append(try parseItem(item, source: source))
        }
        let meals = try logs.map { log in
            try parseMeal(log, items: itemsByMealID[log.id] ?? [])
        }
        let storedGoal = try goalRows.first.map(parseStoredGoal)
        let profile = try profileRows.first.map(parseProfile)
        let goal = DashboardMath.effectiveGoal(stored: storedGoal, profile: profile)
        return DashboardSnapshot(
            date: start, meals: meals, goal: goal, weightTrend: weightRows.compactMap(parseWeight),
            activeEnergyBurned: energyRows.reduce(0) { $0 + $1.activeKilocalories }
        )
    }

    private func loadMealLogs(
        _ client: SupabaseClient,
        userID: UUID,
        start: Date,
        end: Date
    ) async throws -> [MealLogResponse] {
        try await client
            .from("meal_logs")
            .select("id,eaten_at,meal_type,source,image_path")
            .eq("user_id", value: userID.uuidString)
            .gte("eaten_at", value: MorselDate.iso8601(start))
            .lt("eaten_at", value: MorselDate.iso8601(end))
            .order("eaten_at", ascending: true)
            .execute()
            .value
    }

    private func loadMealItems(
        _ client: SupabaseClient,
        logs: [MealLogResponse]
    ) async throws -> [MealItemResponse] {
        guard !logs.isEmpty else {
            return []
        }
        let mealIDs = logs.map(\.id)
        return try await client
            .from("meal_items")
            .select(mealItemColumns)
            .in("meal_log_id", values: mealIDs)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    private func loadGoals(_ client: SupabaseClient, userID: UUID) async throws -> [GoalResponse] {
        try await client
            .from("goals")
            .select("calorie_target_kcal,protein_g,carbs_g,fat_g,source")
            .eq("user_id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value
    }

    private func loadProfiles(_ client: SupabaseClient, userID: UUID) async throws -> [ProfileResponse] {
        try await client
            .from("profiles")
            .select("sex,age_years,height_cm,weight_kg,activity_level,diet_goal,goal_weight_kg")
            .eq("user_id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value
    }

    private func loadWeightTrend(
        _ client: SupabaseClient, userID: UUID, start: Date, end: Date
    ) async throws -> [WeightResponse] {
        try await client.from("weight_logs")
            .select("measured_at,kg")
            .eq("user_id", value: userID.uuidString)
            .gte("measured_at", value: MorselDate.iso8601(start))
            .lt("measured_at", value: MorselDate.iso8601(end))
            .order("measured_at", ascending: true)
            .execute().value
    }

    private func parseWeight(_ response: WeightResponse) -> WeightTrendPoint? {
        guard let date = MorselDate.date(response.measuredAt), response.kilograms.isFinite,
              response.kilograms > 0 else { return nil }
        return WeightTrendPoint(date: date, kilograms: response.kilograms)
    }

    private func loadEnergyBurned(
        _ client: SupabaseClient, userID: UUID, start: Date, end: Date
    ) async throws -> [EnergyResponse] {
        try await client.from("energy_burned_logs").select("burned_at,active_kcal")
            .eq("user_id", value: userID.uuidString)
            .gte("burned_at", value: MorselDate.iso8601(start))
            .lt("burned_at", value: MorselDate.iso8601(end)).execute().value
    }

    private func parseMeal(_ response: MealLogResponse, items: [MealItem]) throws -> MealRecord {
        guard let mealLogID = UUID(uuidString: response.id),
              let mealType = MealType(rawValue: response.mealType),
              let source = MealSource(rawValue: response.source),
              let eatenAt = MorselDate.date(response.eatenAt) else {
            throw MorselError.invalidData("Supabase returned an invalid meal log.")
        }
        return MealRecord(
            mealLogID: mealLogID,
            mealType: mealType,
            eatenAt: eatenAt,
            source: source,
            imagePath: response.imagePath,
            items: items
        )
    }

    func parseItem(_ response: MealItemResponse, source: MealSource) throws -> MealItem {
        guard let itemID = UUID(uuidString: response.id),
              UUID(uuidString: response.mealLogID) != nil,
              let unit = FoodUnit(rawValue: response.unit),
              !response.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.quantity.isFinite,
              response.quantity > 0 else {
            throw MorselError.invalidData("Supabase returned an invalid meal item.")
        }
        let confidence = try nonNegative(response.confidence, field: "confidence", maximum: 1)
        return MealItem(
            itemID: itemID,
            name: response.name,
            quantity: response.quantity,
            unit: unit,
            caloriesKcal: try nonNegative(response.caloriesKcal, field: "calories_kcal"),
            proteinG: try nonNegative(response.proteinG, field: "protein_g"),
            carbsG: try nonNegative(response.carbsG, field: "carbs_g"),
            fatG: try nonNegative(response.fatG, field: "fat_g"),
            fiberG: try nonNegative(response.fiberG, field: "fiber_g"),
            sugarG: try nonNegative(response.sugarG, field: "sugar_g"),
            confidence: confidence,
            notes: response.sourceNotes,
            source: source
        )
    }

    func parseStoredGoal(_ response: GoalResponse) throws -> StoredDashboardGoal {
        guard let source = GoalSource(rawValue: response.source) else {
            throw MorselError.invalidData("Supabase returned an invalid calorie goal source.")
        }
        return StoredDashboardGoal(
            calorieTargetKcal: try positive(response.calorieTargetKcal, field: "calorie_target_kcal"),
            proteinG: try nonNegative(response.proteinG, field: "protein_g"),
            carbsG: try nonNegative(response.carbsG, field: "carbs_g"),
            fatG: try nonNegative(response.fatG, field: "fat_g"),
            source: source
        )
    }

    func parseProfile(_ response: ProfileResponse) throws -> DashboardProfile {
        guard let sex = ProfileSex(rawValue: response.sex),
              let activityLevel = ProfileActivityLevel(rawValue: response.activityLevel),
              let dietGoal = ProfileDietGoal(rawValue: response.dietGoal),
              (10...100).contains(response.ageYears),
              response.heightCm.isFinite,
              (100...250).contains(response.heightCm),
              response.weightKg.isFinite,
              (30...300).contains(response.weightKg),
              validGoalWeight(response.goalWeightKg) else {
            throw MorselError.invalidData("Supabase returned an invalid profile.")
        }
        return DashboardProfile(
            sex: sex,
            ageYears: response.ageYears,
            heightCm: response.heightCm,
            weightKg: response.weightKg,
            activityLevel: activityLevel,
            dietGoal: dietGoal,
            goalWeightKg: response.goalWeightKg
        )
    }

    private func validGoalWeight(_ value: Double?) -> Bool {
        guard let value else {
            return true
        }
        return value.isFinite && value > 0
    }

    private func nonNegative(_ value: Double?, field: String, maximum: Double? = nil) throws -> Double? {
        guard let value else {
            return nil
        }
        guard value.isFinite, value >= 0 else {
            throw MorselError.invalidData("Supabase returned an invalid \(field) value.")
        }
        if let maximum, value > maximum {
            throw MorselError.invalidData("Supabase returned an invalid \(field) value.")
        }
        return value
    }

    private func positive(_ value: Double?, field: String) throws -> Double? {
        guard let value else {
            return nil
        }
        guard value.isFinite, value > 0 else {
            throw MorselError.invalidData("Supabase returned an invalid \(field) value.")
        }
        return value
    }
}

enum MorselDate {
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct MealLogResponse: Decodable {
    let id: String
    let eatenAt: String
    let mealType: String
    let source: String
    let imagePath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case eatenAt = "eaten_at"
        case mealType = "meal_type"
        case source
        case imagePath = "image_path"
    }
}

private struct LogMealResponse: Decodable {
    let mealLogID: String

    enum CodingKeys: String, CodingKey {
        case mealLogID = "meal_log_id"
    }
}

struct MealItemResponse: Decodable {
    let id: String
    let mealLogID: String
    let name: String
    let quantity: Double
    let unit: String
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fiberG: Double?
    let sugarG: Double?
    let confidence: Double?
    let sourceNotes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case mealLogID = "meal_log_id"
        case name
        case quantity
        case unit
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
        case sugarG = "sugar_g"
        case confidence
        case sourceNotes = "source_notes"
    }
}

struct GoalResponse: Decodable {
    let calorieTargetKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let source: String

    enum CodingKeys: String, CodingKey {
        case calorieTargetKcal = "calorie_target_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case source
    }
}

private struct WeightResponse: Decodable {
    let measuredAt: String
    let kilograms: Double

    enum CodingKeys: String, CodingKey {
        case measuredAt = "measured_at"
        case kilograms = "kg"
    }
}

private struct EnergyResponse: Decodable {
    let burnedAt: String
    let activeKilocalories: Double
    enum CodingKeys: String, CodingKey {
        case burnedAt = "burned_at"
        case activeKilocalories = "active_kcal"
    }
}

struct ProfileResponse: Decodable {
    let sex: String
    let ageYears: Int
    let heightCm: Double
    let weightKg: Double
    let activityLevel: String
    let dietGoal: String
    let goalWeightKg: Double?

    enum CodingKeys: String, CodingKey {
        case sex
        case ageYears = "age_years"
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case activityLevel = "activity_level"
        case dietGoal = "diet_goal"
        case goalWeightKg = "goal_weight_kg"
    }
}

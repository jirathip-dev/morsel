import Foundation
import Supabase

private let mealItemColumns = [
    "id", "meal_log_id", "name", "quantity", "unit", "calories_kcal", "protein_g",
    "carbs_g", "fat_g", "fiber_g", "sugar_g", "confidence", "source_notes"
].joined(separator: ",")

protocol DashboardRepository {
    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot
    func confirmMealItem(userID: UUID, itemID: UUID) async throws
}

final class MockDashboardRepository: DashboardRepository {
    private var currentSnapshot: DashboardSnapshot

    init(snapshot: DashboardSnapshot) {
        currentSnapshot = snapshot
    }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        _ = userID
        _ = date
        return currentSnapshot
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {
        _ = userID
        var found = false
        let meals = currentSnapshot.meals.map { meal in
            let items = meal.items.map { item in
                guard item.itemID == itemID else {
                    return item
                }
                found = true
                return MealItem(
                    itemID: item.itemID,
                    name: item.name,
                    quantity: item.quantity,
                    unit: item.unit,
                    caloriesKcal: item.caloriesKcal,
                    proteinG: item.proteinG,
                    carbsG: item.carbsG,
                    fatG: item.fatG,
                    fiberG: item.fiberG,
                    sugarG: item.sugarG,
                    confidence: 1.0,
                    notes: item.notes
                )
            }
            return MealRecord(
                mealLogID: meal.mealLogID,
                mealType: meal.mealType,
                eatenAt: meal.eatenAt,
                source: meal.source,
                items: items
            )
        }
        guard found else {
            throw MorselError.invalidData("The meal item could not be reviewed.")
        }
        currentSnapshot = DashboardSnapshot(date: currentSnapshot.date, meals: meals, goal: currentSnapshot.goal)
    }
}

struct SupabaseDashboardRepository: DashboardRepository {
    let client: SupabaseClient?

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        guard let client else {
            throw MorselError.configurationMissing
        }
        try await requireSession(client, userID: userID)

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let start = utcCalendar.startOfDay(for: date)
        guard let end = utcCalendar.date(byAdding: .day, value: 1, to: start) else {
            throw MorselError.invalidData("The dashboard date could not be calculated.")
        }

        let logs = try await loadMealLogs(client, userID: userID, start: start, end: end)
        let items = try await loadMealItems(client, logs: logs)
        let goalRows = try await loadGoals(client, userID: userID)
        let profileRows = try await loadProfiles(client, userID: userID)

        var itemsByMealID: [String: [MealItem]] = [:]
        for item in items {
            itemsByMealID[item.mealLogID, default: []].append(try parseItem(item))
        }
        let meals = try logs.map { log in
            try parseMeal(log, items: itemsByMealID[log.id] ?? [])
        }
        let storedGoal = try goalRows.first.map(parseStoredGoal)
        let profile = try profileRows.first.map(parseProfile)
        let goal = DashboardMath.effectiveGoal(stored: storedGoal, profile: profile)
        return DashboardSnapshot(date: start, meals: meals, goal: goal)
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {
        guard let client else {
            throw MorselError.configurationMissing
        }
        try await requireSession(client, userID: userID)
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
        _ = try parseItem(item)
    }

    private func requireSession(_ client: SupabaseClient, userID: UUID) async throws {
        let session = try await client.auth.session
        guard session.user.id == userID else {
            throw MorselError.invalidInput("The Supabase session does not match this user.")
        }
    }

    private func loadMealLogs(
        _ client: SupabaseClient,
        userID: UUID,
        start: Date,
        end: Date
    ) async throws -> [MealLogResponse] {
        try await client
            .from("meal_logs")
            .select("id,eaten_at,meal_type,source")
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
            items: items
        )
    }

    private func parseItem(_ response: MealItemResponse) throws -> MealItem {
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
            notes: response.sourceNotes
        )
    }

    private func parseStoredGoal(_ response: GoalResponse) throws -> StoredDashboardGoal {
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

    private func parseProfile(_ response: ProfileResponse) throws -> DashboardProfile {
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

private enum MorselDate {
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

    enum CodingKeys: String, CodingKey {
        case id
        case eatenAt = "eaten_at"
        case mealType = "meal_type"
        case source
    }
}

private struct MealItemResponse: Decodable {
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

private struct MealItemReviewUpdate: Encodable {
    let confidence: Double
}

private struct GoalResponse: Decodable {
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

private struct ProfileResponse: Decodable {
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

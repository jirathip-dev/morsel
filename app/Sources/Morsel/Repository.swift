import Foundation

private let mealItemColumns = [
    "id", "meal_log_id", "name", "quantity", "unit", "calories_kcal", "protein_g",
    "carbs_g", "fat_g", "fiber_g", "sugar_g", "confidence", "source_notes"
].joined(separator: ",")

protocol DashboardRepository {
    func loadToday(userID: UUID, accessToken: String, date: Date) async throws -> DashboardSnapshot
}

struct MockDashboardRepository: DashboardRepository {
    let snapshot: DashboardSnapshot

    func loadToday(userID: UUID, accessToken: String, date: Date) async throws -> DashboardSnapshot {
        _ = userID
        _ = date
        guard !accessToken.isEmpty else {
            throw MorselError.invalidInput("An access token is required.")
        }
        return snapshot
    }
}

struct SupabaseDashboardRepository: DashboardRepository {
    let baseURL: URL?
    let anonKey: String
    let urlSession: URLSession

    init(baseURL: URL?, anonKey: String, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.urlSession = urlSession
    }

    func loadToday(userID: UUID, accessToken: String, date: Date) async throws -> DashboardSnapshot {
        guard baseURL != nil, !anonKey.isEmpty else {
            throw MorselError.configurationMissing
        }
        guard !accessToken.isEmpty else {
            throw MorselError.invalidInput("An access token is required.")
        }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let start = utcCalendar.startOfDay(for: date)
        guard let end = utcCalendar.date(byAdding: .day, value: 1, to: start) else {
            throw MorselError.invalidData("The dashboard date could not be calculated.")
        }

        let logs = try await loadMealLogs(
            userID: userID,
            start: start,
            end: end,
            accessToken: accessToken
        )
        let items = try await loadMealItems(logs: logs, accessToken: accessToken)
        let goalRows = try await loadGoals(userID: userID, accessToken: accessToken)

        var itemsByMealID: [String: [MealItem]] = [:]
        for item in items {
            itemsByMealID[item.mealLogID, default: []].append(try parseItem(item))
        }
        let meals = try logs.map { log in
            try parseMeal(log, items: itemsByMealID[log.id] ?? [])
        }
        let goal = try goalRows.first.map(parseGoal)
        return DashboardSnapshot(date: start, meals: meals, goal: goal)
    }

    private func loadMealLogs(
        userID: UUID,
        start: Date,
        end: Date,
        accessToken: String
    ) async throws -> [MealLogResponse] {
        try await request(
            MealLogResponse.self,
            path: ["rest", "v1", "meal_logs"],
            query: [
                URLQueryItem(name: "select", value: "id,eaten_at,meal_type,source"),
                URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString)"),
                URLQueryItem(name: "eaten_at", value: "gte.\(MorselDate.iso8601(start))"),
                URLQueryItem(name: "eaten_at", value: "lt.\(MorselDate.iso8601(end))"),
                URLQueryItem(name: "order", value: "eaten_at.asc")
            ],
            accessToken: accessToken
        )
    }

    private func loadMealItems(
        logs: [MealLogResponse],
        accessToken: String
    ) async throws -> [MealItemResponse] {
        guard !logs.isEmpty else {
            return []
        }
        let mealIDs = logs.map { $0.id }.joined(separator: ",")
        return try await request(
            MealItemResponse.self,
            path: ["rest", "v1", "meal_items"],
            query: [
                URLQueryItem(name: "select", value: mealItemColumns),
                URLQueryItem(name: "meal_log_id", value: "in.(\(mealIDs))"),
                URLQueryItem(name: "order", value: "created_at.asc")
            ],
            accessToken: accessToken
        )
    }

    private func loadGoals(userID: UUID, accessToken: String) async throws -> [GoalResponse] {
        try await request(
            GoalResponse.self,
            path: ["rest", "v1", "goals"],
            query: [
                URLQueryItem(name: "select", value: "calorie_target_kcal,protein_g,carbs_g,fat_g,source"),
                URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString)"),
                URLQueryItem(name: "limit", value: "1")
            ],
            accessToken: accessToken
        )
    }

    private func request<Response: Decodable>(
        _: Response.Type,
        path: [String],
        query: [URLQueryItem],
        accessToken: String
    ) async throws -> [Response] {
        guard let baseURL else {
            throw MorselError.configurationMissing
        }
        let pathURL = path.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        guard var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false) else {
            throw MorselError.invalidData("The Supabase URL is invalid.")
        }
        components.queryItems = query
        guard let resolvedURL = components.url else {
            throw MorselError.invalidData("The Supabase request URL is invalid.")
        }

        var request = URLRequest(url: resolvedURL)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MorselError.invalidData("Supabase returned an invalid response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MorselError.requestFailed(httpResponse.statusCode, message)
        }
        do {
            return try JSONDecoder().decode([Response].self, from: data)
        } catch {
            throw MorselError.decodingFailed
        }
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

    private func parseGoal(_ response: GoalResponse) throws -> DashboardGoal {
        guard let source = GoalSource(rawValue: response.source),
              response.calorieTargetKcal.isFinite,
              response.calorieTargetKcal > 0,
              let proteinG = try nonNegative(response.proteinG, field: "protein_g"),
              let carbsG = try nonNegative(response.carbsG, field: "carbs_g"),
              let fatG = try nonNegative(response.fatG, field: "fat_g") else {
            throw MorselError.invalidData("Supabase returned an incomplete calorie goal.")
        }
        return DashboardGoal(
            calorieTargetKcal: response.calorieTargetKcal,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            source: source
        )
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

private struct GoalResponse: Decodable {
    let calorieTargetKcal: Double
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

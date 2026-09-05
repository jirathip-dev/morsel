import Foundation

final class MockDashboardRepository: DashboardRepository {
    private var currentSnapshot: DashboardSnapshot
    private var imageData: [String: Data] = [:]
    private let profile = DashboardProfile(
        sex: .male, ageYears: 30, heightCm: 180, weightKg: 80,
        activityLevel: .moderate, dietGoal: .maintain, goalWeightKg: nil
    )
    private(set) var uploadedImagePaths: [String] = []
    private(set) var loadCount = 0
    var failMealLog = false
    private var storedGoal: StoredDashboardGoal?
    /// Issue #113 — seeded Goals-page context (recency + profile line tests).
    private var contextProfile: DashboardProfile?
    private var contextLatestWeight: SyncedWeightSample?

    init(snapshot: DashboardSnapshot) {
        currentSnapshot = snapshot
        storedGoal = snapshot.goal.map {
            StoredDashboardGoal(
                calorieTargetKcal: $0.calorieTargetKcal, proteinG: $0.proteinG,
                carbsG: $0.carbsG, fatG: $0.fatG, source: $0.source
            )
        }
    }

    func seedGoalsContext(profile: DashboardProfile?, latestWeight: SyncedWeightSample?) {
        contextProfile = profile
        contextLatestWeight = latestWeight
    }

    /// Issue #113 — seed the stored goals row directly (with a write time
    /// when recency is under test).
    func seedStoredGoal(_ stored: StoredDashboardGoal) {
        storedGoal = stored
        currentSnapshot = DashboardSnapshot(
            date: currentSnapshot.date, meals: currentSnapshot.meals,
            goal: DashboardGoal(
                calorieTargetKcal: stored.calorieTargetKcal ?? 0,
                proteinG: stored.proteinG ?? 0, carbsG: stored.carbsG ?? 0,
                fatG: stored.fatG ?? 0, source: stored.source
            )
        )
    }

    func loadGoalsContext(userID: UUID) async throws -> GoalsPageContext {
        GoalsPageContext(
            stored: storedGoal,
            profile: contextProfile,
            latestWeight: contextLatestWeight,
            profileRowRead: true
        )
    }

    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? {
        _ = userID
        return storedGoal
    }

    private(set) var historyOverview = HistoryOverview(days: [], goal: nil, weightTrend: [])

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        _ = userID
        _ = end
        _ = days
        return historyOverview
    }

    /// Seed History data for tests/harness. Days outside the requested window
    /// are ignored by the view model's range slices.
    func seed(history: HistoryOverview) {
        historyOverview = history
    }

    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        _ = userID
        let dietGoal: ProfileDietGoal = switch direction {
        case .cut: .lose
        case .maintain: .maintain
        case .bulk: .gain
        }
        return DashboardMath.computedGoal(
            for: DashboardProfile(
                sex: profile.sex, ageYears: profile.ageYears, heightCm: profile.heightCm,
                weightKg: profile.weightKg, activityLevel: profile.activityLevel,
                dietGoal: dietGoal, goalWeightKg: profile.goalWeightKg
            ),
            latestWeightKg: contextLatestWeight?.kilograms
        )
    }

    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {
        _ = userID
        storedGoal = StoredDashboardGoal(
            calorieTargetKcal: goal.calorieTargetKcal, proteinG: goal.proteinG,
            carbsG: goal.carbsG, fatG: goal.fatG, source: goal.source
        )
        currentSnapshot = DashboardSnapshot(
            date: currentSnapshot.date, meals: currentSnapshot.meals,
            goal: DashboardGoal(
                calorieTargetKcal: goal.calorieTargetKcal, proteinG: goal.proteinG,
                carbsG: goal.carbsG, fatG: goal.fatG, source: goal.source
            )
        )
    }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        loadCount += 1
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
                    notes: item.notes,
                    source: item.source
                )
            }
            return MealRecord(
                mealLogID: meal.mealLogID,
                mealType: meal.mealType,
                eatenAt: meal.eatenAt,
                source: meal.source,
                imagePath: meal.imagePath,
                items: items
            )
        }
        guard found else {
            throw MorselError.invalidData("The meal item could not be reviewed.")
        }
        currentSnapshot = DashboardSnapshot(date: currentSnapshot.date, meals: meals, goal: currentSnapshot.goal)
    }

    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {
        _ = userID
        try MealItemUpdateValidation.validate(update)
        var found = false
        let meals = currentSnapshot.meals.map { meal in
            let items = meal.items.map { item in
                guard item.itemID == update.itemID else {
                    return item
                }
                found = true
                return MealItem(
                    itemID: item.itemID,
                    name: update.name ?? item.name,
                    quantity: update.quantity ?? item.quantity,
                    unit: item.unit,
                    caloriesKcal: update.caloriesKcal ?? item.caloriesKcal,
                    proteinG: update.proteinG ?? item.proteinG,
                    carbsG: update.carbsG ?? item.carbsG,
                    fatG: update.fatG ?? item.fatG,
                    fiberG: item.fiberG,
                    sugarG: item.sugarG,
                    confidence: item.confidence,
                    notes: update.source == .manualEdit ? MealSource.manualEdit.rawValue : item.notes,
                    source: item.source
                )
            }
            return MealRecord(
                mealLogID: meal.mealLogID,
                mealType: meal.mealType,
                eatenAt: meal.eatenAt,
                source: meal.source,
                imagePath: meal.imagePath,
                items: items
            )
        }
        guard found else {
            throw MorselError.invalidData("The meal item could not be updated.")
        }
        currentSnapshot = DashboardSnapshot(date: currentSnapshot.date, meals: meals, goal: currentSnapshot.goal)
    }

    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {
        _ = userID
        guard currentSnapshot.meals.contains(where: { $0.mealLogID == mealLogID }) else {
            throw MorselError.invalidData("The meal could not be deleted.")
        }
        let meals = currentSnapshot.meals.filter { $0.mealLogID != mealLogID }
        currentSnapshot = DashboardSnapshot(date: currentSnapshot.date, meals: meals, goal: currentSnapshot.goal)
    }

    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        try MealDraftValidation.validate(draft)
        let imagePath: String?
        if let photo {
            imagePath = try await uploadImage(
                userID: userID,
                path: FoodImageStore.bucketPath(userID: userID, imageID: UUID()),
                upload: photo
            )
        } else {
            imagePath = nil
        }

        guard !failMealLog else {
            if let imagePath {
                removeImage(at: imagePath)
            }
            throw MorselError.requestFailed(422, "The meal could not be saved.")
        }

        let meal = MealRecord(
            mealLogID: UUID(),
            mealType: draft.mealType,
            eatenAt: draft.eatenAt,
            source: photo == nil ? .manual : .photoVision,
            imagePath: imagePath,
            items: draft.items.map { item in
                MealItem(
                    itemID: UUID(),
                    name: item.name,
                    quantity: item.quantity,
                    unit: item.unit,
                    caloriesKcal: item.caloriesKcal,
                    proteinG: item.proteinG,
                    carbsG: item.carbsG,
                    fatG: item.fatG,
                    fiberG: item.fiberG,
                    sugarG: item.sugarG,
                    confidence: item.confidence,
                    notes: item.notes,
                    source: photo == nil ? .manual : .photoVision
                )
            }
        )
        currentSnapshot = DashboardSnapshot(
            date: currentSnapshot.date,
            meals: currentSnapshot.meals + [meal],
            goal: currentSnapshot.goal
        )
        return meal.mealLogID
    }

    func loadMealImage(userID: UUID, path: String) async throws -> Data {
        try FoodImageStore.validate(bucketPath: path, for: userID)
        guard let data = imageData[path] else {
            throw MorselError.invalidData("The meal photo is no longer available.")
        }
        return data
    }

    @discardableResult
    func uploadImage(userID: UUID, path: String, upload: FoodImageUpload) async throws -> String {
        try FoodImageStore.validate(bucketPath: path, for: userID)
        try FoodImageStore.validate(data: upload.data, mimeType: upload.mimeType)
        uploadedImagePaths.append(path)
        imageData[path] = upload.data
        return path
    }

    func removeImage(at path: String) {
        imageData.removeValue(forKey: path)
        uploadedImagePaths.removeAll { $0 == path }
    }
}

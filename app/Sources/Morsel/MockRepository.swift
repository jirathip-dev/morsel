import Foundation

final class MockDashboardRepository: DashboardRepository {
    private var currentSnapshot: DashboardSnapshot
    private var imageData: [String: Data] = [:]
    private(set) var uploadedImagePaths: [String] = []
    var failMealLog = false

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

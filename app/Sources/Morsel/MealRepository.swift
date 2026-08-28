import Foundation
import Supabase

extension SupabaseDashboardRepository {
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        try MealDraftValidation.validate(draft)
        let uploadedImage = try await uploadPhoto(
            photo,
            client: client,
            userID: authenticatedUserID
        )

        do {
            let response: [LogMealResponse] = try await client
                .rpc(
                    "log_meal_with_items",
                    params: LogMealParameters(
                        userID: authenticatedUserID,
                        eatenAt: MorselDate.iso8601(draft.eatenAt),
                        mealType: draft.mealType.rawValue,
                        source: photo == nil ? MealSource.manual.rawValue : MealSource.photoVision.rawValue,
                        imagePath: uploadedImage?.bucketPath,
                        notes: draft.notes,
                        items: draft.items.map(LogMealItemParameters.init)
                    )
                )
                .execute()
                .value
            guard let mealLogID = response.first.flatMap({ UUID(uuidString: $0.mealLogID) }) else {
                throw MorselError.decodingFailed
            }
            return mealLogID
        } catch {
            if let objectPath = uploadedImage?.objectPath {
                _ = try? await client.storage.from(FoodImageStore.bucket).remove(paths: [objectPath])
            }
            throw error
        }
    }

    func loadMealImage(userID: UUID, path: String) async throws -> Data {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        let objectPath = try FoodImageStore.validate(bucketPath: path, for: authenticatedUserID)
        return try await client.storage.from(FoodImageStore.bucket).download(path: objectPath)
    }

    private func uploadPhoto(
        _ photo: FoodImageUpload?,
        client: SupabaseClient,
        userID: UUID
    ) async throws -> UploadedMealImage? {
        guard let photo else {
            return nil
        }
        try FoodImageStore.validate(data: photo.data, mimeType: photo.mimeType)
        let imageID = UUID()
        let bucketPath = FoodImageStore.bucketPath(userID: userID, imageID: imageID)
        let objectPath = try FoodImageStore.validate(bucketPath: bucketPath, for: userID)
        let response = try await client.storage.from(FoodImageStore.bucket).upload(
            objectPath,
            data: photo.data,
            options: FileOptions(contentType: photo.mimeType, upsert: false)
        )
        guard response.fullPath == bucketPath else {
            _ = try? await client.storage.from(FoodImageStore.bucket).remove(paths: [objectPath])
            throw MorselError.invalidData("Supabase returned an unexpected meal photo path.")
        }
        return UploadedMealImage(bucketPath: bucketPath, objectPath: objectPath)
    }
}

private struct UploadedMealImage {
    let bucketPath: String
    let objectPath: String
}

private struct LogMealResponse: Decodable {
    let mealLogID: String

    enum CodingKeys: String, CodingKey {
        case mealLogID = "meal_log_id"
    }
}

private struct LogMealParameters: Encodable {
    let userID: String
    let eatenAt: String
    let mealType: String
    let source: String
    let imagePath: String?
    let notes: String?
    let items: [LogMealItemParameters]

    enum CodingKeys: String, CodingKey {
        case userID = "p_user_id"
        case eatenAt = "p_eaten_at"
        case mealType = "p_meal_type"
        case source = "p_source"
        case imagePath = "p_image_path"
        case notes = "p_notes"
        case items = "p_items"
    }

    init(
        userID: UUID,
        eatenAt: String,
        mealType: String,
        source: String,
        imagePath: String?,
        notes: String?,
        items: [LogMealItemParameters]
    ) {
        self.userID = userID.uuidString
        self.eatenAt = eatenAt
        self.mealType = mealType
        self.source = source
        self.imagePath = imagePath
        self.notes = notes
        self.items = items
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userID, forKey: .userID)
        try container.encode(eatenAt, forKey: .eatenAt)
        try container.encode(mealType, forKey: .mealType)
        try container.encode(source, forKey: .source)
        try container.encode(imagePath, forKey: .imagePath)
        try container.encode(notes, forKey: .notes)
        try container.encode(items, forKey: .items)
    }
}

private struct LogMealItemParameters: Encodable {
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

    init(_ item: MealItemDraft) {
        name = item.name
        quantity = item.quantity
        unit = item.unit.rawValue
        caloriesKcal = item.caloriesKcal
        proteinG = item.proteinG
        carbsG = item.carbsG
        fatG = item.fatG
        fiberG = item.fiberG
        sugarG = item.sugarG
        confidence = item.confidence
        sourceNotes = item.notes
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
        case confidence
        case sourceNotes = "source_notes"
    }
}

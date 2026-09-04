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

// MARK: - Issue #106 outbox remote writer

extension SupabaseDashboardRepository: RemoteMealWriting {
    /// Idempotent photo upload: the object path is derived from the meal's
    /// client identity, so a retried delivery uploads the SAME object (never
    /// an orphaned duplicate) and can safely upsert over a half-committed
    /// previous attempt.
    func uploadMealPhoto(userID: UUID, mealID: UUID, photo: QueuedMealPhoto) async throws -> String {
        guard let client else {
            throw MorselError.configurationMissing
        }
        _ = try await requireSession(client, userID: userID)
        try FoodImageStore.validate(data: photo.data, mimeType: photo.mimeType)
        let bucketPath = FoodImageStore.bucketPath(userID: userID, imageID: mealID)
        let objectPath = try FoodImageStore.validate(bucketPath: bucketPath, for: userID)
        let response = try await client.storage.from(FoodImageStore.bucket).upload(
            objectPath,
            data: photo.data,
            options: FileOptions(contentType: photo.mimeType, upsert: true)
        )
        guard response.fullPath == bucketPath else {
            throw MorselError.invalidData("Supabase returned an unexpected meal photo path.")
        }
        return bucketPath
    }

    /// Authenticated, idempotent meal commit: the client-generated meal id is
    /// the server primary key (migration 0010 conflict guard), so a retry
    /// after a server-side commit reads back the existing authoritative row
    /// instead of inserting a duplicate.
    func commitMeal(userID: UUID, meal: QueuedMeal, imagePath: String?) async throws {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID: UUID
        do {
            authenticatedUserID = try await requireSession(client, userID: userID)
        } catch {
            throw classifyRemoteMealError(error)
        }
        let response: [LogMealResponse]
        do {
            response = try await client
                .rpc(
                    "log_meal_with_items_client",
                    params: LogMealParameters(
                        userID: authenticatedUserID,
                        eatenAt: MorselDate.iso8601(meal.eatenAt),
                        mealType: meal.mealType.rawValue,
                        source: meal.source.rawValue,
                        imagePath: imagePath,
                        notes: meal.notes,
                        items: meal.draft.items.map(LogMealItemParameters.init),
                        clientMealID: meal.mealID
                    )
                )
                .execute()
                .value
        } catch {
            throw classifyRemoteMealError(error)
        }
        guard let returnedID = response.first.flatMap({ UUID(uuidString: $0.mealLogID) }) else {
            throw MealDeliveryError.permanent(.server)
        }
        guard returnedID == meal.mealID else {
            // The server must return the row for OUR client id — anything
            // else means the commit did not target this queued meal.
            throw MealDeliveryError.permanent(.server)
        }
    }

    func removeRemotePhoto(userID: UUID, bucketPath: String) async throws {
        guard let client else { return }
        if let objectPath = try? FoodImageStore.validate(bucketPath: bucketPath, for: userID) {
            _ = try? await client.storage.from(FoodImageStore.bucket).remove(paths: [objectPath])
        }
    }
}

/// Maps raw Supabase/transport errors to retry-policy categories. Raw system
/// text is never persisted or surfaced — only the friendly category copy.
func classifyRemoteMealError(_ error: Error) -> MealDeliveryError {
    if let delivery = error as? MealDeliveryError {
        return delivery
    }
    if let postgrest = error as? PostgrestError {
        // Postgres SQLSTATE: 42xxx = auth/RLS refusal (42501 raised by the
        // security-invoker meal function), 22xxx = validation refusal.
        let code = postgrest.code ?? ""
        if code == "42501" {
            return .permanent(.auth)
        }
        if code.hasPrefix("42") || code.hasPrefix("22") || code == "P0001" {
            return .permanent(.validation)
        }
        return .permanent(.server)
    }
    if let morselError = error as? MorselError {
        switch morselError {
        case .invalidInput, .invalidData:
            return .permanent(.validation)
        case let .requestFailed(status, _):
            return (400..<500).contains(status) ? .permanent(.auth) : .transient(.server)
        default:
            return .transient(.network)
        }
    }
    if error is URLError {
        return .transient(.network)
    }
    if error is FoodImageError {
        return .permanent(.photo)
    }
    return .transient(.network)
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
    let clientMealID: String?

    enum CodingKeys: String, CodingKey {
        case userID = "p_user_id"
        case eatenAt = "p_eaten_at"
        case mealType = "p_meal_type"
        case source = "p_source"
        case imagePath = "p_image_path"
        case notes = "p_notes"
        case items = "p_items"
        case clientMealID = "p_client_meal_id"
    }

    init(
        userID: UUID,
        eatenAt: String,
        mealType: String,
        source: String,
        imagePath: String?,
        notes: String?,
        items: [LogMealItemParameters],
        clientMealID: UUID? = nil
    ) {
        self.userID = userID.uuidString
        self.eatenAt = eatenAt
        self.mealType = mealType
        self.source = source
        self.imagePath = imagePath
        self.notes = notes
        self.items = items
        self.clientMealID = clientMealID?.uuidString
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
        try container.encodeIfPresent(clientMealID, forKey: .clientMealID)
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

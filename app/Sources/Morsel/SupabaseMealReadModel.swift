import Foundation
import Supabase

// Issue #135 — Supabase meal READ-model helpers (kept out of Repository.swift
// so both files stay inside the lint budgets): per-read signed-URL hydration
// for stored meal photos (the #133 contract, MealRecordSchema.image {path,
// signed_url, expires_at}) and the meal record parse that attaches the image
// contract to the row and its items.
extension SupabaseDashboardRepository {
    /// Parses one meal log row into the read model, attaching the #133 image
    /// contract ({path, signed_url, expires_at}) when the meal has a photo.
    /// The canonical object path wins over a legacy bucket-qualified
    /// image_path so server-logged and app-logged rows render identically.
    func parseMeal(
        _ response: MealLogResponse,
        items: [MealItem],
        image: MealImage? = nil
    ) throws -> MealRecord {
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
            imagePath: image?.path ?? response.imagePath,
            image: image,
            items: items.map { $0.withMealImage(image) }
        )
    }

    /// Mints the per-read signed URL for each stored meal photo — 15-minute
    /// TTL like the server. URLs are refreshed on every read, so an expired
    /// URL from a cached snapshot is never reused. A row whose signing fails
    /// (offline/RLS) still carries its canonical path — the
    /// authenticated-download thumbnail pipeline renders it without a URL.
    func mintMealImages(
        logs: [MealLogResponse],
        client: SupabaseClient,
        userID: UUID,
        now: Date = Date()
    ) async -> [String: MealImage] {
        let signedTTLSeconds = 15 * 60
        var images: [String: MealImage] = [:]
        for log in logs {
            guard let storedPath = log.imagePath,
                  let objectPath = try? FoodImageStore.validate(bucketPath: storedPath, for: userID) else {
                continue
            }
            let signedURL = try? await client
                .storage
                .from(FoodImageStore.bucket)
                .createSignedURL(path: objectPath, expiresIn: signedTTLSeconds)
            images[log.id] = MealImage(
                path: objectPath,
                signedURL: signedURL,
                expiresAt: signedURL.map { _ in now.addingTimeInterval(TimeInterval(signedTTLSeconds)) }
            )
        }
        return images
    }
}

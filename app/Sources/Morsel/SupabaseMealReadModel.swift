import Foundation
import Supabase

// Issue #135 — Supabase meal READ-model helpers (kept out of Repository.swift
// so both files stay inside the lint budgets): the meal record parse that
// attaches the image contract to the row and its items, the path-only attach
// first paint uses (#179), and the LAZY signed-URL mint a URL consumer calls
// on demand (the #133 contract, MealRecordSchema.image {path, signed_url,
// expires_at}).
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

    /// Issue #179 — the canonical, account-validated image path for every
    /// stored photo, attached to the read model with NO network work: first
    /// paint never waits for — or issues — a signing request. The path is
    /// validated exactly like the download seam, so a row that fails
    /// validation (foreign or malformed) carries no image contract while its
    /// raw column still reaches consumers for legacy rendering.
    func mealImagePaths(logs: [MealLogResponse], userID: UUID) -> [String: MealImage] {
        var images: [String: MealImage] = [:]
        for log in logs {
            guard let storedPath = log.imagePath,
                  let objectPath = try? FoodImageStore.validate(bucketPath: storedPath, for: userID) else {
                continue
            }
            images[log.id] = MealImage(path: objectPath)
        }
        return images
    }

    /// Issue #179 — LAZY mint of the per-read signed URL for stored meal
    /// photos: 15-minute TTL like the server, called only by a consumer that
    /// genuinely requires a URL. The native read graph (Today/History) never
    /// calls it — it carries `mealImagePaths` values and the thumbnail/Edit
    /// surfaces download bytes through the authenticated `loadMealImage` seam
    /// — so native first paint issues zero signing calls. A row whose signing
    /// fails (offline/RLS) still carries its canonical path.
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

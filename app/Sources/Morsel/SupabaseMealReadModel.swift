import Foundation
import Supabase

// Issue #135 — Supabase meal READ-model helpers (kept out of Repository.swift
// so both files stay inside the lint budgets): the meal record parse that
// attaches the image contract to the row and its items, the path-only attach
// first paint uses (#179), and the LAZY signed-URL mint a URL consumer calls
// on demand (the #133 contract, MealRecordSchema.image {path, signed_url,
// expires_at}).

/// Issue #258 — how completely one meal's item rows were read. A day read
/// DEGRADES instead of aborting when `meal_items` cannot be read (or one row
/// is unreadable): the meal still renders, flagged `.incomplete`, so a
/// consumer can tell "nothing logged" from "read incomplete". Nil (rather
/// than `.complete`) on records no remote item read produced. Declared here
/// with the projection that sets it — `Models.swift` holds the 400-line
/// SwiftLint `file_length` cap.
enum MealItemsReadState: String, Sendable, Codable {
    case complete
    case incomplete

    /// True only when the read is known to be short of what was logged.
    var isIncomplete: Bool { self == .incomplete }
}

/// One day read's items, keyed by meal, plus the meals whose rows could not be
/// read (issue #258). `incompleteMealIDs` is never empty-by-accident: a failed
/// read marks every meal of the day, and an unreadable row marks its owner.
struct DayItemsRead {
    let itemsByMealID: [String: [MealItem]]
    let incompleteMealIDs: Set<String>
}

extension SupabaseDashboardRepository {
    /// Issue #258 — one day read's item rows, DEGRADED instead of aborting: a
    /// failed item read (`items == nil`) marks every meal of the day
    /// incomplete, while one item row that cannot be parsed marks only the
    /// meal that owns it. Every readable row survives, so one bad row never
    /// hides the rest of the day.
    func dayItems(logs: [MealLogResponse], items: [MealItemResponse]?) throws -> DayItemsRead {
        var sourcesByMealID: [String: MealSource] = [:]
        for log in logs {
            guard let source = MealSource(rawValue: log.source) else {
                throw MorselError.invalidData("Supabase returned an invalid meal log.")
            }
            sourcesByMealID[log.id] = source
        }
        var itemsByMealID: [String: [MealItem]] = [:]
        // The read failed as a whole, or only some rows did.
        var incompleteMealIDs = items == nil ? Set(logs.map(\.id)) : []
        for item in items ?? [] {
            // A row whose meal is not in this day cannot be attributed (and is
            // not part of the day): drop it rather than aborting the read.
            guard let source = sourcesByMealID[item.mealLogID] else { continue }
            guard let parsed = try? parseItem(item, source: source) else {
                incompleteMealIDs.insert(item.mealLogID)
                continue
            }
            itemsByMealID[item.mealLogID, default: []].append(parsed)
        }
        return DayItemsRead(itemsByMealID: itemsByMealID, incompleteMealIDs: incompleteMealIDs)
    }

    /// Parses one meal log row into the read model, attaching the #133 image
    /// contract ({path, signed_url, expires_at}) when the meal has a photo.
    /// The canonical object path wins over a legacy bucket-qualified
    /// image_path so server-logged and app-logged rows render identically.
    func parseMeal(
        _ response: MealLogResponse,
        items: [MealItem],
        image: MealImage? = nil,
        itemsIncomplete: Bool = false
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
            items: items.map { $0.withMealImage(image) },
            itemsRead: itemsIncomplete ? .incomplete : .complete
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

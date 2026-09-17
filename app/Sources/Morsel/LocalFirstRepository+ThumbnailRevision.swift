import Foundation

// Issue #188 — the read seam's revision identity, in its own file so the
// local-first facade stays inside the repo's file-length budget.
//
// The prepared-thumbnail cache asks this BEFORE fetching anything, which is
// what makes a warm revisit a pure memory hit and what makes a same-path
// replacement a new identity instead of a stale surrogate. Nothing else about
// the read path changes: `loadMealImage` still serves the queued outbox bytes
// before the remote object (#135).

extension LocalFirstDashboardRepository: MealPhotoRevisionProviding {
    /// Which bytes `loadMealImage` will serve for this object, and their
    /// revision: the local outbox payload's own content fingerprint while the
    /// meal is still queued (so a replaced queued photo changes the key with
    /// no extra signal, and a queued→remote transition — identical payload,
    /// new source — is a new revision the cache re-files instead of
    /// re-decoding), otherwise this device's remote epoch for the object.
    func mealPhotoRevision(userID: UUID, path: String) async -> MealThumbnailRevision {
        if let queued = try? queuedPhoto(userID: userID, path: path) {
            return .queued(fingerprint: MealThumbnailFingerprint.of(queued.data))
        }
        return .remote(epoch: revisions.observe(accountID: userID, objectPath: path))
    }
}

extension LocalFirstDashboardRepository {
    /// The outbox payload serving one object path, when a queued photo meal
    /// still holds it — the #135 local-first read and the issue #188 revision
    /// share this one truth about which bytes are authoritative.
    ///
    /// Issue #191 — the canonical object path NAMES the meal it belongs to, so
    /// this is a keyed read of exactly that one row: only the requested photo's
    /// payload is ever materialized, never every queued photo's bytes (the
    /// pre-#191 scan). The canonical-form equality below is the SAME match the
    /// scan performed, so which paths resolve is unchanged.
    func queuedPhoto(userID: UUID, path: String) throws -> QueuedMealPhoto? {
        guard let objectPath = try? FoodImageStore.validate(bucketPath: path, for: userID),
              let mealID = Self.queuedMealID(inObjectPath: objectPath),
              FoodImageStore.objectPath(userID: userID, imageID: mealID) == objectPath else {
            return nil
        }
        return try store.queuedMeal(mealID: mealID)?.photo
    }

    /// The meal id a canonical object path names (`{user}/{meal}.jpg`); nil
    /// when the file name is not a meal id, so the caller falls through to the
    /// same canonical-form comparison as before.
    private static func queuedMealID(inObjectPath path: String) -> UUID? {
        guard let name = path.split(separator: "/").last, name.hasSuffix(".jpg") else { return nil }
        return UUID(uuidString: String(name.dropLast(4)))
    }
}

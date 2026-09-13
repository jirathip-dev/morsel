import Foundation

// Issue #188 — this device's own revalidation epochs for stored photo objects.
//
// A photo lives at one canonical object path (`{user_id}/{meal_id}.jpg`) and
// this app REPLACES it by upserting that same path (issue #153), so the path
// alone cannot say whether bytes changed. External changes (another device,
// the MCP server) cannot be seen at all without fetching. The rule this
// registry implements is therefore declared, bounded and signal-driven:
//
//   * the cache never polls — a warm revisit costs zero fetches;
//   * every app-side signal moves exactly the epochs it can name: a replacement
//     at a known object path bumps that object, an attach whose canonical path
//     the server derives bumps the account (a bounded superset);
//   * logout / account switch forgets the account's epochs and leaves every
//     other account's alone.
//
// The registry itself is bounded: at most `maxTrackedObjects` objects are
// tracked (least-recently-observed out first). Forgetting an object is safe —
// it re-observes at epoch 0, which is a NEW revision and so a refetch, never a
// stale serve.

/// Issue #188 — the app's own revalidation epochs for photo objects.
final class MealPhotoRevisions: @unchecked Sendable {
    struct ObjectKey: Hashable {
        let accountID: UUID
        let objectPath: String
    }

    static let shared = MealPhotoRevisions()
    static let maxTrackedObjects = 256

    private struct Tracked {
        var epoch: Int
        var lastObserved: Int
    }

    private let lock = NSLock()
    private var tracked: [ObjectKey: Tracked] = [:]
    private var clock = 0

    /// The object's current epoch: 0 the first time this device asks, and the
    /// same value on every later ask until a signal bumps it — which is what
    /// makes a warm thumbnail read a pure memory hit.
    @discardableResult
    func observe(accountID: UUID, objectPath: String) -> Int {
        let key = ObjectKey(accountID: accountID, objectPath: objectPath)
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        var entry = tracked[key] ?? Tracked(epoch: 0, lastObserved: clock)
        entry.lastObserved = clock
        tracked[key] = entry
        enforceBoundLocked()
        return entry.epoch
    }

    /// A same-path replacement this device performed: every prepared thumbnail
    /// of THAT object is stale from this instant (one refetch each on the next
    /// read — never a stale surrogate).
    func replaced(accountID: UUID, objectPath: String) {
        let key = ObjectKey(accountID: accountID, objectPath: objectPath)
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        var entry = tracked[key] ?? Tracked(epoch: 0, lastObserved: clock)
        entry.epoch += 1
        entry.lastObserved = clock
        tracked[key] = entry
    }

    /// A replacement whose canonical object path this device cannot name
    /// locally (the authenticated attach derives it from the meal id on the
    /// server): every prepared thumbnail OF THE ACCOUNT is stale — a bounded
    /// superset, spent only on an app write.
    func replacedAccount(accountID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        for key in tracked.keys where key.accountID == accountID {
            tracked[key]?.epoch += 1
            tracked[key]?.lastObserved = clock
        }
    }

    /// Logout / account switch: this account's epochs are forgotten, and no
    /// other account is touched.
    func removeAll(accountID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        for key in tracked.keys where key.accountID == accountID {
            tracked.removeValue(forKey: key)
        }
    }
}

// MARK: - Introspection (tests + issue #188 evidence)

extension MealPhotoRevisions {
    /// The object's epoch as currently tracked (0 when not tracked).
    func epoch(accountID: UUID, objectPath: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tracked[ObjectKey(accountID: accountID, objectPath: objectPath)]?.epoch ?? 0
    }

    func trackedCount(accountID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tracked.keys.filter { $0.accountID == accountID }.count
    }

    func totalTrackedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tracked.count
    }
}

private extension MealPhotoRevisions {
    func enforceBoundLocked() {
        while tracked.count > Self.maxTrackedObjects,
              let oldest = tracked.min(by: { $0.value.lastObserved < $1.value.lastObserved }) {
            tracked.removeValue(forKey: oldest.key)
        }
    }
}

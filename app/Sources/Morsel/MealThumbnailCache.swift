import Foundation
import UIKit

// Issue #188 — the bounded, coalescing prepared-thumbnail cache.
//
// The shipped small photo surface (`MealPhotoEditorSection`'s `.photo` figure;
// #223/#229 made every journal row an offline illustration and left real photos
// to detail/edit) reads through this cache:
//
//  * ONE fetch and ONE preparation per identical request (in-flight
//    coalescing), every warm revisit reuses the prepared image;
//  * keyed by account × object path × revision × target pixel size;
//  * bounded by a declared entry capacity and pixel-byte budget with LRU
//    eviction; source bytes are never retained, only prepared pixels;
//  * revision-aware: the local-first read seam names the revision of the bytes
//    it will serve, and the app's write seams bump the objects they replace, so
//    a same-path replacement invalidates instead of serving a stale surrogate.
//
// The full-size path (the authenticated `loadMealImage` bytes, and anything a
// zoom/detail reader wants) stays separate: it is never served a downsampled
// surrogate.

/// Where the cache gets one account's photo bytes, and the revision those bytes
/// carry right now.
///
/// `revision` is asked BEFORE the bytes: that is what makes a warm revisit a
/// pure memory hit, and what makes a replaced object a new identity.
struct MealPhotoSource: @unchecked Sendable {
    let fetch: (UUID, String) async throws -> Data
    let revision: (UUID, String) async -> MealThumbnailRevision

    init(
        fetch: @escaping (UUID, String) async throws -> Data,
        revision: @escaping (UUID, String) async -> MealThumbnailRevision
    ) {
        self.fetch = fetch
        self.revision = revision
    }

    /// The account's repository as a photo source. The local-first facade
    /// answers the revision from its own local state (`MealPhotoRevision
    /// Providing`); every other repository is honestly "remote epoch 0" — no
    /// device-local signal about its objects exists.
    ///
    /// Unchecked `Sendable` because these closures call the shipped repository
    /// from the cache's background task, exactly as the surfaces already call
    /// it from their own tasks.
    init(repository: any DashboardRepository) {
        self.init(
            fetch: { userID, path in try await repository.loadMealImage(userID: userID, path: path) },
            revision: { userID, path in
                guard let local = repository as? any MealPhotoRevisionProviding else {
                    return .remote(epoch: 0)
                }
                return await local.mealPhotoRevision(userID: userID, path: path)
            }
        )
    }
}

/// A repository that can name one of its photos' revision without fetching it.
protocol MealPhotoRevisionProviding {
    func mealPhotoRevision(userID: UUID, path: String) async -> MealThumbnailRevision
}

/// Issue #188 — the prepared-thumbnail cache.
///
/// One instance per app (`.shared`); tests build their own with their own
/// source, capacity and byte budget. Bookkeeping is lock-guarded and tiny; the
/// fetch + preparation run on a background task, and the synchronous decode
/// body runs on `MealThumbnailPreparer`'s executor — never the main actor,
/// never in a view body.
final class MealThumbnailCache: @unchecked Sendable {
    /// What the cache did — the counted (never timed) evidence #188 asks for.
    struct Counters: Equatable, Sendable {
        /// Source fetches started (one per attempt, however many callers).
        var fetches = 0
        /// Off-body preparations that produced an image: one decode per
        /// attempt that had to (a fetch that reused prepared pixels, or that
        /// failed before decoding, adds none).
        var preparations = 0
        /// Attempts that re-filed prepared pixels already in memory instead of
        /// decoding again (same bytes under a new revision key).
        var reuses = 0
        /// Warm reads served from memory without fetching or decoding.
        var hits = 0
        /// Reads that found no prepared entry.
        var misses = 0
        /// Reads that joined an identical in-flight attempt.
        var coalesced = 0
        /// Entries dropped to hold the declared bounds.
        var evictions = 0
        /// Attempts that failed (and cached nothing).
        var failures = 0
    }

    /// Declared bounds: at most this many prepared thumbnails, and this many
    /// pixel bytes. One over-budget entry is still kept and served — thrashing
    /// between fetch and evict is worse than one oversized image.
    static let defaultCapacity = 12
    static let defaultByteLimit = 8 * 1_024 * 1_024

    static let shared = MealThumbnailCache()

    private struct Entry {
        let image: UIImage
        let fingerprint: Int
        let cost: Int
        var lastUse: Int
    }

    private let preparer: MealThumbnailPreparer
    private let capacity: Int
    private let byteLimit: Int
    private let lock = NSLock()
    private var entries: [MealThumbnailKey: Entry] = [:]
    private var inFlight: [MealThumbnailKey: Task<UIImage, Error>] = [:]
    private var accountGenerations: [UUID: Int] = [:]
    private var counters = Counters()
    private var clock = 0
    private var residentBytes = 0

    init(
        preparer: MealThumbnailPreparer = MealThumbnailPreparer(),
        capacity: Int = MealThumbnailCache.defaultCapacity,
        byteLimit: Int = MealThumbnailCache.defaultByteLimit
    ) {
        self.preparer = preparer
        self.capacity = max(1, capacity)
        self.byteLimit = max(1, byteLimit)
    }

    /// The prepared image for one request: a memory hit when the account,
    /// object, revision and target pixels are all unchanged, otherwise one
    /// shared fetch + preparation that every identical concurrent caller joins.
    /// Cancelling the calling task stops that caller waiting (it throws
    /// `CancellationError`) without cancelling the shared attempt or losing its
    /// result.
    func thumbnail(_ request: MealThumbnailRequest, from source: MealPhotoSource) async throws -> UIImage {
        let revision = await source.revision(request.accountID, request.objectPath)
        let key = request.key(revision: revision.token)
        if let hit = cachedImage(for: key) {
            return hit
        }
        let generation = currentGeneration(accountID: request.accountID)
        let image = try await sharedAttempt(for: key, request: request, source: source, generation: generation).value
        try Task.checkCancellation()
        return image
    }

    /// Logout / account switch: drop this account's prepared pixels and retire
    /// its in-flight attempts, so a late completion can no longer publish into
    /// a signed-out account (and no other account is ever touched).
    func removeAll(accountID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        accountGenerations[accountID, default: 0] += 1
        for key in Array(entries.keys) where key.accountID == accountID {
            residentBytes -= entries[key]?.cost ?? 0
            entries.removeValue(forKey: key)
        }
        for key in Array(inFlight.keys) where key.accountID == accountID {
            inFlight.removeValue(forKey: key)
        }
    }
}

// MARK: - Counted state (tests + issue #188 evidence)

extension MealThumbnailCache {
    func snapshotCounters() -> Counters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// Prepared thumbnails currently in memory.
    func residentEntryCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Pixel bytes currently in memory (the declared bound; source bytes are
    /// never retained).
    func residentPixelBytes() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return residentBytes
    }

    /// The identities currently resident — the account/object/revision/pixel
    /// scoping evidence.
    func residentKeys() -> [MealThumbnailKey] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.keys)
    }

    /// The peak number of preparations ever in flight on this cache's worker
    /// (the bounded-memory / bounded-concurrency witness).
    func preparerPeakConcurrency() async -> Int {
        await preparer.peakConcurrentPreparations
    }
}

// MARK: - Warm hits, coalescing, insertion and eviction

private extension MealThumbnailCache {
    func cachedImage(for key: MealThumbnailKey) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else {
            counters.misses += 1
            return nil
        }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        counters.hits += 1
        return entry.image
    }

    /// The shared attempt for one key: the first caller starts it, every other
    /// caller joins it (counted), and its completion always clears the slot.
    func sharedAttempt(
        for key: MealThumbnailKey,
        request: MealThumbnailRequest,
        source: MealPhotoSource,
        generation: Int
    ) -> Task<UIImage, Error> {
        lock.lock()
        if let existing = inFlight[key] {
            counters.coalesced += 1
            lock.unlock()
            return existing
        }
        let attempt = Task.detached(priority: .userInitiated) { [self] in
            do {
                let image = try await fetchAndPrepare(
                    request: request, source: source, key: key, generation: generation
                )
                clearInFlight(key)
                return image
            } catch {
                clearInFlight(key)
                recordFailure()
                throw error
            }
        }
        inFlight[key] = attempt
        lock.unlock()
        return attempt
    }

    func fetchAndPrepare(
        request: MealThumbnailRequest,
        source: MealPhotoSource,
        key: MealThumbnailKey,
        generation: Int
    ) async throws -> UIImage {
        recordFetch()
        let data = try await source.fetch(request.accountID, request.objectPath)
        guard !data.isEmpty else {
            throw MealThumbnailError.missingPhoto
        }
        let fingerprint = MealThumbnailFingerprint.of(data)
        if let reused = takeReusable(for: key, fingerprint: fingerprint) {
            insert(reused, fingerprint: fingerprint, for: key, generation: generation)
            recordReuse()
            return reused
        }
        let prepared = try await preparer.prepare(
            data: data, box: request.displayBox, displayScale: request.displayScale
        )
        recordPreparation()
        insert(prepared, fingerprint: fingerprint, for: key, generation: generation)
        return prepared
    }

    /// The same bytes already prepared for this account/object/box — a new
    /// revision (queued→remote, or a replacement that lands identical bytes)
    /// re-files the prepared pixels instead of decoding them again.
    func takeReusable(for key: MealThumbnailKey, fingerprint: Int) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let match = entries.first(where: { candidate, entry in
            candidate.accountID == key.accountID
                && candidate.objectPath == key.objectPath
                && candidate.targetPixels == key.targetPixels
                && entry.fingerprint == fingerprint
        }) else {
            return nil
        }
        residentBytes -= match.value.cost
        entries.removeValue(forKey: match.key)
        return match.value.image
    }

    func insert(_ image: UIImage, fingerprint: Int, for key: MealThumbnailKey, generation: Int) {
        let cost = MealThumbnailPixels.byteCost(of: image)
        lock.lock()
        defer { lock.unlock() }
        guard accountGenerations[key.accountID, default: 0] == generation else {
            return // retired by logout/account switch while this attempt ran
        }
        if let previous = entries.removeValue(forKey: key) {
            residentBytes -= previous.cost
        }
        pruneStaleRevisionsLocked(for: key)
        clock += 1
        entries[key] = Entry(image: image, fingerprint: fingerprint, cost: cost, lastUse: clock)
        residentBytes += cost
        evictLocked()
    }

    /// A replaced object keeps ONE resident revision per target: the stale
    /// pixels are dropped as the fresh ones land, so "a same-path replacement
    /// invalidates the affected entries" is true of the memory too, not just of
    /// the key.
    func pruneStaleRevisionsLocked(for key: MealThumbnailKey) {
        for candidate in Array(entries.keys) where candidate != key
            && candidate.accountID == key.accountID
            && candidate.objectPath == key.objectPath
            && candidate.targetPixels == key.targetPixels {
            residentBytes -= entries[candidate]?.cost ?? 0
            entries.removeValue(forKey: candidate)
        }
    }

    func evictLocked() {
        while entries.count > capacity || residentBytes > byteLimit {
            guard entries.count > 1, let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else {
                return
            }
            residentBytes -= victim.value.cost
            entries.removeValue(forKey: victim.key)
            counters.evictions += 1
        }
    }

    func clearInFlight(_ key: MealThumbnailKey) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.removeValue(forKey: key)
    }

    func currentGeneration(accountID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return accountGenerations[accountID, default: 0]
    }

    func recordFetch() {
        lock.lock()
        defer { lock.unlock() }
        counters.fetches += 1
    }

    func recordReuse() {
        lock.lock()
        defer { lock.unlock() }
        counters.reuses += 1
    }

    func recordFailure() {
        lock.lock()
        defer { lock.unlock() }
        counters.failures += 1
    }
}

// MARK: - Preparation counting

extension MealThumbnailCache {
    /// Counts one off-body preparation (the prepper body owns the decode, so
    /// the cache records the attempt it caused here, at the same seam the
    /// other counters use).
    func recordPreparation() {
        lock.lock()
        defer { lock.unlock() }
        counters.preparations += 1
    }
}

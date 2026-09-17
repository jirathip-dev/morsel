import Foundation

// Issue #106 — durable background reconciliation for the account-scoped
// local store. ONE worker per account (single-flight: a requested pass while
// a pass is running re-runs once afterwards, never concurrently). Retries
// reuse the same client-generated meal identity and the server-side primary
// key conflict guard (migration 0010), so a timeout after a server commit
// can never duplicate a meal. Permanent refusals (auth/validation) move the
// row to a durable needs-attention state that preserves the payload; only
// transient failures are retried with bounded backoff. Secrets are never
// persisted — the store holds data rows only.
// Issue #189 — a pass reports what it ACTUALLY changed (released rows, visible
// refusal transitions, per-type Health uploads), never how much work is left:
// a successful drain EMPTIES the queue and must still reconcile, while a pass
// that changed nothing must not. The owner's hook is awaited before the pass
// completes, and a pass that ended before the hook existed is delivered on
// installation (the startup order loses nothing).
protocol RemoteMealWriting {
    /// Uploads (idempotently) or reuses the deterministic photo object for a
    /// queued meal; returns the storage bucket path.
    func uploadMealPhoto(userID: UUID, mealID: UUID, photo: QueuedMealPhoto) async throws -> String

    /// Commits the meal through the authenticated security-invoker RPC with
    /// the client id as the server primary key; reads back the authoritative
    /// server result. Throws MealDeliveryError for classification.
    func commitMeal(userID: UUID, meal: QueuedMeal, imagePath: String?) async throws

    /// Best-effort cleanup of a just-uploaded object after a permanent
    /// refusal (no orphaned photo on a rejected meal).
    func removeRemotePhoto(userID: UUID, bucketPath: String) async throws
}

/// Delivery outcome classification (raw system text never reaches the UI).
enum MealDeliveryError: LocalizedError {
    case permanent(OutboxErrorCategory)
    case transient(OutboxErrorCategory)

    var errorDescription: String? {
        switch self {
        case let .permanent(category), let .transient(category):
            return category.friendlyDescription
        }
    }
}

/// Issue #189 — what ONE pass ACTUALLY changed, kept separate from the queue
/// depth the old `storeHasQueuedOrDirtyWork()` reported: a successful final
/// drain empties the queue (depth "no change") and still must reconcile, and a
/// row that fails again the same way leaves it non-empty without moving
/// anything visible. Only identities and counts travel — never payloads.
struct SyncPassChange: Equatable {
    /// Meals the server accepted and the local row released.
    private(set) var releasedMealIDs: [UUID] = []
    /// Rows whose journal-visible refusal state changed in this pass.
    private(set) var refusalChangedMealIDs: [UUID] = []
    /// Rows of each Health type that uploaded in this pass (0 = none).
    private(set) var syncedWeightCount = 0
    private(set) var syncedEnergyCount = 0

    /// The journal's merged day needs one authoritative re-read.
    var changesJournal: Bool { !releasedMealIDs.isEmpty || !refusalChangedMealIDs.isEmpty }
    /// The calm Health status must re-derive its per-type kinds.
    var changesHealthStatus: Bool { syncedWeightCount > 0 || syncedEnergyCount > 0 }
    var isEmpty: Bool { !changesJournal && !changesHealthStatus }

    /// The server accepted this row and the durable outbox released it.
    mutating func released(mealID: UUID) { releasedMealIDs.append(mealID) }

    /// A refusal whose journal-visible identity actually moved.
    mutating func refusalChanged(mealID: UUID) { refusalChangedMealIDs.append(mealID) }

    /// The per-type Health rows THIS pass uploaded.
    mutating func synced(weightCount: Int, energyCount: Int) {
        syncedWeightCount = weightCount
        syncedEnergyCount = energyCount
    }

    mutating func merge(_ other: SyncPassChange) {
        releasedMealIDs += other.releasedMealIDs
        refusalChangedMealIDs += other.refusalChangedMealIDs
        syncedWeightCount += other.syncedWeightCount
        syncedEnergyCount += other.syncedEnergyCount
    }
}

/// Issue #189 — the journal-visible refusal identity of one outbox row: a
/// still-retrying pending row has no refusal to render; a needs-attention row
/// renders the category that caused it. Two passes that leave the SAME
/// identity changed nothing the journal can see (no reload storm).
struct MealRefusal: Equatable {
    let needsAttention: Bool
    let category: OutboxErrorCategory?

    init(_ row: QueuedMeal?) {
        needsAttention = row?.state == .needsAttention
        category = needsAttention ? row?.lastErrorCategory : nil
    }
}

final class LocalSyncEngine {
    private let userID: UUID
    private let mealRemote: RemoteMealWriting?
    private let store: LocalDataStore
    private let healthStore: LocalHealthStore?
    private let healthRemote: WeightLogStore?
    private let now: () -> Date
    private let healthUploader: HealthRemoteUploading?
    /// Issue #189 — the owner's reconciliation hook, awaited on the main actor
    /// BEFORE a pass completes (the owner converges with the authoritative
    /// result instead of racing it); install it before work starts. A pass
    /// that already finished is delivered on installation.
    private var onSyncChanged: (@MainActor (SyncPassChange) async -> Void)?
    /// A change that finished before a hook existed (startup order), buffered
    /// as ONE merged value and delivered exactly once.
    private var pendingChange: SyncPassChange?

    private var passRunning = false
    private var rerunRequested = false
    private var workTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "morsel.sync-engine")

    init(
        userID: UUID,
        store: LocalDataStore,
        healthStore: LocalHealthStore? = nil,
        mealRemote: RemoteMealWriting? = nil,
        healthRemote: WeightLogStore? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.userID = userID
        self.store = store
        self.healthStore = healthStore
        self.mealRemote = mealRemote
        self.healthRemote = healthRemote
        self.now = now
        healthUploader = healthRemote.map { adapter in
            RemoteHealthUploader(remote: adapter)
        }
    }

    /// Cancels this account's worker (logout / account switch / dealloc).
    func shutdown() {
        queue.sync {
            workTask?.cancel()
            workTask = nil
            passRunning = false
            pendingChange = nil
            onSyncChanged = nil
        }
    }

    /// Installs the owner's hook and delivers a change that finished before
    /// installation (issue #189: an immediate startup drain cannot beat it).
    func startReconciling(_ handler: @escaping @MainActor (SyncPassChange) async -> Void) async {
        let buffered: SyncPassChange? = queue.sync {
            onSyncChanged = handler
            defer { pendingChange = nil }
            return pendingChange
        }
        if let buffered { await handler(buffered) }
    }

    /// Requests a pass. Safe to call from any thread; never overlaps.
    func syncNow() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.passRunning {
                self.rerunRequested = true
                return
            }
            self.passRunning = true
            self.workTask = Task { [weak self] in
                guard let self else { return }
                await self.runPass()
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.passRunning = false
                    if self.rerunRequested {
                        self.rerunRequested = false
                        self.syncNow()
                    }
                }
            }
        }
    }

    /// Deterministic single pass (tests drive this directly). Reconciliation is
    /// awaited here, so no pass completes before its owner knows what changed.
    func runPass() async {
        var change = await deliverMeals(attemptNeedsAttentionAuth: true)
        change.merge(await deliverHealth())
        await deliver(change)
    }

    /// Hands ONE bounded change to the owner (awaited on the main actor), or
    /// buffers it until a hook is installed. An empty change is never an event.
    private func deliver(_ change: SyncPassChange) async {
        guard !change.isEmpty else { return }
        let handler: (@MainActor (SyncPassChange) async -> Void)? = queue.sync {
            guard let installed = onSyncChanged else {
                var buffered = pendingChange ?? SyncPassChange()
                buffered.merge(change)
                pendingChange = buffered
                return nil
            }
            return installed
        }
        if let handler { await handler(change) }
    }

    // MARK: - Meal outbox

    private func deliverMeals(attemptNeedsAttentionAuth: Bool) async -> SyncPassChange {
        var change = SyncPassChange()
        guard let mealRemote else { return change }
        let rows: [QueuedMeal]
        do {
            rows = try store.queuedMeals().filter { row in
                row.state == .pending
                    || (row.state == .needsAttention
                        && attemptNeedsAttentionAuth && row.lastErrorCategory == .auth)
            }
        } catch {
            return change
        }
        var remainingTransient = 0
        for row in rows where !Task.isCancelled {
            let refusal = MealRefusal(try? store.queuedMeal(mealID: row.mealID))
            do {
                try await deliverOne(row, remote: mealRemote)
                try store.removeMeal(mealID: row.mealID)
                change.released(mealID: row.mealID)
            } catch is CancellationError {
                return change
            } catch let error as MealDeliveryError {
                if case let .permanent(category) = error {
                    // Preserve recoverable data; visible `needs attention`.
                    // EVERY permanent refusal (auth/validation/photo/server)
                    // leaves the green-pending purgatory (issue #135).
                    try? store.recordMealAttempt(
                        mealID: row.mealID, error: category, permanent: true, now: now()
                    )
                } else {
                    try? store.recordMealAttempt(
                        mealID: row.mealID,
                        error: transientCategory(of: error), now: now()
                    )
                    remainingTransient += 1
                }
                noteRefusalChange(mealID: row.mealID, from: refusal, into: &change)
            } catch {
                try? store.recordMealAttempt(
                    mealID: row.mealID, error: .network, now: now()
                )
                remainingTransient += 1
                noteRefusalChange(mealID: row.mealID, from: refusal, into: &change)
            }
        }
        scheduleRetryIfNeeded(transientCount: remainingTransient)
        return change
    }

    /// Issue #189 — a refusal only counts as a change when the row's
    /// journal-visible identity moved: failing the same way again is not news
    /// (no reload storm), and it is never a delivery success either.
    private func noteRefusalChange(
        mealID: UUID, from refusal: MealRefusal, into change: inout SyncPassChange
    ) {
        guard MealRefusal(try? store.queuedMeal(mealID: mealID)) != refusal else { return }
        change.refusalChanged(mealID: mealID)
    }

    private func deliverOne(_ row: QueuedMeal, remote: RemoteMealWriting) async throws {
        var imagePath = row.imagePath
        // Normalize a legacy bucket-qualified path (app builds before #135)
        // to the canonical object path the server contract stores.
        if let stored = imagePath,
           let canonical = try? FoodImageStore.validate(bucketPath: stored, for: userID),
           canonical != stored {
            imagePath = canonical
            try? store.updateMealImagePath(mealID: row.mealID, path: canonical)
        }
        if row.photo != nil, imagePath == nil {
            guard let photo = row.photo else { return }
            let path: String
            do {
                path = try await remote.uploadMealPhoto(
                    userID: userID, mealID: row.mealID, photo: photo
                )
            } catch let error as MealDeliveryError {
                throw error
            } catch {
                // Issue #135 — an upload refusal must be classified like an
                // RPC refusal: auth/photo/validation denials are permanent
                // and surface as needs-attention; only real transport
                // failures stay retryable. The old catch-all silently kept
                // photo meals green-pending forever.
                throw classifyRemoteMealError(error)
            }
            try store.updateMealImagePath(mealID: row.mealID, path: path)
            imagePath = path
        }
        do {
            try await remote.commitMeal(userID: userID, meal: row, imagePath: imagePath)
        } catch let error as MealDeliveryError {
            if case let .permanent(category) = error,
               let path = imagePath {
                // Never leave an orphaned photo behind a rejected meal.
                try? await remote.removeRemotePhoto(userID: userID, bucketPath: path)
                try? store.updateMealImagePath(mealID: row.mealID, path: nil)
            }
            throw error
        }
    }

    private func transientCategory(of error: MealDeliveryError) -> OutboxErrorCategory {
        if case let .transient(category) = error {
            return category
        }
        return .server
    }

    private func scheduleRetryIfNeeded(transientCount: Int) {
        guard transientCount > 0 else { return }
        let base: TimeInterval = 15
        let cap: TimeInterval = 900
        let delay = min(base * pow(2, Double(min(transientCount, 5))), cap)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.syncNow()
        }
    }

    // MARK: - Health rows (bodyMass + activeEnergyBurned only)

    private func deliverHealth() async -> SyncPassChange {
        var change = SyncPassChange()
        guard let healthStore, let healthUploader else { return change }
        let unsynced: [WeightLog]
        let dirtyDays: [EnergyBurnedLog]
        do {
            unsynced = try healthStore.unsyncedWeightSamples()
            dirtyDays = try healthStore.dirtyEnergyDays()
        } catch {
            return change
        }
        guard !unsynced.isEmpty || !dirtyDays.isEmpty else { return change }
        do {
            try await healthUploader.upsert(unsynced)
            try await healthUploader.upsertEnergyBurned(dirtyDays)
            for sample in unsynced {
                try? healthStore.markWeightSynced(measuredAt: sample.measuredAt)
            }
            for day in dirtyDays {
                try? healthStore.markEnergyDaySynced(day: day.burnedAt)
            }
            // Issue #112 — the calm status names ONLY the types that actually
            // uploaded ≥1 row in this pass: each per-type mark shares the
            // pass stamp, and a type with zero rows gets no mark at all (an
            // energy-only drain must never read as a weight sync).
            let stamp = now()
            var uploadedWeightCount = 0
            var uploadedEnergyCount = 0
            try? healthStore.setLastSuccessfulUpload(stamp)
            if !unsynced.isEmpty {
                try? healthStore.setLastWeightUpload(stamp)
                uploadedWeightCount = unsynced.count
            }
            if !dirtyDays.isEmpty {
                try? healthStore.setLastEnergyUpload(stamp)
                uploadedEnergyCount = dirtyDays.count
            }
            change.synced(weightCount: uploadedWeightCount, energyCount: uploadedEnergyCount)
        } catch {
            // Rows stay dirty — next pass retries the same idempotent upserts.
            // Nothing was uploaded: no event, and never a fake sync success.
        }
        return change
    }
}

// MARK: - Health remote adapter

protocol HealthRemoteUploading {
    func upsert(_ logs: [WeightLog]) async throws
    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws
}

private struct RemoteHealthUploader: HealthRemoteUploading {
    let remote: WeightLogStore

    func upsert(_ logs: [WeightLog]) async throws {
        try await remote.upsert(logs)
    }

    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws {
        try await remote.upsertEnergyBurned(logs)
    }
}

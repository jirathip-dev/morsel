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

final class LocalSyncEngine {
    private let userID: UUID
    private let mealRemote: RemoteMealWriting?
    private let store: LocalDataStore
    private let healthStore: LocalHealthStore?
    private let healthRemote: WeightLogStore?
    private let now: () -> Date
    private let healthUploader: HealthRemoteUploading?
    /// Called (on the main actor) after a pass changed sync state, so the
    /// journal can converge with the authoritative server result.
    var onSyncCompleted: (() -> Void)?

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
        }
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

    /// Deterministic single pass (tests drive this directly).
    func runPass() async {
        await deliverMeals(attemptNeedsAttentionAuth: true)
        await deliverHealth()
        let changed = storeHasQueuedOrDirtyWork()
        if changed {
            await MainActor.run { onSyncCompleted?() }
        }
    }

    // MARK: - Meal outbox

    private func deliverMeals(attemptNeedsAttentionAuth: Bool) async {
        guard let mealRemote else { return }
        let rows: [QueuedMeal]
        do {
            rows = try store.queuedMeals().filter { row in
                row.state == .pending
                    || (row.state == .needsAttention
                        && attemptNeedsAttentionAuth && row.lastErrorCategory == .auth)
            }
        } catch {
            return
        }
        var remainingTransient = 0
        for row in rows where !Task.isCancelled {
            do {
                try await deliverOne(row, remote: mealRemote)
                try store.removeMeal(mealID: row.mealID)
            } catch is CancellationError {
                return
            } catch let error as MealDeliveryError {
                if case let .permanent(category) = error {
                    // Preserve recoverable data; visible `needs attention`.
                    try? store.recordMealAttempt(
                        mealID: row.mealID, error: category, now: now()
                    )
                } else {
                    try? store.recordMealAttempt(
                        mealID: row.mealID,
                        error: transientCategory(of: error), now: now()
                    )
                    remainingTransient += 1
                }
            } catch {
                try? store.recordMealAttempt(
                    mealID: row.mealID, error: .network, now: now()
                )
                remainingTransient += 1
            }
        }
        scheduleRetryIfNeeded(transientCount: remainingTransient)
    }

    private func deliverOne(_ row: QueuedMeal, remote: RemoteMealWriting) async throws {
        var imagePath = row.imagePath
        if row.photo != nil, imagePath == nil {
            guard let photo = row.photo else { return }
            let path = try await remote.uploadMealPhoto(
                userID: userID, mealID: row.mealID, photo: photo
            )
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

    private func deliverHealth() async {
        guard let healthStore, let healthUploader else { return }
        let unsynced: [WeightLog]
        let dirtyDays: [EnergyBurnedLog]
        do {
            unsynced = try healthStore.unsyncedWeightSamples()
            dirtyDays = try healthStore.dirtyEnergyDays()
        } catch {
            return
        }
        guard !unsynced.isEmpty || !dirtyDays.isEmpty else { return }
        do {
            try await healthUploader.upsert(unsynced)
            try await healthUploader.upsertEnergyBurned(dirtyDays)
            var uploadedWeight = false
            for sample in unsynced {
                try? healthStore.markWeightSynced(measuredAt: sample.measuredAt)
                uploadedWeight = true
            }
            var uploadedEnergy = false
            for day in dirtyDays {
                try? healthStore.markEnergyDaySynced(day: day.burnedAt)
                uploadedEnergy = true
            }
            // Issue #112 — the calm status names ONLY the types that actually
            // uploaded ≥1 row in this pass: each per-type mark shares the
            // pass stamp, and a type with zero rows gets no mark at all (an
            // energy-only drain must never read as a weight sync).
            let stamp = now()
            try? healthStore.setLastSuccessfulUpload(stamp)
            if uploadedWeight { try? healthStore.setLastWeightUpload(stamp) }
            if uploadedEnergy { try? healthStore.setLastEnergyUpload(stamp) }
        } catch {
            // Rows stay dirty — next pass retries the same idempotent upserts.
        }
    }

    private func storeHasQueuedOrDirtyWork() -> Bool {
        let hasMeals = (try? store.queuedMeals().isEmpty) == false
        let hasHealth: Bool = {
            guard let healthStore else { return false }
            let hasWeights = (try? healthStore.unsyncedWeightSamples().isEmpty) == false
            let hasDays = (try? healthStore.dirtyEnergyDays().isEmpty) == false
            return hasWeights || hasDays
        }()
        return hasMeals || hasHealth
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

import Combine
import Foundation

struct MealGroup: Identifiable, Equatable {
    let type: MealType
    let meals: [MealRecord]

    var id: MealType { type }

    var totalCalories: Double {
        DashboardMath.totals(for: meals).caloriesKcal
    }

    var firstMealTime: Date? {
        meals.first?.eatenAt
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var snapshot: DashboardSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var weightImportError: String?
    @Published private(set) var healthStatus: HealthCalmStatus = .unknown

    let repository: any DashboardRepository
    let userID: UUID
    private let weightImporter: HealthKitWeightImporter?
    private let healthStore: LocalHealthStore?
    private let syncEngine: LocalSyncEngine?
    private let dateProvider: () -> Date
    private var reloadAfterLoad = false
    private var observersStarted = false

    init(
        repository: any DashboardRepository,
        userID: UUID,
        weightImporter: HealthKitWeightImporter? = nil,
        healthStore: LocalHealthStore? = nil,
        syncEngine: LocalSyncEngine? = nil,
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.userID = userID
        self.weightImporter = weightImporter
        self.healthStore = healthStore
        self.syncEngine = syncEngine
        self.dateProvider = dateProvider
    }

    var totals: DashboardTotals {
        DashboardMath.totals(for: snapshot?.meals ?? [])
    }

    /// Issue #113 amendment C — the SAME #112 calm-status stamp that feeds
    /// `healthStatus` drives the margin note's time (never a second clock).
    /// Nil when no Apple Health upload has ever succeeded locally.
    var lastHealthImportDate: Date? {
        guard let healthStore else { return nil }
        return try? healthStore.lastSuccessfulUpload()
    }

    var mealGroups: [MealGroup] {
        guard let meals = snapshot?.meals else {
            return []
        }
        return MealType.allCases.compactMap { type in
            let matchingMeals = meals.filter { $0.mealType == type }
            return matchingMeals.isEmpty ? nil : MealGroup(type: type, meals: matchingMeals)
        }
    }

    var reviewItems: [MealItem] {
        snapshot?.meals
            .flatMap(\.items)
            .filter(\.needsReview) ?? []
    }

    /// User-invokable Health retry/reconnect (Settings): re-request
    /// authorization, re-import BOTH types independently, and queue the
    /// durable upload pass.
    func retryHealthSync() async {
        healthStatus = .syncing
        await importWeights(registerObservers: true)
    }

    /// Imports body mass and active energy INDEPENDENTLY (one type's
    /// denial/query failure never suppresses the other), registers both
    /// observers immediately (independent of any remote result), and queues
    /// the durable background upload of locally stored rows.
    func importWeights(registerObservers: Bool = true) async {
        guard let weightImporter else { return }
        if registerObservers, !observersStarted {
            observersStarted = true
            weightImporter.startObserving(
                onSuccess: { [weak self] in
                    Task { @MainActor in
                        self?.syncEngine?.syncNow()
                        await self?.load()
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        await self?.handleObserverImportError(error)
                    }
                }
            )
        }
        var bodyFailed = false
        var energyFailed = false
        var bodyImported = 0
        var energyImported = 0
        do {
            bodyImported = try await importBodyMassPass()
        } catch is CancellationError {
            return
        } catch {
            bodyFailed = true
            surfaceHealthError(error)
        }
        do {
            energyImported = try await importEnergyPass()
        } catch is CancellationError {
            return
        } catch {
            energyFailed = true
            surfaceHealthError(error)
        }
        await updateCalmStatus(
            bodyMassFailed: bodyFailed, energyFailed: energyFailed,
            bodyImported: bodyImported, energyImported: energyImported
        )
        syncEngine?.syncNow()
    }

    func load() async {
        if isLoading {
            reloadAfterLoad = true
            return
        }
        // Local-first paint: show the last cached snapshot immediately, then
        // converge with the authoritative remote state in the background.
        if snapshot == nil,
           let cached = try? await repository.cachedToday(userID: userID, date: dateProvider()) {
            snapshot = cached
        }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            if reloadAfterLoad {
                reloadAfterLoad = false
                Task { await load() }
            }
        }
        do {
            snapshot = try await repository.loadToday(
                userID: userID,
                date: dateProvider()
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
        }
    }

    /// Saves a meal. At the final head the repository durably commits the
    /// meal (meal + items + photo in one local transaction) BEFORE returning,
    /// so this succeeds without waiting for a second full remote loadToday —
    /// the Add-Meal page closes and the journal shows the row with an honest
    /// `pending sync` marker until the authoritative server result is read
    /// back and reconciled.
    func addMeal(draft: MealDraft, photo: FoodImageUpload?) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let mealID = try await repository.logMeal(userID: userID, draft: draft, photo: photo)
            await showQueuedMealIfNeeded(localMealID: mealID)
            syncEngine?.syncNow()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
            return false
        }
    }

    /// Optimistic journal row for a locally committed (queued) meal — the UI
    /// must not wait for a reload to show what the user just saved.
    private func showQueuedMealIfNeeded(localMealID: UUID) async {
        guard let record = try? await repository.localMealRecord(
            userID: userID, localMealID: localMealID
        ) else {
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: dateProvider())
        if let snapshot,
           calendar.startOfDay(for: record.eatenAt) == today,
           !snapshot.meals.contains(where: { $0.mealLogID == record.mealLogID }) {
            var meals = snapshot.meals
            meals.append(record)
            meals.sort { $0.eatenAt < $1.eatenAt }
            self.snapshot = DashboardSnapshot(
                date: snapshot.date,
                meals: meals,
                goal: snapshot.goal,
                weightTrend: snapshot.weightTrend,
                activeEnergyBurned: snapshot.activeEnergyBurned
            )
        } else if snapshot == nil, calendar.startOfDay(for: record.eatenAt) == today {
            self.snapshot = DashboardSnapshot(date: today, meals: [record], goal: nil)
        }
    }

    func markReviewed(_ itemID: UUID) async -> Bool {
        do {
            try await repository.confirmMealItem(userID: userID, itemID: itemID)
            snapshot = try await repository.loadToday(userID: userID, date: dateProvider())
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
            return false
        }
    }

    func updateMealItem(_ update: MealItemUpdate) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await repository.updateMealItem(userID: userID, update: update)
            snapshot = try await repository.loadToday(userID: userID, date: dateProvider())
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
            return false
        }
    }

    func deleteMeal(_ mealLogID: UUID) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await repository.deleteMealLog(userID: userID, mealLogID: mealLogID)
            snapshot = try await repository.loadToday(userID: userID, date: dateProvider())
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
            return false
        }
    }
}

// MARK: - Health pass helpers (issue #112 truthful per-type status)

extension DashboardViewModel {
    /// One independent body-mass pass (anchor-bounded re-import); returns
    /// the number of samples durably stored. Throws so the caller can keep
    /// the two types' cancellation semantics independent.
    private func importBodyMassPass() async throws -> Int {
        guard let weightImporter else { return 0 }
        let anchor = try? healthStore?.bodyMassAnchor()
        let stored = try await weightImporter.importBodyMass(since: anchor)
        if let latest = stored.map(\.measuredAt).max(), latest > (anchor ?? .distantPast) {
            try? healthStore?.setBodyMassAnchor(latest)
        }
        return stored.count
    }

    /// One independent active-energy pass; returns the number of daily rows
    /// durably stored.
    private func importEnergyPass() async throws -> Int {
        guard let weightImporter else { return 0 }
        let anchor = try? healthStore?.energyAnchor()
        let stored = try await weightImporter.importActiveEnergy(since: anchor)
        if let latest = stored.map(\.burnedAt).max(), latest > (anchor ?? .distantPast) {
            try? healthStore?.setEnergyAnchor(latest)
        }
        return stored.count
    }

    /// Observer callback failure: map through the human copy table and
    /// re-derive the calm status as if both imports failed with zero rows.
    private func handleObserverImportError(_ error: Error) async {
        weightImportError = HealthSyncUserMessage.userMessage(for: error)
        await updateCalmStatus(
            bodyMassFailed: true, energyFailed: true,
            bodyImported: 0, energyImported: 0
        )
    }

    /// Maps an import failure through the human copy table (never raw text).
    private func surfaceHealthError(_ error: Error) {
        weightImportError = HealthSyncUserMessage.userMessage(for: error)
    }

    /// Calm status derivation (issue #112 — truthful per type). Read-side
    /// truth comes from the typed reader seam (getRequestStatusForAuthorization
    /// — never share status, which stays false for the toShare: [] request):
    /// a still-pending read prompt means the app cannot make ANY claim for
    /// that type, so the status is `permissionRequired` — never a green
    /// "synced". `synced` names only kinds whose per-type upload mark matches
    /// the last successful pass stamp; a decided read with zero body-mass
    /// rows anywhere is the calm `noWeightData` state.
    private func updateCalmStatus(
        bodyMassFailed: Bool, energyFailed: Bool,
        bodyImported: Int, energyImported: Int
    ) async {
        guard let weightImporter else {
            healthStatus = .unavailable
            return
        }
        let bodyReadDecided = weightImporter.authorizationStatus(for: .bodyMass)
        let energyReadDecided = weightImporter.authorizationStatus(for: .activeEnergyBurned)

        if (bodyMassFailed && !bodyReadDecided)
            || (energyFailed && !energyReadDecided)
            || (!bodyMassFailed && !bodyReadDecided && bodyImported == 0) {
            healthStatus = .permissionRequired
            return
        }
        if let lastUpload = try? healthStore?.lastSuccessfulUpload() {
            let kinds = syncedKinds(matching: lastUpload)
            if !kinds.isEmpty {
                healthStatus = .synced(lastUpload, syncedKinds: kinds)
                return
            }
        }
        let hasPending = (try? healthStore?.hasPendingUploads()) ?? false
        if hasPending {
            healthStatus = .pending
            return
        }
        let hasWeightRows = (try? healthStore?.hasWeightSamples()) == true
        let weightEverUploaded = (try? healthStore?.lastWeightUpload()) != nil
        if bodyReadDecided, bodyImported == 0, !hasWeightRows, !weightEverUploaded {
            healthStatus = .noWeightData
            return
        }
        healthStatus = .unknown
    }

    /// Kinds that uploaded ≥1 row in the pass stamped `stamp`. The sync
    /// engine writes each per-type mark with the SAME time as the last
    /// successful upload, so equality identifies the pass (issue #112).
    private func syncedKinds(matching stamp: Date) -> Set<HealthSyncedKind> {
        var kinds = Set<HealthSyncedKind>()
        if (try? healthStore?.lastWeightUpload()) == stamp { kinds.insert(.bodyMass) }
        if (try? healthStore?.lastEnergyUpload()) == stamp { kinds.insert(.activeEnergy) }
        return kinds
    }

    /// Re-derives the calm status after a sync pass (rows drained → synced
    /// with the last upload time + uploaded kinds; otherwise pending).
    func refreshHealthCalmStatus() async {
        await updateCalmStatus(
            bodyMassFailed: false, energyFailed: false,
            bodyImported: 0, energyImported: 0
        )
    }
}

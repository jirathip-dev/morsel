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
    /// Issue #258 — the last successful fresh day load, and whether the cached
    /// copy is what the screen is showing (see the #258 notices in TodayLogViews).
    @Published private(set) var lastLoadedAt: Date?
    @Published private(set) var isShowingCachedDay = false

    let repository: any DashboardRepository
    let userID: UUID
    private let weightImporter: HealthKitWeightImporter?
    private let healthStore: LocalHealthStore?
    private let syncEngine: LocalSyncEngine?
    private let dateProvider: () -> Date
    private var reloadAfterLoad = false
    private var observersStarted = false
    @Published private var diaryDate: Date?
    private var loadGeneration = 0
    private var loadingDate: Date?

    var selectedDate: Date { DashboardMath.startOfLocalDay(diaryDate ?? dateProvider()) }
    var today: Date { DashboardMath.startOfLocalDay(dateProvider()) }

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

    var totals: DashboardTotals { DashboardMath.totals(for: snapshot?.meals ?? []) }

    /// The same Health status stamp drives the margin note (nil before first upload).
    var lastHealthImportDate: Date? {
        guard let healthStore else { return nil }
        return try? healthStore.lastSuccessfulUpload()
    }

    var mealGroups: [MealGroup] {
        guard let meals = snapshot?.meals else { return [] }
        return MealType.allCases.compactMap { type in
            let matchingMeals = meals.filter { $0.mealType == type }
            return matchingMeals.isEmpty ? nil : MealGroup(type: type, meals: matchingMeals)
        }
    }

    var reviewItems: [MealItem] { snapshot?.meals.flatMap(\.items).filter(\.needsReview) ?? [] }

    /// Reconnect both Health types independently, then queue the upload pass.
    func retryHealthSync() async {
        healthStatus = .syncing
        await importWeights(registerObservers: true)
    }

    /// Import each Health type independently and register both observers.
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
        let date = selectedDate
        if isLoading, loadingDate == date {
            reloadAfterLoad = true
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        loadingDate = date
        isLoading = true
        errorMessage = nil
        if snapshot?.date != date { snapshot = nil }
        defer {
            if generation == loadGeneration {
                isLoading = false
                loadingDate = nil
                if reloadAfterLoad {
                    reloadAfterLoad = false
                    Task { await load() }
                }
            }
        }
        if snapshot == nil, let cached = try? await repository.cachedToday(userID: userID, date: date) {
            guard generation == loadGeneration, date == selectedDate else { return }
            snapshot = cached
        }
        do {
            let loaded = try await repository.loadToday(userID: userID, date: date)
            guard generation == loadGeneration, date == selectedDate else { return }
            snapshot = loaded
            lastLoadedAt = dateProvider()
            isShowingCachedDay = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, date == selectedDate else { return }
            // Issue #258 — a failed refresh keeps the cached day on screen but
            // never as current: cached label, last load time, retry.
            isShowingCachedDay = snapshot != nil
            errorMessage = DashboardUserMessage.userMessage(for: error)
        }
    }

    private func refreshSelectedDay() async throws {
        let date = selectedDate
        let generation = loadGeneration
        let loaded = try await repository.loadToday(userID: userID, date: date)
        guard date == selectedDate, generation == loadGeneration else { return }
        snapshot = loaded
    }

    /// Commits locally before closing; queued rows retain their pending marker.
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

    /// Paint the locally committed row without waiting for a remote read.
    private func showQueuedMealIfNeeded(localMealID: UUID) async {
        guard let record = try? await repository.localMealRecord(
            userID: userID, localMealID: localMealID
        ) else {
            try? await refreshSelectedDay()
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let today = selectedDate
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
            try await refreshSelectedDay()
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
            try await refreshSelectedDay()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
            return false
        }
    }

    func attachPhoto(_ photo: FoodImageUpload, toItem itemID: UUID) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await repository.attachMealPhoto(userID: userID, itemID: itemID, photo: photo)
            syncEngine?.syncNow()
            try await refreshSelectedDay()
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
            try await refreshSelectedDay()
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
    func selectDate(_ date: Date) {
        let day = DashboardMath.startOfLocalDay(date)
        guard day != selectedDate, day <= today else { return }
        diaryDate = day == today ? nil : day
        loadGeneration &+= 1
        snapshot = nil
        errorMessage = nil
        isLoading = false
        loadingDate = nil
        reloadAfterLoad = false
        lastLoadedAt = nil
        isShowingCachedDay = false
    }

    /// Anchor-bounded body-mass import, independently throwing.
    private func importBodyMassPass() async throws -> Int {
        guard let weightImporter else { return 0 }
        let anchor = try? healthStore?.bodyMassAnchor()
        let stored = try await weightImporter.importBodyMass(since: anchor)
        if let latest = stored.map(\.measuredAt).max(), latest > (anchor ?? .distantPast) {
            try? healthStore?.setBodyMassAnchor(latest)
        }
        return stored.count
    }

    /// One independent active-energy pass; returns the daily rows stored.
    private func importEnergyPass() async throws -> Int {
        guard let weightImporter else { return 0 }
        let anchor = try? healthStore?.energyAnchor()
        let stored = try await weightImporter.importActiveEnergy(since: anchor)
        if let latest = stored.map(\.burnedAt).max(), latest > (anchor ?? .distantPast) {
            try? healthStore?.setEnergyAnchor(latest)
        }
        return stored.count
    }

    /// Observer failure: human copy, then derive status with zero imported rows.
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

    /// #112/#173: await per-type read decisions; only matching stamps name synced kinds.
    private func updateCalmStatus(
        bodyMassFailed: Bool, energyFailed: Bool,
        bodyImported: Int, energyImported: Int
    ) async {
        guard let weightImporter else {
            healthStatus = .unavailable
            return
        }
        let bodyReadDecided = await weightImporter.authorizationStatus(for: .bodyMass)
        let energyReadDecided = await weightImporter.authorizationStatus(for: .activeEnergyBurned)

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

    /// Matching per-type upload stamps identify the successful pass (#112).
    private func syncedKinds(matching stamp: Date) -> Set<HealthSyncedKind> {
        var kinds = Set<HealthSyncedKind>()
        if (try? healthStore?.lastWeightUpload()) == stamp { kinds.insert(.bodyMass) }
        if (try? healthStore?.lastEnergyUpload()) == stamp { kinds.insert(.activeEnergy) }
        return kinds
    }

    /// Re-derives the calm status after a sync pass (drained → synced).
    func refreshHealthCalmStatus() async {
        await updateCalmStatus(
            bodyMassFailed: false, energyFailed: false,
            bodyImported: 0, energyImported: 0
        )
    }
}

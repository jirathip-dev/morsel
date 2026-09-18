import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var snapshot: DashboardSnapshot? {
        didSet { if snapshot?.meals != oldValue?.meals { derivedRevision &+= 1 } }
    }
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
    /// Issue #190 — one write per acknowledged record: a repeated tap joins it.
    /// Internal (like `LocalFirstDashboardRepository`'s cross-file seams) so the
    /// confirmation extension in `WriteAcknowledgement.swift` can reach it.
    var writesInFlight: [String: Task<Void, Error>] = [:]
    private lazy var refreshOwner = TodayRefreshOwner(repository: repository, userID: userID)
    private var observersStarted = false
    @Published private var diaryDate: Date?

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

    var totals: DashboardTotals { derived().totals }

    /// The same Health status stamp drives the margin note (nil before first upload).
    var lastHealthImportDate: Date? {
        guard let healthStore else { return nil }
        return try? healthStore.lastSuccessfulUpload()
    }

    var mealGroups: [MealGroup] { derived().groups }

    var reviewItems: [MealItem] { derived().review }

    /// Issue #195 — one derived scan per day-data revision: loading, status and
    /// turn updates that leave the day's meals unchanged reuse the totals,
    /// groupings and review items instead of rescanning every meal item.
    private var derivedRevision = 0
    private var derivedCache: (revision: Int, value: DayDerived)?
    /// Full derived scans; the reuse regression reads this counter.
    private(set) var derivedScanCount = 0

    /// Reconnect both Health types independently, then queue the upload pass.
    func retryHealthSync() async {
        healthStatus = .syncing; await importWeights(registerObservers: true)
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
                        await self?.invalidateDay()
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        await self?.handleObserverImportError(error)
                    }
                }
            )
        }
        var bodyFailed = false, energyFailed = false
        var bodyImported = 0, energyImported = 0
        do {
            bodyImported = try await importBodyMassPass()
        } catch is CancellationError {
            return
        } catch {
            bodyFailed = true; surfaceHealthError(error)
        }
        do {
            energyImported = try await importEnergyPass()
        } catch is CancellationError {
            return
        } catch {
            energyFailed = true; surfaceHealthError(error)
        }
        await updateCalmStatus(
            bodyMassFailed: bodyFailed, energyFailed: energyFailed,
            bodyImported: bodyImported, energyImported: energyImported
        )
        syncEngine?.syncNow()
        if bodyImported > 0 || energyImported > 0 { await invalidateDay() }
    }

    func load(superseding: Bool = false) async {
        guard !Task.isCancelled else { return }
        await refreshOwner.wait(for: startRefresh(superseding: superseding))
    }

    func invalidateDay() async { await refreshOwner.wait(for: startRefresh(invalidating: true)) }

    func cancelRefresh() { refreshOwner.cancel(); isLoading = false }

    private func startRefresh(invalidating: Bool = false, superseding: Bool = false,
                              keepsAlive: Bool = false) -> TodayRefreshOwner.Flight {
        let date = selectedDate
        if snapshot?.date != date { snapshot = nil }
        let flight = refreshOwner.start(date: date, needsCache: snapshot == nil,
                                        invalidating: invalidating, superseding: superseding,
                                        keepsAlive: keepsAlive) { [weak self] event in
            guard let self else { return }
            if case .finished = event { self.isLoading = false; return }
            guard date == self.selectedDate else { return }
            switch event {
            case .cached(let cached): self.snapshot = cached.cachedCopy
            case .loaded(let loaded): self.publishDay(loaded)
            case .failed(let error):
                // Issue #303 — the refresh concluded unsuccessfully: this is
                // the announced cached state, not a silent first paint.
                self.snapshot = self.snapshot?.failedRefreshCopy
                self.errorMessage = DashboardUserMessage.userMessage(for: error)
            case .finished: break
            }
        }
        isLoading = true
        errorMessage = nil
        return flight
    }

    /// Commits locally before closing; queued rows retain their pending marker.
    func addMeal(draft: MealDraft, photo: FoodImageUpload?) async -> Bool {
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            let mealID = try await repository.logMeal(userID: userID, draft: draft, photo: photo)
            _ = startRefresh(invalidating: true, keepsAlive: true)
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
        let date = selectedDate
        guard let record = try? await repository.localMealRecord(
            userID: userID, localMealID: localMealID
        ), date == selectedDate else { return }
        let calendar = Calendar.autoupdatingCurrent
        let today = selectedDate
        if let snapshot,
           calendar.startOfDay(for: record.eatenAt) == today,
           !snapshot.meals.contains(where: { $0.mealLogID == record.mealLogID }) {
            var meals = snapshot.meals
            meals.append(record)
            meals.sort { $0.eatenAt < $1.eatenAt }
            self.snapshot = DashboardSnapshot(
                date: snapshot.date, meals: meals, goal: snapshot.goal, weightTrend: snapshot.weightTrend,
                activeEnergyBurned: snapshot.activeEnergyBurned, readProvenance: snapshot.readProvenance)
        } else if snapshot == nil, calendar.startOfDay(for: record.eatenAt) == today {
            self.snapshot = DashboardSnapshot(date: today, meals: [record], goal: nil)
        }
    }

    func markReviewed(_ itemID: UUID) async -> Bool {
        do {
            try await joinedWrite("review:\(itemID)") {
                try await self.repository.confirmMealItem(userID: self.userID, itemID: itemID)
            }
            confirmedWrite { confirmingItem(itemID, in: $0) { acknowledgedRow($0, confidence: 1.0) } }
            return true
        } catch {
            return refuse(error)
        }
    }

    func updateMealItem(_ update: MealItemUpdate) async -> Bool {
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            try await joinedWrite("edit:\(update.itemID)") {
                try await self.repository.updateMealItem(userID: self.userID, update: update)
            }
            confirmedWrite { confirmingItem(update.itemID, in: $0) { acknowledgedRow($0, update) } }
            return true
        } catch {
            return refuse(error)
        }
    }

    func attachPhoto(_ photo: FoodImageUpload, toItem itemID: UUID) async -> Bool {
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            try await joinedWrite("photo:\(itemID)") {
                try await self.repository.attachMealPhoto(userID: self.userID, itemID: itemID, photo: photo)
            }
            syncEngine?.syncNow()
            confirmedWrite { day in
                guard let owner = day.meals.first(where: { $0.items.contains { $0.itemID == itemID } }) else {
                    return day
                }
                let image = MealImage(path: FoodImageStore.objectPath(userID: userID, imageID: owner.mealLogID))
                return confirming(owner.mealLogID, in: day) {
                    acknowledgedRow($0, items: $0.items.map { $0.withMealImage(image) }, image: image)
                }
            }
            return true
        } catch {
            return refuse(error)
        }
    }

    func deleteMeal(_ mealLogID: UUID) async -> Bool {
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            try await joinedWrite("delete:\(mealLogID)") {
                try await self.repository.deleteMealLog(userID: self.userID, mealLogID: mealLogID)
            }
            confirmedWrite { confirmingMeals($0) { $0.mealLogID == mealLogID ? nil : $0 } }
            return true
        } catch {
            return refuse(error)
        }
    }

    /// Issue #190 — the refusal path every confirmed mutation shares: a
    /// cancelled write stays silent, a refused one carries its honest copy.
    private func refuse(_ error: Error) -> Bool {
        guard !(error is CancellationError) else { return false }
        errorMessage = DashboardUserMessage.userMessage(for: error); return false
    }
}

// MARK: - Health pass helpers (issue #112 truthful per-type status)
// see docs/NATIVE_JOURNAL_PROVENANCE.md
extension DashboardViewModel {
    private func publishDay(_ loaded: DashboardSnapshot) {
        var day = loaded
        day.readProvenance = day.readProvenance ?? DayReadProvenance(isCached: false, loadedAt: dateProvider())
        snapshot = day
    }

    func selectDate(_ date: Date) {
        let day = DashboardMath.startOfLocalDay(date)
        guard day != selectedDate, day <= today else { return }
        diaryDate = day == today ? nil : day
        cancelRefresh(); snapshot = nil; errorMessage = nil
    }

    /// One independent body-mass delta pass (issue #192): the importer owns the
    /// durable cursor, which advances only with the persisted window, so the
    /// foreground path and the observer path share one ownership.
    private func importBodyMassPass() async throws -> Int {
        guard let weightImporter else { return 0 }
        return try await weightImporter.importBodyMassDelta().count
    }

    /// One independent active-energy delta pass; returns the number of local
    /// day rows the window touched.
    private func importEnergyPass() async throws -> Int {
        guard let weightImporter else { return 0 }
        return try await weightImporter.importActiveEnergyDelta().count
    }

    /// Observer failure: human copy, then derive status with zero imported rows.
    private func handleObserverImportError(_ error: Error) async {
        weightImportError = HealthSyncUserMessage.userMessage(for: error)
        await updateCalmStatus(bodyMassFailed: true, energyFailed: true, bodyImported: 0, energyImported: 0)
    }

    /// Maps an import failure through the human copy table (never raw text).
    private func surfaceHealthError(_ error: Error) {
        weightImportError = HealthSyncUserMessage.userMessage(for: error)
    }

    /// #112/#173: await per-type read decisions (not share status). Unknown
    /// permission cannot claim sync; only matching upload stamps name synced kinds.
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
        if (try? healthStore?.hasPendingUploads()) ?? false {
            healthStatus = .pending
            return
        }
        let hasWeightRows = (try? healthStore?.hasWeightSamples()) == true
        if bodyReadDecided, bodyImported == 0, !hasWeightRows,
           (try? healthStore?.lastWeightUpload()) == nil {
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

    /// Re-derives the calm status after a sync pass (rows drained → synced
    /// with the last upload time + uploaded kinds; otherwise pending).
    func refreshHealthCalmStatus() async {
        await updateCalmStatus(bodyMassFailed: false, energyFailed: false, bodyImported: 0, energyImported: 0)
    }
}

// MARK: - Issue #190 confirmed writes (the day read is freshness, never the gate)

extension DashboardViewModel {
    /// Issue #190 — the acknowledged write invalidates the day for a fresh read, then updates
    /// ONLY the acknowledged record of the day on screen; no caller waits for that read.
    private func confirmedWrite(_ acknowledged: (DashboardSnapshot) -> DashboardSnapshot) {
        let day = snapshot
        _ = startRefresh(invalidating: true, keepsAlive: true)
        guard let day else { return }
        self.snapshot = acknowledged(day)
    }

    /// Issue #190 — an acknowledged Goals save invalidates the day without awaiting it.
    func invalidateDayAfterConfirmedGoals() { _ = startRefresh(invalidating: true, keepsAlive: true) }
}

// MARK: - Issue #195 derived day work (one scan per day-data revision)

extension DashboardViewModel {
    /// The day's totals, groupings and review items come from ONE scan that is
    /// reused until the meals change; the key is the data revision the snapshot
    /// write path maintains, never the publish count.
    private func derived() -> DayDerived {
        if let derivedCache, derivedCache.revision == derivedRevision { return derivedCache.value }
        derivedScanCount += 1
        let meals = snapshot?.meals ?? []
        let groups = MealType.allCases.compactMap { type -> MealGroup? in
            let matching = meals.filter { $0.mealType == type }
            return matching.isEmpty ? nil : MealGroup(type: type, meals: matching)
        }
        let value = DayDerived(totals: DashboardMath.totals(for: meals), groups: groups,
                               review: meals.flatMap(\.items).filter(\.needsReview))
        derivedCache = (derivedRevision, value)
        return value
    }
}

/// Issue #195 — one scan's worth of day-derived values, reused until the meals change.
struct DayDerived {
    let totals: DashboardTotals
    let groups: [MealGroup]
    let review: [MealItem]
}

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

/// Issue #106 — calm Apple Health sync status (never raw entitlement/HK
/// text). `synced` shows the last successful upload time; `pending` means
/// locally stored rows are waiting for a connection; the other states are
/// permission/availability with a user-invokable retry path.
enum HealthCalmStatus: Equatable, Sendable {
    case unknown
    case syncing
    case synced(Date)
    case pending
    case permissionRequired
    case unavailable

    var copy: String {
        switch self {
        case .unknown:
            return "Apple Health sync has not run yet."
        case .syncing:
            return "Checking Apple Health…"
        case let .synced(date):
            return "Last successful Health sync · \(date.formatted(date: .omitted, time: .shortened))"
        case .pending:
            return "Health data is ready — it will sync when a connection is available."
        case .permissionRequired:
            return "Allow Apple Health access in Settings to sync body weight and activity."
        case .unavailable:
            return "Apple Health is unavailable on this device."
        }
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
                        self?.weightImportError = HealthSyncUserMessage.userMessage(for: error)
                        self?.updateCalmStatus(bodyMassFailed: true, energyFailed: true)
                    }
                }
            )
        }
        var bodyFailed = false
        var energyFailed = false

        // Body mass path (independent).
        do {
            let anchor = try? healthStore?.bodyMassAnchor()
            let stored = try await weightImporter.importBodyMass(since: anchor)
            if let latest = stored.map(\.measuredAt).max(), latest > (anchor ?? .distantPast) {
                try? healthStore?.setBodyMassAnchor(latest)
            }
        } catch is CancellationError {
            return
        } catch {
            bodyFailed = true
            surfaceHealthError(error)
        }

        // Active energy path (independent — runs even if body mass failed).
        do {
            let anchor = try? healthStore?.energyAnchor()
            let stored = try await weightImporter.importActiveEnergy(since: anchor)
            if let latest = stored.map(\.burnedAt).max(), latest > (anchor ?? .distantPast) {
                try? healthStore?.setEnergyAnchor(latest)
            }
        } catch is CancellationError {
            return
        } catch {
            energyFailed = true
            surfaceHealthError(error)
        }

        updateCalmStatus(bodyMassFailed: bodyFailed, energyFailed: energyFailed)
        syncEngine?.syncNow()
    }

    /// Maps an import failure through the human copy table (never raw text).
    private func surfaceHealthError(_ error: Error) {
        weightImportError = HealthSyncUserMessage.userMessage(for: error)
    }

    /// Calm status derivation: permission/availability come from the typed
    /// importer error or the per-type authorization state — never from raw
    /// system text; otherwise the status is `synced` (last successful upload)
    /// or `pending` (durable rows waiting for a connection).
    private func updateCalmStatus(bodyMassFailed: Bool, energyFailed: Bool) {
        guard let weightImporter else {
            healthStatus = .unavailable
            return
        }
        if bodyMassFailed || energyFailed {
            let denied = !weightImporter.authorizationStatus(for: .bodyMass)
                || !weightImporter.authorizationStatus(for: .activeEnergyBurned)
            if denied {
                healthStatus = .permissionRequired
                return
            }
        }
        if let lastUpload = try? healthStore?.lastSuccessfulUpload() {
            healthStatus = .synced(lastUpload)
            return
        }
        let hasPending = (try? healthStore?.hasPendingUploads()) ?? false
        healthStatus = hasPending ? .pending : .unknown
    }

    /// Re-derives the calm status after a sync pass (rows drained → synced
    /// with the last upload time; otherwise pending).
    func refreshHealthCalmStatus() {
        updateCalmStatus(bodyMassFailed: false, energyFailed: false)
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
        let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            return calendar
        }()
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

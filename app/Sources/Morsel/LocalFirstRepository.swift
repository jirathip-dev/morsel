import Foundation

// Issue #106 — local-first repository facade. Every read hydrates from the
// account-scoped SQLite cache first (or writes the authoritative remote
// snapshot through on success); a remote failure never erases the last valid
// cached snapshot and queued meal rows are always merged into the journal so
// a save is visible the moment its local transaction commits. The store is a
// cache/outbox — RLS, the security-invoker meal transaction and friendly
// error boundaries remain authoritative on the server.
final class LocalFirstDashboardRepository: DashboardRepository {
    private let remote: any DashboardRepository
    private let store: LocalDataStore
    private let snapshotCache: LocalSnapshotCache
    /// Local-first Apple Health store (same account file); optional for tests
    /// that only exercise meal reliability.
    private let healthStore: LocalHealthStore?
    /// Asks the owning coordinator to attempt a durable sync pass now.
    private let requestSync: () -> Void
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    init(
        remote: any DashboardRepository,
        store: LocalDataStore,
        snapshotCache: LocalSnapshotCache,
        healthStore: LocalHealthStore? = nil,
        requestSync: @escaping () -> Void = {}
    ) {
        self.remote = remote
        self.store = store
        self.snapshotCache = snapshotCache
        self.healthStore = healthStore
        self.requestSync = requestSync
    }

    // MARK: - Today

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        let dayKey = Self.dayKey(date)
        do {
            let snapshot = try await remote.loadToday(userID: userID, date: date)
            try snapshotCache.saveDashboardCache(dayKey: dayKey, payload: try Self.encode(snapshot))
            return try merged(snapshot, userID: userID, date: date)
        } catch {
            // Remote failure must not erase a valid cached snapshot: serve
            // the last local copy (with queued rows) instead of throwing.
            if let cached = try cachedSnapshot(dayKey: dayKey) {
                return try merged(cached, userID: userID, date: date)
            }
            throw error
        }
    }

    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? {
        try cachedSnapshot(dayKey: Self.dayKey(date))
    }

    private func cachedSnapshot(dayKey: String) throws -> DashboardSnapshot? {
        guard let payload = try snapshotCache.loadDashboardCache(dayKey: dayKey) else {
            return nil
        }
        return try Self.decode(DashboardSnapshot.self, payload)
    }

    // MARK: - History + Goals

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        let cacheKey = Self.historyKey(end: end, days: days)
        do {
            let overview = try await remote.loadHistory(userID: userID, end: end, days: days)
            try snapshotCache.saveHistoryCache(cacheKey: cacheKey, payload: try Self.encode(overview))
            return overview
        } catch {
            if let payload = try snapshotCache.loadHistoryCache(cacheKey: cacheKey) {
                return try Self.decode(HistoryOverview.self, payload)
            }
            throw error
        }
    }

    func cachedHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview? {
        guard let payload = try snapshotCache.loadHistoryCache(cacheKey: Self.historyKey(end: end, days: days)) else {
            return nil
        }
        return try Self.decode(HistoryOverview.self, payload)
    }

    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? {
        do {
            let goal = try await remote.loadGoals(userID: userID)
            if let goal, let payload = try? Self.encode(goal) {
                try? snapshotCache.saveGoalsCache(userKey: userID.uuidString, payload: payload)
            }
            return goal
        } catch {
            guard let payload = try snapshotCache.loadGoalsCache(userKey: userID.uuidString) else {
                throw error
            }
            return try Self.decode(StoredDashboardGoal.self, payload)
        }
    }

    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        do {
            let goal = try await remote.computeGoals(userID: userID, direction: direction)
            if let payload = try? Self.encode(goal) {
                try? snapshotCache.saveGoalsCache(
                    userKey: "computed.\(direction.rawValue).\(userID.uuidString)", payload: payload
                )
            }
            return goal
        } catch {
            guard let payload = try snapshotCache.loadGoalsCache(
                userKey: "computed.\(direction.rawValue).\(userID.uuidString)"
            ) else {
                throw error
            }
            return try Self.decode(DashboardGoal.self, payload)
        }
    }

    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {
        try await remote.saveGoals(userID: userID, goal: goal)
        let stored = StoredDashboardGoal(
            calorieTargetKcal: goal.calorieTargetKcal,
            proteinG: goal.proteinG,
            carbsG: goal.carbsG,
            fatG: goal.fatG,
            source: .manual
        )
        if let payload = try? Self.encode(stored) {
            try? snapshotCache.saveGoalsCache(userKey: userID.uuidString, payload: payload)
        }
    }

    // MARK: - Meal writes

    /// Durable local commit: validate, then write meal + items + photo in ONE
    /// SQLite transaction. No network on this path — the UI may leave Add
    /// Meal and show the row with `pending sync` immediately.
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        try MealDraftValidation.validate(draft)
        if let photo {
            try FoodImageStore.validate(data: photo.data, mimeType: photo.mimeType)
        }
        let queued = QueuedMealFactory.make(draft: draft, photo: photo)
        try store.enqueueMeal(queued)
        requestSync()
        return queued.mealID
    }

    func localMealRecord(userID: UUID, localMealID: UUID) async throws -> MealRecord? {
        try store.queuedMeal(mealID: localMealID)?.mealRecord
    }

    /// Deleting a never-synced queued meal cancels the outbox row locally
    /// (the server never saw it); synced meals delete remotely as before.
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {
        if try store.queuedMeal(mealID: mealLogID) != nil {
            try store.removeMeal(mealID: mealLogID)
            return
        }
        try await remote.deleteMealLog(userID: userID, mealLogID: mealLogID)
    }

    /// Item edits on a still-queued meal mutate the durable local draft;
    /// synced meals update remotely as before.
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {
        if let queued = try queuedMeal(containingItem: update.itemID) {
            try store.updateQueuedMealItems(mealID: queued.mealID, items: updatedItems(queued, update))
            return
        }
        try await remote.updateMealItem(userID: userID, update: update)
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {
        if try queuedMeal(containingItem: itemID) != nil {
            return // local manual items never need remote review confirmation
        }
        try await remote.confirmMealItem(userID: userID, itemID: itemID)
    }

    func loadMealImage(userID: UUID, path: String) async throws -> Data {
        try await remote.loadMealImage(userID: userID, path: path)
    }

    // MARK: - Pending merge

    /// Serves the journal snapshot with durable queued rows merged in. Rows
    /// the server already carries (identical client/server ids after sync)
    /// are replaced by their authoritative remote copy — never duplicated.
    private func merged(_ snapshot: DashboardSnapshot, userID: UUID, date: Date) throws -> DashboardSnapshot {
        let dayStart = calendar.startOfDay(for: date)
        var meals = snapshot.meals
        var remoteIDs = Set(meals.map(\.mealLogID))
        let queued = try store.queuedMeals()
        for row in queued where calendar.startOfDay(for: row.eatenAt) == dayStart {
            guard !remoteIDs.contains(row.mealID) else { continue }
            meals.append(row.mealRecord)
            remoteIDs.insert(row.mealID)
        }
        meals.sort { $0.eatenAt < $1.eatenAt }
        return DashboardSnapshot(
            date: snapshot.date,
            meals: meals,
            goal: snapshot.goal,
            weightTrend: try mergedWeightTrend(snapshot.weightTrend),
            activeEnergyBurned: mergedActiveEnergy(remote: snapshot.activeEnergyBurned, day: dayStart)
        )
    }

    /// Local body-mass rows awaiting upload extend the trend (same measured
    /// time never duplicates the remote row).
    private func mergedWeightTrend(_ remoteTrend: [WeightTrendPoint]) throws -> [WeightTrendPoint] {
        guard let healthStore else { return remoteTrend }
        let remoteDates = Set(remoteTrend.map(\.date))
        let unsynced = try healthStore.unsyncedWeightSamples()
        var trend = remoteTrend
        for sample in unsynced where !remoteDates.contains(sample.measuredAt) {
            trend.append(WeightTrendPoint(date: sample.measuredAt, kilograms: sample.kilograms))
        }
        return trend.sorted { $0.date < $1.date }
    }

    /// A dirty (not yet uploaded) local energy day is fresher than the last
    /// remote day total; energy only grows as samples arrive, so the larger
    /// of the two is the truthful context value.
    private func mergedActiveEnergy(remote: Double, day: Date) -> Double {
        guard let healthStore else { return remote }
        guard let dirty = try? healthStore.dirtyEnergyDays(),
              let dayRow = dirty.first(where: {
                  calendar.startOfDay(for: $0.burnedAt) == calendar.startOfDay(for: day)
              }) else {
            return remote
        }
        return max(remote, dayRow.activeKilocalories)
    }

    private func queuedMeal(containingItem itemID: UUID) throws -> QueuedMeal? {
        try store.queuedMeals().first { meal in meal.items.contains { $0.itemID == itemID } }
    }

    private func updatedItems(_ queued: QueuedMeal, _ update: MealItemUpdate) -> [QueuedMealItem] {
        queued.items.map { item in
            guard item.itemID == update.itemID else { return item }
            return QueuedMealItem(
                itemID: item.itemID,
                name: update.name ?? item.name,
                quantity: update.quantity ?? item.quantity,
                unit: item.unit,
                caloriesKcal: update.caloriesKcal ?? item.caloriesKcal,
                proteinG: update.proteinG ?? item.proteinG,
                carbsG: update.carbsG ?? item.carbsG,
                fatG: update.fatG ?? item.fatG,
                fiberG: item.fiberG,
                sugarG: item.sugarG,
                confidence: item.confidence,
                notes: item.notes
            )
        }
    }

    // MARK: - Keys + coding

    static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return String(calendar.startOfDay(for: date).timeIntervalSince1970)
    }

    private static func historyKey(end: Date, days: Int) -> String {
        "\(Self.dayKey(end))-\(days)"
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

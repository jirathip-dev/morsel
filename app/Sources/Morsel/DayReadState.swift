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

/// Native day-read provenance; persisted with the cached day, never inferred from its diary date.
/// Optional on the snapshot so older cached payloads still decode without an invented success time.
struct DayReadProvenance: Equatable, Sendable, Codable {
    let isCached: Bool
    let loadedAt: Date?
}

struct DashboardSnapshot: Equatable, Sendable, Codable {
    let date: Date
    let meals: [MealRecord]
    let goal: DashboardGoal?
    let weightTrend: [WeightTrendPoint]
    let activeEnergyBurned: Double
    var readProvenance: DayReadProvenance?
    let datedTarget: DatedTarget?

    init(
        date: Date, meals: [MealRecord], goal: DashboardGoal?, weightTrend: [WeightTrendPoint] = [],
        activeEnergyBurned: Double = 0, readProvenance: DayReadProvenance? = nil, datedTarget: DatedTarget? = nil
    ) {
        self.date = date
        self.meals = meals
        self.goal = goal
        self.weightTrend = weightTrend
        self.activeEnergyBurned = activeEnergyBurned
        self.readProvenance = readProvenance
        self.datedTarget = datedTarget
    }
}

extension DashboardSnapshot {
    var cachedCopy: DashboardSnapshot {
        var copy = self
        copy.readProvenance = DayReadProvenance(isCached: true, loadedAt: readProvenance?.loadedAt)
        return copy
    }
}

extension LocalFirstDashboardRepository {
    /// Issue #181 — the cached FIRST paint honours the same durable local
    /// overlays an authoritative refresh does: queued meals (each exactly
    /// once, with their own pending/needs-attention state) plus unsynced
    /// weight/energy under the existing whole-second + trailing-window rules.
    /// A queued-only startup with no dashboard cache still paints those rows
    /// locally — no goal, no remote value, and never a claim that pending
    /// rows are synced. Nothing to overlay and nothing cached means nil.
    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? {
        if let cached = try cachedSnapshot(dayKey: Self.dayKey(date)) {
            return try merged(cached, userID: userID, date: date)
        }
        let localOnly = try merged(
            DashboardSnapshot(date: DashboardMath.startOfLocalDay(date), meals: [], goal: nil),
            userID: userID, date: date
        )
        return localOnly.meals.isEmpty ? nil : localOnly
    }

    func cachedSnapshot(dayKey: String) throws -> DashboardSnapshot? {
        guard let payload = try snapshotCache.loadDashboardCache(dayKey: dayKey) else {
            return nil
        }
        return try Self.decode(DashboardSnapshot.self, payload).cachedCopy
    }
}

extension DashboardViewModel {
    var lastLoadedAt: Date? { snapshot?.readProvenance?.loadedAt }
    var isShowingCachedDay: Bool { snapshot?.readProvenance?.isCached == true }
}

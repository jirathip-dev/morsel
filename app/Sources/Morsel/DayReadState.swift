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

    init(
        date: Date, meals: [MealRecord], goal: DashboardGoal?, weightTrend: [WeightTrendPoint] = [],
        activeEnergyBurned: Double = 0, readProvenance: DayReadProvenance? = nil
    ) {
        self.date = date
        self.meals = meals
        self.goal = goal
        self.weightTrend = weightTrend
        self.activeEnergyBurned = activeEnergyBurned
        self.readProvenance = readProvenance
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
    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? {
        try cachedSnapshot(dayKey: Self.dayKey(date))
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

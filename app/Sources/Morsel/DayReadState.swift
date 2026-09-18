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

/// Issue #303 — the outcome of the read that produced the visible copy:
/// `fresh` is an authoritative read of this day; `pending` is a cached copy
/// whose refresh has not concluded yet (the normal first paint — silent);
/// `failed` is a cached copy whose refresh concluded unsuccessfully — the one
/// state the cached notice announces.
enum DayReadOutcome: String, Codable, Sendable {
    case fresh, pending, failed
}

/// Native day-read provenance; persisted with the cached day, never inferred from its diary date.
/// Optional on the snapshot so older cached payloads still decode without an invented success time.
struct DayReadProvenance: Equatable, Sendable, Codable {
    let isCached: Bool
    let loadedAt: Date?
    /// Issue #303 — how this copy was produced. Cached copies are `pending`
    /// until their refresh concludes; a payload written before this field
    /// existed decodes as `pending` (a concluded refresh is never invented).
    let outcome: DayReadOutcome

    init(isCached: Bool, loadedAt: Date?, outcome: DayReadOutcome? = nil) {
        self.isCached = isCached
        self.loadedAt = loadedAt
        self.outcome = outcome ?? (isCached ? .pending : .fresh)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isCached = try container.decode(Bool.self, forKey: .isCached)
        loadedAt = try container.decodeIfPresent(Date.self, forKey: .loadedAt)
        outcome = try container.decodeIfPresent(DayReadOutcome.self, forKey: .outcome) ?? .pending
    }
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
    /// Issue #303 — the cached copy painted before (or while) its refresh runs:
    /// the outcome stays `pending`, so nothing is announced until the refresh
    /// behind it concludes unsuccessfully.
    var cachedCopy: DashboardSnapshot {
        var copy = self
        copy.readProvenance = DayReadProvenance(
            isCached: true, loadedAt: readProvenance?.loadedAt, outcome: .pending
        )
        return copy
    }

    /// Issue #303 — the last good copy after its refresh concluded
    /// unsuccessfully: the one cached state the notice announces, with the
    /// last successful load time and a retry.
    var failedRefreshCopy: DashboardSnapshot {
        var copy = self
        copy.readProvenance = DayReadProvenance(
            isCached: true, loadedAt: readProvenance?.loadedAt, outcome: .failed
        )
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

    /// Issue #303 — the cached notice gate: a cached copy is on screen AND its
    /// refresh concluded unsuccessfully. Cache-ness alone — the normal first
    /// paint while the refresh is in flight — never announces.
    var isShowingCachedDay: Bool {
        guard let provenance = snapshot?.readProvenance else { return false }
        return provenance.isCached && provenance.outcome == .failed
    }

    /// Issue #303 — the in-flight half of the distinction, observable in state:
    /// a cached copy is on screen while its refresh has not concluded.
    var isRefreshingCachedDay: Bool {
        guard let provenance = snapshot?.readProvenance else { return false }
        return provenance.isCached && provenance.outcome == .pending
    }
}

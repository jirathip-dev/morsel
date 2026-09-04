import Foundation

// Issue #94 — History ledger models + math (kept out of Models.swift so the
// shipped files stay inside the repo lint budgets).

enum DayComparison: Equatable, Sendable {
    case under
    case onTarget
    case over

    /// DESIGN.md signed state words: "under / on target / over".
    var word: String {
        switch self {
        case .under: return "under"
        case .onTarget: return "on target"
        case .over: return "over"
        }
    }
}

// MARK: - History (issue #94)

/// One calendar day of the History ledger. `logged` is true when at least one
/// meal was recorded that day; `eatenKcal` is that day's total.
struct HistoryDay: Identifiable, Equatable, Sendable {
    let date: Date
    let eatenKcal: Double
    let logged: Bool

    var id: Date { date }
}

/// A History range payload: per-day totals + the effective goal + the weight
/// trend across the trailing 30 days (the trend spans a fixed 30-day window,
/// matching the approved V1 History page).
struct HistoryOverview: Equatable, Sendable {
    let days: [HistoryDay]
    let goal: DashboardGoal?
    let weightTrend: [WeightTrendPoint]

    init(days: [HistoryDay], goal: DashboardGoal?, weightTrend: [WeightTrendPoint] = []) {
        self.days = days
        self.goal = goal
        self.weightTrend = weightTrend
    }
}

extension DashboardMath {
    // MARK: History ledger math (issue #94)

    /// Day buckets must be compared on the same UTC-day grid the repository
    /// uses for meal_logs ranges.
    static func startOfUTCDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.startOfDay(for: date)
    }

    /// Completed (non-today) logged days in a window.
    static func completedLoggedDays(_ days: [HistoryDay], today: Date) -> [HistoryDay] {
        let todayStart = startOfUTCDay(today)
        return days.filter { day in
            day.logged && startOfUTCDay(day.date) < todayStart
        }
    }

    static func averageKcal(_ days: [HistoryDay], today: Date) -> Double? {
        let completed = completedLoggedDays(days, today: today)
        guard !completed.isEmpty else { return nil }
        let sum = completed.reduce(0) { $0 + $1.eatenKcal }
        return sum / Double(completed.count)
    }

    static func daysOverGoal(_ days: [HistoryDay], goal: Double?, today: Date) -> Int {
        guard let goal, goal.isFinite, goal > 0 else { return 0 }
        return completedLoggedDays(days, today: today).filter { day in
            (day.eatenKcal - goal) > onTargetToleranceKcal
        }.count
    }

    static func daysLogged(_ days: [HistoryDay], today: Date) -> Int {
        completedLoggedDays(days, today: today).count
    }

    /// Trailing streak of consecutive logged days ending today (when today is
    /// logged) or yesterday. Empty window → 0.
    static func loggingStreak(_ days: [HistoryDay], today: Date) -> Int {
        let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            return calendar
        }()
        let loggedStarts = Set(days.filter(\.logged).map { startOfUTCDay($0.date) })
        var cursor = startOfUTCDay(today)
        if !loggedStarts.contains(cursor) {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = previous
        }
        var streak = 0
        while loggedStarts.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}

import Foundation
import Supabase

// Issue #94 — History range loading for the V1 History ledger tab (kept out of
// Repository.swift so the shipped files stay inside the repo lint budgets).

extension SupabaseDashboardRepository {
    // MARK: History (issue #94)

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let endStart = utcCalendar.startOfDay(for: end)
        let clampedDays = min(max(days, 1), 30)
        guard let start = utcCalendar.date(byAdding: .day, value: -(clampedDays - 1), to: endStart),
              let nextDay = utcCalendar.date(byAdding: .day, value: 1, to: endStart),
              let trendStart = utcCalendar.date(byAdding: .day, value: -29, to: endStart) else {
            throw MorselError.invalidData("The history range could not be calculated.")
        }

        let logs = try await loadMealLogs(client, userID: authenticatedUserID, start: start, end: nextDay)
        let items = try await loadMealItems(client, logs: logs)
        let goalRows = try await loadGoals(client, userID: authenticatedUserID)
        let profileRows = try await loadProfiles(client, userID: authenticatedUserID)
        let weightRows = try await loadWeightTrend(
            client, userID: authenticatedUserID, start: trendStart, end: nextDay
        )

        let storedGoal = try goalRows.first.map(parseStoredGoal)
        let profile = try profileRows.first.map(parseProfile)
        // Issue #113 — newest synced weight feeds the computed path (profile
        // weight remains the fallback), like the server's weight_used.
        let goal = historyEffectiveGoal(stored: storedGoal, profile: profile, weightRows: weightRows)

        // Bucket meal logs into UTC calendar days; aggregate item calories.
        var caloriesByMealID: [String: Double] = [:]
        for item in items {
            caloriesByMealID[item.mealLogID, default: 0] += item.caloriesKcal ?? 0
        }
        var mealCountByDay: [Date: Int] = [:]
        var caloriesByDay: [Date: Double] = [:]
        for log in logs {
            guard let eatenAt = MorselDate.date(log.eatenAt) else { continue }
            let day = utcCalendar.startOfDay(for: eatenAt)
            mealCountByDay[day, default: 0] += 1
            caloriesByDay[day, default: 0] += caloriesByMealID[log.id] ?? 0
        }

        var day = start
        var historyDays: [HistoryDay] = []
        while day < nextDay {
            let logged = (mealCountByDay[day] ?? 0) > 0
            historyDays.append(
                HistoryDay(date: day, eatenKcal: logged ? (caloriesByDay[day] ?? 0) : 0, logged: logged)
            )
            guard let following = utcCalendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = following
        }

        return HistoryOverview(
            days: historyDays,
            goal: goal,
            weightTrend: DashboardMath.dedupeWeightTrendByWholeSecond(weightRows.compactMap(parseWeight))
        )
    }

    /// Amendment A helper: newest synced weight feeds the history goal's
    /// computed path (profile weight remains the fallback), like the
    /// server's weight_used — kept out of loadHistory's body budget.
    private func historyEffectiveGoal(
        stored: StoredDashboardGoal?, profile: DashboardProfile?, weightRows: [WeightResponse]
    ) -> DashboardGoal? {
        DashboardMath.effectiveGoal(
            stored: stored, profile: profile,
            latestWeightKg: weightRows.compactMap(parseWeight).last?.kilograms
        )
    }
}

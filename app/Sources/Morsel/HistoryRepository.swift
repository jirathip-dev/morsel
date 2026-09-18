import Foundation
import Supabase

// Issue #94 — History range loading for the V1 History ledger tab (kept out of
// Repository.swift so the shipped files stay inside the repo lint budgets).

// Issue #193 — the ledger's own NARROW projection: meal identity/date and the
// calorie contribution only. The rich projection in Repository.swift
// (`mealItemColumns`) stays untouched — the Today/drill-down read still
// transfers complete items and photos.
let ledgerMealLogColumns = "id,eaten_at"
let ledgerMealItemColumns = "meal_log_id,calories_kcal"

struct LedgerMealLogResponse: Decodable {
    let id: String
    let eatenAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case eatenAt = "eaten_at"
    }
}

struct LedgerMealItemResponse: Decodable {
    let mealLogID: String
    let caloriesKcal: Double?

    enum CodingKeys: String, CodingKey {
        case mealLogID = "meal_log_id"
        case caloriesKcal = "calories_kcal"
    }
}

extension SupabaseDashboardRepository {
    // MARK: History (issue #94)

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        try await loadHistory(userID: userID, end: end, days: days, calendar: .autoupdatingCurrent)
    }

    func loadHistory(userID: UUID, end: Date, days: Int, calendar: Calendar) async throws -> HistoryOverview {
        guard let client else {
            throw MorselError.configurationMissing
        }
        let authenticatedUserID = try await requireSession(client, userID: userID)

        // Issue #121 — day windows are the DEVICE'S LOCAL days (device zone).
        let endStart = calendar.startOfDay(for: end)
        let clampedDays = min(max(days, 1), 31) // A full calendar month fits in one overview (#249).
        guard let start = calendar.date(byAdding: .day, value: -(clampedDays - 1), to: endStart),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: endStart),
              let trendStart = calendar.date(byAdding: .day, value: -29, to: endStart) else {
            throw MorselError.invalidData("The history range could not be calculated.")
        }

        // Issue #178 — the independent goal/profile/weight reads overlap the
        // logs→items chain (bounded by ReadGraph.maxInFlightRequests).
        async let goalRowsTask = loadGoals(client, userID: authenticatedUserID)
        async let profileRowsTask = loadProfiles(client, userID: authenticatedUserID)
        async let weightRowsTask = loadWeightTrend(
            client, userID: authenticatedUserID, start: trendStart, end: nextDay
        )
        // Issue #193 — the ledger's own narrow read: identity/date + calorie
        // contributions only, instead of the shared rich item projection.
        let logs = try await loadLedgerMealLogs(client, userID: authenticatedUserID, start: start, end: nextDay)
        let items = try await loadLedgerMealCalories(client, logs: logs)
        let (goalRows, profileRows, weightRows) = try await (goalRowsTask, profileRowsTask, weightRowsTask)

        let targets = try await loadDatedTargets(userID: authenticatedUserID, start: start, end: endStart,
                                               calendar: calendar)
        // Issue #113 — newest synced weight feeds the computed path (profile
        // weight remains the fallback), like the server's weight_used.
        let goal = historyEffectiveGoal(stored: try goalRows.first.map(parseStoredGoal),
                                        profile: try profileRows.first.map(parseProfile), weightRows: weightRows)

        // Bucket meal logs into LOCAL calendar days; aggregate item calories.
        var caloriesByMealID: [String: Double] = [:]
        for item in items {
            caloriesByMealID[item.mealLogID, default: 0] += item.caloriesKcal ?? 0
        }
        var mealCountByDay: [Date: Int] = [:]
        var caloriesByDay: [Date: Double] = [:]
        for log in logs {
            guard let eatenAt = MorselDate.date(log.eatenAt) else { continue }
            let day = calendar.startOfDay(for: eatenAt)
            mealCountByDay[day, default: 0] += 1
            caloriesByDay[day, default: 0] += caloriesByMealID[log.id] ?? 0
        }

        var day = start
        var historyDays: [HistoryDay] = []
        while day < nextDay {
            let logged = (mealCountByDay[day] ?? 0) > 0
            historyDays.append(HistoryDay(
                date: day, eatenKcal: logged ? (caloriesByDay[day] ?? 0) : 0, logged: logged,
                datedTarget: targets.first { $0.date == DatedTarget.label(day, calendar: calendar) }))
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { break }
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

    // MARK: Narrow ledger read (issue #193)

    /// The History overview's meal read: identity and eaten_at only, on the
    /// same endpoint, filter and index as the rich `loadMealLogs`. Issue #194
    /// — read to completion in bounded pages over the `eaten_at,id` order.
    private func loadLedgerMealLogs(
        _ client: SupabaseClient, userID: UUID, start: Date, end: Date
    ) async throws -> [LedgerMealLogResponse] {
        try await pagedRows(
            identity: { $0.id },
            fetch: { offset, limit in
                try await client
                    .from("meal_logs")
                    .select(ledgerMealLogColumns)
                    .eq("user_id", value: userID.uuidString)
                    .gte("eaten_at", value: MorselDate.iso8601(start))
                    .lt("eaten_at", value: MorselDate.iso8601(end))
                    .order("eaten_at", ascending: true).order("id", ascending: true)
                    .range(from: offset, to: offset + limit - 1)
                    .boundedPage()
            }
        )
    }

    /// The History overview's item read: one calorie contribution per row
    /// (null stays null), in the same created_at order the baseline summed,
    /// so the per-meal totals are bit-for-bit the baseline's. Issue #194 — the
    /// meal ids go out in bounded chunks and each chunk pages to completion on
    /// `created_at,id`; both keys are immutable, so no row can migrate across
    /// a page boundary and the #193 narrow projection needs no identity
    /// column (see `ledgerItemIdentity`).
    private func loadLedgerMealCalories(
        _ client: SupabaseClient, logs: [LedgerMealLogResponse]
    ) async throws -> [LedgerMealItemResponse] {
        try await chunkedRows(
            ids: logs.map(\.id),
            identity: ledgerItemIdentity,
            fetch: { ids, offset, limit in
                try await client
                    .from("meal_items")
                    .select(ledgerMealItemColumns)
                    .in("meal_log_id", values: ids)
                    .order("created_at", ascending: true).order("id", ascending: true)
                    .range(from: offset, to: offset + limit - 1)
                    .boundedPage()
            }
        )
    }
}

/// The narrow ledger item projection carries no primary key (#193 keeps it to
/// `meal_log_id,calories_kcal`), and its ordering keys are immutable, so a row
/// cannot move across a page boundary: there is nothing to dedupe by and
/// nothing that could arrive twice. Distinct rows that share a calorie value
/// must both count, so no value-based identity is invented here.
private func ledgerItemIdentity(_ row: LedgerMealItemResponse) -> String? {
    nil
}

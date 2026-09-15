import Foundation
import Supabase

/// Read-only diary index, separate from the bounded History ledger read.
protocol JournalCalendarReading {
    func calendarDates(userID: UUID) async throws -> [Date]
    func cachedCalendarDates(userID: UUID) throws -> [Date]?
}

extension JournalCalendarReading {
    func cachedCalendarDates(userID: UUID) throws -> [Date]? { nil }
}

extension SupabaseDashboardRepository: JournalCalendarReading {
    func calendarDates(userID: UUID) async throws -> [Date] {
        guard let client else { throw MorselError.configurationMissing }
        let owner = try await requireSession(client, userID: userID)
        var offset = 0
        var dates: Set<Date> = []
        while true {
            try Task.checkCancellation()
            let rows: [CalendarLogDate] = try await client.from("meal_logs")
                .select("eaten_at").eq("user_id", value: owner.uuidString)
                .order("eaten_at", ascending: true).order("id", ascending: true)
                .range(from: offset, to: offset + 499).execute().value
            for row in rows {
                guard let date = MorselDate.date(row.eatenAt) else {
                    throw MorselError.invalidData("The diary returned an invalid meal date.")
                }
                dates.insert(DashboardMath.startOfLocalDay(date))
            }
            if rows.count < 500 { return dates.sorted() }
            offset += rows.count
        }
    }
}

private struct CalendarLogDate: Decodable {
    let eatenAt: String
    enum CodingKeys: String, CodingKey { case eatenAt = "eaten_at" }
}

extension LocalFirstDashboardRepository: JournalCalendarReading {
    private func calendarCacheKey(_ userID: UUID) -> String {
        "diary-index-" + userID.uuidString + "-" + TimeZone.autoupdatingCurrent.identifier
    }

    func cachedCalendarDates(userID: UUID) throws -> [Date]? {
        guard let payload = try snapshotCache.loadHistoryCache(cacheKey: calendarCacheKey(userID)) else { return nil }
        let cached = try JSONDecoder().decode(HistoryOverview.self, from: payload)
        let queued = try store.queuedMeals().map { DashboardMath.startOfLocalDay($0.eatenAt) }
        return Array(Set(cached.days.map(\.date) + queued)).sorted()
    }

    func calendarDates(userID: UUID) async throws -> [Date] {
        var dates: [Date]
        do {
            guard let reader = remote as? any JournalCalendarReading else {
                throw MorselError.invalidData("The diary index is unavailable.")
            }
            dates = try await reader.calendarDates(userID: userID)
            let index = HistoryOverview(days: dates.map { HistoryDay(date: $0, eatenKcal: 0, logged: true) }, goal: nil)
            try snapshotCache.saveHistoryCache(cacheKey: calendarCacheKey(userID), payload: JSONEncoder().encode(index))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let cached = try cachedCalendarDates(userID: userID) else { throw error }
            dates = cached
        }
        dates += try store.queuedMeals().map { DashboardMath.startOfLocalDay($0.eatenAt) }
        return Array(Set(dates)).sorted()
    }
}

extension MockDashboardRepository: JournalCalendarReading {
    func calendarDates(userID: UUID) async throws -> [Date] {
        historyOverview.days.filter(\.logged).map(\.date)
    }
}

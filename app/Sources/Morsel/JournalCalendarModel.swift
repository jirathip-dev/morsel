import SwiftUI

@MainActor
final class JournalCalendarModel: ObservableObject {
    @Published private(set) var loggedDates: Set<Date> = []
    @Published private(set) var hasIndex = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var month: Date
    @Published private(set) var days: [HistoryDay] = []
    @Published private(set) var goal: DashboardGoal?
    private let repository: any DashboardRepository
    private let userID: UUID
    private var generation = 0
    let calendar: Calendar
    let today: Date

    init(repository: any DashboardRepository, userID: UUID, today: Date = Date(),
         calendar: Calendar = .autoupdatingCurrent) {
        self.repository = repository
        self.userID = userID
        self.calendar = calendar
        self.today = calendar.startOfDay(for: today)
        month = calendar.dateInterval(of: .month, for: today)?.start ?? today
    }

    var firstLoggedDay: Date? { loggedDates.filter { $0 <= today }.min() }
    var earliestDay: Date? {
        guard hasIndex else { return nil }
        return calendar.date(byAdding: .day, value: -1, to: firstLoggedDay ?? today)
    }
    var months: [Date] {
        guard let first = earliestDay,
              var cursor = calendar.dateInterval(of: .month, for: first)?.start else { return [month] }
        var result: [Date] = []
        while cursor <= today {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }
    var cells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        // The approved grid is Monday-first regardless of the device's firstWeekday.
        return Array(repeating: nil, count: (weekday + 5) % 7) + (0..<count).map {
            calendar.date(byAdding: .day, value: $0, to: interval.start)
        }
    }
    func allows(_ date: Date) -> Bool {
        guard let earliestDay else { return false }
        let day = calendar.startOfDay(for: date)
        return day >= earliestDay && day <= today
    }
    func adjacent(to date: Date, direction: PageTurnDirection) -> Date? {
        guard let next = calendar.date(byAdding: .day, value: direction == .forward ? 1 : -1, to: date),
              allows(next) else { return nil }
        return next
    }
    func showMonth(containing date: Date) async {
        month = calendar.dateInterval(of: .month, for: date)?.start ?? date
        await load()
    }
    func load() async {
        generation &+= 1
        let request = generation
        let requestedMonth = month
        isLoading = true
        errorMessage = nil
        days = []
        defer { if request == generation { isLoading = false } }
        do {
            guard let reader = repository as? any JournalCalendarReading else {
                throw MorselError.invalidData("The diary index is unavailable.")
            }
            if !hasIndex, let cached = try reader.cachedCalendarDates(userID: userID) {
                loggedDates = Set(cached.map { calendar.startOfDay(for: $0) })
                hasIndex = true
            }
            let dates = try await reader.calendarDates(userID: userID)
            guard request == generation else { return }
            loggedDates = Set(dates.map { calendar.startOfDay(for: $0) })
            hasIndex = true
            guard let interval = calendar.dateInterval(of: .month, for: requestedMonth),
                  let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return }
            let overview = try await repository.loadHistory(userID: userID, end: min(last, today), days: 30)
            var loadedDays = overview.days
            if calendar.range(of: .day, in: .month, for: requestedMonth)?.count == 31, last <= today {
                let first = try await repository.loadHistory(userID: userID, end: interval.start, days: 1)
                loadedDays += first.days
            }
            guard request == generation else { return }
            days = loadedDays
            goal = overview.goal
        } catch is CancellationError {
            return
        } catch {
            guard request == generation else { return }
            errorMessage = DashboardUserMessage.userMessage(for: error)
        }
    }
}

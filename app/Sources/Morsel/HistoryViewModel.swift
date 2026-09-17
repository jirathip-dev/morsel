import Combine
import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
    enum RangeDays: Int, CaseIterable, Identifiable {
        case seven = 7
        case thirty = 30

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .seven: return "7 days"
            case .thirty: return "30 days"
            }
        }
    }

    @Published private(set) var overview: HistoryOverview?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var range: RangeDays = .seven {
        didSet {
            guard range != oldValue else { return }
            loadGeneration &+= 1
            overview = nil
            errorMessage = nil
            isLoading = false
            collapseDay()
        }
    }
    @Published private(set) var expandedDay: Date?
    @Published private(set) var daySnapshot: DashboardSnapshot?
    @Published private(set) var isExpandedLoading = false
    @Published private(set) var expandedError: String?

    /// Issue #136 — in-flight read generations (see `load()`/`select()`).
    private var loadGeneration = 0
    private var daySelectionGeneration = 0
    private var overviewScope: String?

    /// Newest first (the "Days vs goal" list); bars render ascending (#105).
    @Published var showsAllListDays = false

    let repository: any DashboardRepository
    let userID: UUID
    private let dateProvider: () -> Date
    /// Issue #175 — the mounted suites install a page lifecycle observer; the app leaves it nil.
    nonisolated(unsafe) static var observer: JournalPageObserver?
    init(
        repository: any DashboardRepository,
        userID: UUID,
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.userID = userID
        self.dateProvider = dateProvider
        Self.observer?(.created, .history, self)
    }

    deinit { Self.observer?(.released, .history, nil) }

    var today: Date { dateProvider() }

    var goal: DashboardGoal? { overview?.goal }

    /// Ledger (ascending, oldest first) — the bar chart order.
    var chartDays: [HistoryDay] {
        guard let overview else { return [] }
        let start = DashboardMath.startOfLocalDay(today)
        let windowStart = Calendar.autoupdatingCurrent
            .date(byAdding: .day, value: -(range.rawValue - 1), to: start) ?? start
        return overview.days.filter { $0.date >= windowStart && $0.date <= start }
    }

    /// Newest-first rows; 7-day mode caps the collapsed list at four rows.
    var listDays: [HistoryDay] {
        chartDays.reversed()
    }

    var visibleListDays: [HistoryDay] {
        let days = listDays
        guard range == .seven, !showsAllListDays else { return days }
        return Array(days.prefix(4))
    }

    var listRevealHiddenDays: [HistoryDay] {
        guard range == .seven, !showsAllListDays, listDays.count > 4 else { return [] }
        return Array(listDays.dropFirst(4))
    }

    var isTodayLogged: Bool {
        let todayStart = DashboardMath.startOfLocalDay(today)
        return chartDays.contains { DashboardMath.startOfLocalDay($0.date) == todayStart && $0.logged }
    }

    var averageKcal: Double? { DashboardMath.averageKcal(chartDays, today: today) }
    var daysOver: Int { DashboardMath.daysOverGoal(chartDays, goal: goal?.calorieTargetKcal, today: today) }
    var daysLogged: Int { DashboardMath.daysLogged(chartDays, today: today) }
    var streak: Int { DashboardMath.loggingStreak(chartDays, today: today) }

    var weightDeltaOverRange: Double? {
        guard let trend = overview?.weightTrend, trend.count >= 2,
              let first = trend.first?.kilograms, let last = trend.last?.kilograms else {
            return nil
        }
        return last - first
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let end = today
        let days = range.rawValue
        let scope = dayScope(end)
        if overviewScope != scope {
            overview = nil
            collapseDay()
        }
        overviewScope = scope
        isLoading = true
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
                if dayScope(today) != scope { overview = nil; collapseDay() }
            }
        }
        let cached = try? await repository.cachedHistory(userID: userID, end: end, days: days)
        guard ownsOverview(generation, scope: scope, days: days) else { return }
        if let cached { overview = cached.cachedCopy }
        do {
            let loaded = try await repository.loadHistory(userID: userID, end: end, days: days)
            guard ownsOverview(generation, scope: scope, days: days) else { return }
            overview = loaded
            if loaded.readProvenance?.isCached == true {
                errorMessage = "Couldn't refresh History. Showing saved data."
            }
        } catch {
            guard ownsOverview(generation, scope: scope, days: days), !isCancellation(error) else { return }
            errorMessage = DashboardUserMessage.userMessage(for: error)
        }
    }

    func select(_ day: HistoryDay) async {
        if expandedDay == day.date { collapseDay(); return }
        collapseDay()
        expandedDay = day.date
        let generation = daySelectionGeneration
        let scope = dayScope(day.date)
        guard day.logged else { return }
        isExpandedLoading = true
        defer {
            if daySelectionGeneration == generation {
                isExpandedLoading = false
                if dayScope(day.date) != scope { collapseDay() }
            }
        }
        let cached = try? await repository.cachedToday(userID: userID, date: day.date)
        guard ownsDay(generation, date: day.date, scope: scope) else { return }
        if let cached { daySnapshot = cached.cachedCopy }
        do {
            let loaded = try await repository.loadToday(userID: userID, date: day.date)
            guard ownsDay(generation, date: day.date, scope: scope) else { return }
            daySnapshot = loaded
            if loaded.readProvenance?.isCached == true {
                expandedError = "Couldn't refresh this day. Showing saved data."
            }
        } catch {
            guard ownsDay(generation, date: day.date, scope: scope), !isCancellation(error) else { return }
            expandedError = DashboardUserMessage.userMessage(for: error)
        }
    }

    private func collapseDay() {
        daySelectionGeneration &+= 1
        expandedDay = nil
        daySnapshot = nil
        expandedError = nil
        isExpandedLoading = false
    }

    private func dayScope(_ date: Date) -> String {
        "\(TimeZone.autoupdatingCurrent.identifier):\(LocalFirstDashboardRepository.dayKey(date))"
    }

    private func ownsOverview(_ generation: Int, scope: String, days: Int) -> Bool {
        !Task.isCancelled && loadGeneration == generation && range.rawValue == days && dayScope(today) == scope
    }

    private func ownsDay(_ generation: Int, date: Date, scope: String) -> Bool {
        !Task.isCancelled && daySelectionGeneration == generation && expandedDay == date && dayScope(date) == scope
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

import Combine
import Foundation
import SwiftUI

// Issue #94 — History: the V1 ledger tab (bars vs goal, day drill-down,
// weight trend); issue #136 — ledger reads supersede by generation.

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
    @Published var range: RangeDays = .seven
    @Published private(set) var expandedDay: Date?
    @Published private(set) var daySnapshot: DashboardSnapshot?
    @Published private(set) var isExpandedLoading = false
    @Published private(set) var expandedError: String?

    /// Issue #136 — in-flight read generations (see `load()`/`select()`).
    private var loadGeneration = 0
    private var daySelectionGeneration = 0

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
        // Issue #136 — reads are superseded, never gated: a cancelled read
        // that never surfaces CancellationError used to leave isLoading stuck.
        // Only the newest read may publish or clear the loading flag.
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        do {
            let loaded = try await repository.loadHistory(
                userID: userID, end: today, days: range.rawValue
            )
            guard loadGeneration == generation else { return }
            overview = loaded
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = DashboardUserMessage.userMessage(for: error)
        }
    }

    func select(_ day: HistoryDay) async {
        if expandedDay == day.date {
            // Collapse supersedes any in-flight read for the day card.
            daySelectionGeneration &+= 1
            expandedDay = nil
            daySnapshot = nil
            expandedError = nil
            isExpandedLoading = false
            return
        }
        expandedDay = day.date
        daySnapshot = nil
        expandedError = nil
        daySelectionGeneration &+= 1
        let generation = daySelectionGeneration
        guard day.logged else { isExpandedLoading = false; return }
        isExpandedLoading = true
        defer {
            if daySelectionGeneration == generation {
                isExpandedLoading = false
            }
        }
        do {
            let loaded = try await repository.loadToday(userID: userID, date: day.date)
            guard daySelectionGeneration == generation else { return }
            daySnapshot = loaded
        } catch is CancellationError {
            return
        } catch {
            guard daySelectionGeneration == generation else { return }
            expandedError = DashboardUserMessage.userMessage(for: error)
        }
    }
}

struct HistoryView: View {
    @StateObject private var viewModel: HistoryViewModel
    /// Issue #105: page-turn revisit bump — returning to History reloads.
    private let reloadKey: Int

    init(repository: any DashboardRepository, userID: UUID, reloadKey: Int = 0) {
        self.reloadKey = reloadKey
        _viewModel = StateObject(
            wrappedValue: HistoryViewModel(repository: repository, userID: userID)
        )
    }

    var body: some View {
        JournalPage(date: viewModel.today, bottomInset: 56) {
            HistoryHeader(viewModel: viewModel)
                .padding(.bottom, 6)
            if let errorMessage = viewModel.errorMessage, viewModel.overview == nil {
                HistoryErrorNotice(message: errorMessage) {
                    Task { await viewModel.load() }
                }
            } else if viewModel.isLoading && viewModel.overview == nil {
                HistoryLedgerSkeleton()
            } else {
                historyContent
            }
        }
        .task(id: reloadKey) {
            HistoryViewModel.observer?(.activated, .history, nil)
            await viewModel.load()
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let goalText = viewModel.goal?.calorieTargetKcal {
                ProvenanceLabel(
                    text: "against your target of \(MorselFormat.number(goalText)) kcal · tap a day to open it"
                )
            } else {
                ProvenanceLabel(text: "your daily target is not set yet · tap a day to open it")
            }
            RangePicker(viewModel: viewModel)
                .padding(.top, 12)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.chartDays) { day in
                    HistoryBarRow(viewModel: viewModel, day: day)
                    if viewModel.expandedDay == day.date {
                        DayDrillDown(viewModel: viewModel)
                    }
                    if day.id != viewModel.chartDays.last?.id {
                        Rectangle()
                            .fill(Color.morselInkLine.opacity(0.3))
                            .frame(height: 0.5)
                    }
                }
            }
            .padding(.vertical, 4)

            JournalRule()
                .padding(.vertical, 12)
            HistorySummaryStrip(viewModel: viewModel)

            JournalRule()
                .padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "Days vs goal", detail: "kcal delta · tap to open")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.visibleListDays) { day in
                        HistoryListRow(viewModel: viewModel, day: day)
                    }
                    if !viewModel.listRevealHiddenDays.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.showsAllListDays = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("see all")
                                    .font(.morselFootnote)
                                    .foregroundStyle(Color.morselForest)
                                Text("→")
                                    .font(.morselFootnote)
                                    .foregroundStyle(Color.morselForest)
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("See all days")
                    }
                }
            }

            if let trend = viewModel.overview?.weightTrend, !trend.isEmpty {
                JournalRule()
                    .padding(.vertical, 12)
                V1WeightTrendView(
                    points: trend,
                    delta: viewModel.weightDeltaOverRange,
                    isThirtyDay: viewModel.range == .thirty,
                    today: viewModel.today
                )
            }
        }
    }
}

// MARK: - History header

private struct HistoryHeader: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("History")
                    .font(.morselFootnote)
                    .foregroundStyle(Color.morselInkThree)
                Spacer()
                Text("last \(viewModel.range.rawValue) days")
                    .font(.morselFootnote)
                    .foregroundStyle(Color.morselInkThree)
            }
            Text("Calories vs goal")
                .font(Font.morselHand(size: 28))
                .foregroundStyle(Color.morselInk)
                .padding(.top, 2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RangePicker: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        HStack(spacing: 24) {
            ForEach(HistoryViewModel.RangeDays.allCases) { option in
                Button {
                    viewModel.range = option
                    Task { await viewModel.load() }
                } label: {
                    VStack(spacing: 3) {
                        Text(option.title)
                            .font(Font.morselHand(size: 20))
                            .foregroundStyle(viewModel.range == option ? Color.morselForest : Color.morselInkTwo)
                        MarkerStroke(
                            color: viewModel.range == option ? Color.morselForest : .clear,
                            width: option == .seven ? 34 : 42,
                            height: 4
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.range == option ? .isSelected : [])
            }
            Spacer()
        }
    }
}

extension Color {
    /// V1 hatch ink: Paper ink hatch, Night cream hatch (role hatch token).
    static let morselHatch = Color.morselJournal(paper: "#2A261F", night: "#FFF7E8")
}

struct HistoryErrorNotice: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.morselBody)
                .foregroundStyle(Color.morselOver)
            Button("Try again", action: retry)
                .buttonStyle(MorselGhostButtonStyle())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.morselAccentSoft, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.morselInkLine.opacity(0.5), lineWidth: 1)
        }
    }
}

// MARK: - Issue #136 paper loading skeletons (ledger + day card)

/// Ledger loading skeleton: range pills + bar rows (issue #136, no spinner).
struct HistoryLedgerSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 24) {
                PaperSkeletonBlock(width: 54, height: 16, radius: 4)
                PaperSkeletonBlock(width: 66, height: 16, radius: 4)
                Spacer(minLength: 0)
            }
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 10) {
                    PaperSkeletonBlock(width: 42, height: 9)
                    PaperSkeletonFill(height: 13)
                    PaperSkeletonBlock(width: 84, height: 9)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading the ledger")
    }
}

/// Day-card drill-down loading skeleton (paper blocks, no spinner).
struct DayDrillDownSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PaperSkeletonBlock(width: 148, height: 20, radius: 4)
                Spacer(minLength: 4)
                PaperSkeletonBlock(width: 44, height: 44, radius: 7)
            }
            PaperSkeletonFill(height: 9)
            PaperSkeletonFill(height: 9)
            PaperSkeletonFill(height: 9)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading the day")
    }
}

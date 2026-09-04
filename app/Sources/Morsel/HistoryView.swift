import Combine
import Foundation
import SwiftUI

// Issue #94 — History: the V1 ledger tab. 7/30-day bars against the daily
// goal (soft ±50 kcal tolerance), summary strip, day drill-down accordion,
// and the real-dated weight trend. Every delta is eaten minus goal; the only
// over mark is the hatched overshoot.

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

    /// History list shows newest first (the "Days vs goal" list) while the
    /// bars render ascending (ledger order) — see `chartDays`.
    @Published var showsAllListDays = false

    let repository: any DashboardRepository
    let userID: UUID
    private let dateProvider: () -> Date

    init(
        repository: any DashboardRepository,
        userID: UUID,
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.userID = userID
        self.dateProvider = dateProvider
    }

    var today: Date { dateProvider() }

    var goal: DashboardGoal? { overview?.goal }

    /// Ledger (ascending, oldest first) — the bar chart order.
    var chartDays: [HistoryDay] {
        guard let overview else { return [] }
        let start = DashboardMath.startOfUTCDay(today)
        let windowStart = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -(range.rawValue - 1), to: start) ?? start
        return overview.days.filter { $0.date >= windowStart && $0.date <= start }
    }

    /// Newest-first rows for the "Days vs goal" list; 7-day mode caps the
    /// collapsed list at four rows behind "see all".
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
        let todayStart = DashboardMath.startOfUTCDay(today)
        return chartDays.contains { DashboardMath.startOfUTCDay($0.date) == todayStart && $0.logged }
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
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            overview = try await repository.loadHistory(userID: userID, end: today, days: range.rawValue)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
        }
    }

    func select(_ day: HistoryDay) async {
        if expandedDay == day.date {
            expandedDay = nil
            daySnapshot = nil
            expandedError = nil
            return
        }
        expandedDay = day.date
        daySnapshot = nil
        expandedError = nil
        guard day.logged else { return }
        isExpandedLoading = true
        defer { isExpandedLoading = false }
        do {
            daySnapshot = try await repository.loadToday(userID: userID, date: day.date)
        } catch is CancellationError {
            return
        } catch {
            expandedError = DashboardUserMessage.userMessage(for: error)
        }
    }
}

struct HistoryView: View {
    @StateObject private var viewModel: HistoryViewModel
    /// Issue #105: page-turn revisit bump — the persistent pager keeps pages
    /// mounted, so returning to History reloads when this key changes.
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
                HStack(spacing: 10) {
                    ProgressView().tint(Color.morselAccent)
                    Text("Reading the ledger…").font(.morselBody).foregroundStyle(Color.morselInkTwo)
                }
            } else {
                historyContent
            }
        }
        .task(id: reloadKey) {
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

import SwiftUI

struct HistoryView: View {
    @StateObject private var viewModel: HistoryViewModel
    /// Issue #105: page-turn revisit bump — returning to History reloads.
    private let reloadKey: Int
    private let diary: JournalCalendarModel?
    private let selectedDate: Date
    private let openDay: (Date) -> Void
    @State private var showingCalendar = false

    init(repository: any DashboardRepository, userID: UUID, reloadKey: Int = 0,
         diary: JournalCalendarModel? = nil, selectedDate: Date = Date(),
         openDay: @escaping (Date) -> Void = { _ in }) {
        self.reloadKey = reloadKey
        self.diary = diary
        self.selectedDate = selectedDate
        self.openDay = openDay
        _viewModel = StateObject(
            wrappedValue: HistoryViewModel(repository: repository, userID: userID)
        )
    }

    var body: some View {
        JournalPage(date: viewModel.today, bottomInset: 56) {
            HistoryHeader(viewModel: viewModel)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) {
                JournalHistoryRangePicker(viewModel: viewModel, showingCalendar: $showingCalendar,
                                          offersCalendar: diary != nil)
                    .padding(.vertical, 10)
                if showingCalendar, let diary {
                    JournalCalendarView(model: diary, selectedDate: selectedDate, openDay: openDay)
                        .task { await diary.showMonth(containing: selectedDate) }
                } else if let errorMessage = viewModel.errorMessage, viewModel.overview == nil {
                    HistoryErrorNotice(message: errorMessage) {
                        Task { await viewModel.load() }
                    }
                } else if viewModel.isLoading && viewModel.overview == nil {
                    HistoryLedgerSkeleton()
                } else {
                    historyContent
                }
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
            if let errorMessage = viewModel.errorMessage {
                HistoryErrorNotice(message: errorMessage) { Task { await viewModel.load() } }
            } else if viewModel.overview?.readProvenance?.isCached == true {
                ProvenanceLabel(text: viewModel.isLoading
                                ? "Showing saved History · refreshing…" : "Showing saved History")
            }
            if let goalText = viewModel.goal?.calorieTargetKcal {
                ProvenanceLabel(
                    text: "against your target of \(MorselFormat.number(goalText)) kcal · tap a day to open it"
                )
            } else {
                ProvenanceLabel(text: "your daily target is not set yet · tap a day to open it")
            }

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

            if let trend = viewModel.overview?.weightTrend {
                JournalRule()
                    .padding(.vertical, 12)
                V1WeightTrendView(
                    points: trend,
                    delta: viewModel.weightDeltaOverRange,
                    isThirtyDay: viewModel.range == .thirty,
                    today: viewModel.today,
                    foodDays: viewModel.chartDays.map(WeightDeltaDay.init(day:))
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
                .padding(.vertical, -2)
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

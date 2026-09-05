import SwiftUI

// Issue #94 — History ledger chrome (bar rows, summary, list rows, drill-down).
// Kept out of HistoryView.swift so the shipped files stay inside the repo lint
// budgets.

// MARK: - Bar rows

struct HistoryBarRow: View {
    @ObservedObject var viewModel: HistoryViewModel
    let day: HistoryDay

    private var isToday: Bool {
        DashboardMath.startOfLocalDay(day.date) == DashboardMath.startOfLocalDay(viewModel.today)
    }

    var body: some View {
        Button {
            Task { await viewModel.select(day) }
        } label: {
            HStack(spacing: 10) {
                if isToday {
                    Text("today")
                        .font(Font.morselHand(size: 18))
                        .foregroundStyle(Color.morselForest)
                        .frame(width: labelWidth, alignment: .leading)
                } else if viewModel.range == .seven {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.morselSerif(size: 13).weight(.semibold))
                        .foregroundStyle(Color.morselInkTwo)
                        .frame(width: labelWidth, alignment: .leading)
                } else if showsCompactLabel(for: day) {
                    Text(day.date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.morselData)
                        .foregroundStyle(Color.morselInkThree)
                        .frame(width: labelWidth, alignment: .leading)
                } else {
                    Color.clear.frame(width: labelWidth, height: 8)
                }
                bar
                valueColumn
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayAccessibilityText)
    }

    private var labelWidth: CGFloat { viewModel.range == .thirty ? 46 : 42 }

    private func showsCompactLabel(for day: HistoryDay) -> Bool {
        guard let overview = viewModel.overview, let first = overview.days.first,
              let last = overview.days.last else { return false }
        let calendar = Calendar(identifier: .gregorian)
        let dayOfMonth = calendar.component(.day, from: day.date)
        return dayOfMonth % 5 == 1 || day.date == first.date || day.date == last.date
    }

    private var dayAccessibilityText: String {
        if day.logged {
            return "\(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))), "
                + "\(MorselFormat.number(day.eatenKcal)) kilocalories"
        }
        return "\(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))), no meals logged"
    }

    @ViewBuilder
    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if let goal = viewModel.goal {
                    goalBand(at: goal.calorieTargetKcal, width: proxy.size.width)
                }
                if day.logged {
                    washBar(in: proxy.size.width)
                }
            }
        }
        .frame(height: viewModel.range == .thirty ? 12 : 18)
    }

    /// Faint ±50 kcal tolerance wash around the goal line + inkline tick.
    private func goalBand(at goal: Double, width: CGFloat) -> some View {
        let scale = chartScale
        let bandFraction = CGFloat(min(100.0 / scale, 0.12))
        let centerFraction = CGFloat(goal / scale)
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.morselSurfaceTwo)
                .frame(width: width * bandFraction)
                .offset(x: width * min(max(centerFraction - bandFraction / 2, 0), 1))
            Rectangle()
                .fill(Color.morselInkLine)
                .frame(width: 1.2)
                .offset(x: width * min(max(centerFraction - 0.6 / width, 0), 1) + 0.6)
        }
    }

    /// Green ink bar (ghosted for today) with the orange overshoot hatch.
    private func washBar(in width: CGFloat) -> some View {
        let scale = chartScale
        let fraction = min(max(day.eatenKcal / scale, 0), 1)
        let goalKcal = viewModel.goal?.calorieTargetKcal
        let goalFraction = goalKcal.map { min(max($0 / scale, 0), 1) } ?? 0
        let overFraction = goalKcal.map { goal in
            min(max((day.eatenKcal - goal) / scale, 0), fraction - goalFraction)
        } ?? 0
        return ZStack(alignment: .leading) {
            WashEdgeShape(fillFraction: 1)
                .fill(Color.morselLeaf.opacity(isToday ? 0.45 : 1))
                .frame(width: width * fraction)
            if overFraction > 0 {
                HatchedOverlay()
                    .frame(width: width * overFraction)
                    .offset(x: width * goalFraction)
            }
        }
    }

    /// Bars scale to the window's max eaten value vs the goal (goal stays
    /// inside the frame for over days by scaling to the larger of the two).
    private var chartScale: Double {
        let eatenMax = viewModel.chartDays.map(\.eatenKcal).max() ?? 0
        let goal = viewModel.goal?.calorieTargetKcal ?? 0
        return max(eatenMax * 1.05, goal * 1.05, 1)
    }

    @ViewBuilder
    private var valueColumn: some View {
        if viewModel.range == .thirty {
            Color.clear.frame(width: 84, height: 8)
        } else if day.logged {
            VStack(alignment: .trailing, spacing: 0) {
                Text(MorselFormat.number(day.eatenKcal))
                    .font(.morselDataMedium)
                    .foregroundStyle(isToday ? Color.morselLeaf : Color.morselInk)
                if isToday {
                    Text("· partial")
                        .font(.morselFootnote)
                        .foregroundStyle(Color.morselInkThree)
                }
            }
            .frame(width: 84, alignment: .trailing)
        } else {
            Text("no log")
                .font(.morselFootnote)
                .foregroundStyle(Color.morselInkThree)
                .frame(width: 84, alignment: .trailing)
        }
    }
}

/// Diagonal ink hatch for the over-goal segment (paper: ink on over wash;
/// night: cream hatch — the semantic mark, per the V1 contract).
private struct HatchedOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.morselExcessWash
                Path { path in
                    let step: CGFloat = 5
                    var strikeX: CGFloat = -proxy.size.height
                    while strikeX < proxy.size.width {
                        path.move(to: CGPoint(x: strikeX, y: proxy.size.height))
                        path.addLine(to: CGPoint(x: strikeX + proxy.size.height, y: 0))
                        strikeX += step
                    }
                }
                .stroke(Color.morselHatch, style: StrokeStyle(lineWidth: 1.1))
                .clipShape(Rectangle())
            }
        }
    }
}

// MARK: - Summary strip

struct HistorySummaryStrip: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        HStack(alignment: .top) {
            SummaryMetric(value: viewModel.averageKcal.map(MorselFormat.number) ?? "—", label: "avg kcal")
            SummaryMetric(value: "\(viewModel.daysOver)", label: viewModel.daysOver == 1 ? "day over" : "days over")
            SummaryMetric(value: "\(viewModel.daysLogged)", label: "logged")
            Spacer()
        }
        .padding(.bottom, 10)
        HStack {
            Text("\(viewModel.streak)-day logging streak")
                .font(.morselData)
                .foregroundStyle(Color.morselInkTwo)
            Spacer()
            if viewModel.isTodayLogged {
                VStack(spacing: 2) {
                    Text("today · partial")
                        .font(Font.morselHand(size: 16))
                        .foregroundStyle(Color.morselForest)
                    MarkerStroke(color: Color.morselForest, width: 66, height: 3)
                }
            }
        }
    }
}

struct SummaryMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.morselGauge)
                .monospacedDigit()
                .foregroundStyle(Color.morselInk)
            Text(label)
                .font(.morselFootnote)
                .foregroundStyle(Color.morselInkTwo)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Days vs goal list row

struct HistoryListRow: View {
    @ObservedObject var viewModel: HistoryViewModel
    let day: HistoryDay

    private var isToday: Bool {
        DashboardMath.startOfLocalDay(day.date) == DashboardMath.startOfLocalDay(viewModel.today)
    }

    private var delta: Double? {
        DashboardMath.eatenMinusGoal(eaten: day.eatenKcal, goal: viewModel.goal?.calorieTargetKcal)
    }

    private var comparison: DayComparison {
        DashboardMath.comparison(delta: delta)
    }

    var body: some View {
        Button {
            Task { await viewModel.select(day) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(dayTitle)
                    .font(isToday ? Font.morselHand(size: 17) : .morselSerif(size: 14).weight(.semibold))
                    .foregroundStyle(isToday ? Color.morselForest : Color.morselInk)
                    .frame(width: 92, alignment: .leading)
                if day.logged {
                    Spacer(minLength: 4)
                    Text(
                        "\(MorselFormat.number(day.eatenKcal)) vs "
                            + "\(MorselFormat.number(viewModel.goal?.calorieTargetKcal))"
                    )
                        .font(.morselData)
                        .foregroundStyle(Color.morselInkThree)
                    Spacer(minLength: 4)
                    Text(deltaText)
                        .font(.morselDataMedium)
                        .foregroundStyle(Color.morselInk)
                    Text(comparison.word)
                        .font(.morselFootnote)
                        .foregroundStyle(comparisonColor)
                } else {
                    Spacer()
                    Text("no meals logged")
                        .font(.morselFootnote)
                        .foregroundStyle(Color.morselInkThree)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityLabel("\(dayTitle), \(deltaText) \(comparison.word)")
    }

    private var dayTitle: String {
        if isToday { return "Today" }
        return day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var deltaText: String {
        guard let delta else { return "" }
        return delta > 0 ? "+\(MorselFormat.number(delta))" : "\(MorselFormat.number(delta))"
    }

    private var comparisonColor: Color {
        switch comparison {
        case .under: return Color.morselLeaf
        case .onTarget: return Color.morselForest
        case .over: return Color.morselOver
        }
    }
}

// MARK: - Day drill-down (accordion)

struct DayDrillDown: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = viewModel.daySnapshot {
                dayContent(snapshot)
            } else if viewModel.isExpandedLoading {
                HStack(spacing: 8) {
                    ProgressView().tint(Color.morselAccent)
                    Text("Opening the day…").font(.morselBody).foregroundStyle(Color.morselInkTwo)
                }
            } else if let expandedError = viewModel.expandedError {
                Text(expandedError)
                    .font(.morselBody)
                    .foregroundStyle(Color.morselOver)
            } else {
                Text("No meals logged for this date.")
                    .font(.morselBody)
                    .foregroundStyle(Color.morselInkTwo)
            }
        }
        .padding(12)
        .background(Color.morselSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.morselInkLine.opacity(0.4), lineWidth: 1)
        }
        .padding(.vertical, 6)
    }

    private func dayContent(_ snapshot: DashboardSnapshot) -> some View {
        let totals = DashboardMath.totals(for: snapshot.meals)
        let goal = snapshot.goal?.calorieTargetKcal
        return VStack(alignment: .leading, spacing: 12) {
            Text(snapshot.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(Font.morselHand(size: 24))
                .foregroundStyle(Color.morselInk)
            HStack(spacing: 6) {
                Text("\(MorselFormat.number(totals.caloriesKcal)) kcal")
                    .font(.morselDataMedium)
                    .foregroundStyle(Color.morselInk)
                if let goal {
                    Text("vs \(MorselFormat.number(goal))")
                        .font(.morselData)
                        .foregroundStyle(Color.morselInkThree)
                    let delta = DashboardMath.eatenMinusGoal(eaten: totals.caloriesKcal, goal: goal) ?? 0
                    Text(delta > 0 ? "· +\(MorselFormat.number(delta)) over" : "· on target")
                        .font(.morselData)
                        .foregroundStyle(delta > 0 ? Color.morselOver : Color.morselForest)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                MacroWashStrip(
                    label: "Protein", value: totals.proteinG,
                    target: snapshot.goal?.proteinG, wash: .morselProteinWash
                )
                MacroWashStrip(
                    label: "Carbs", value: totals.carbsG,
                    target: snapshot.goal?.carbsG, wash: .morselCarbsWash
                )
                MacroWashStrip(
                    label: "Fat", value: totals.fatG,
                    target: snapshot.goal?.fatG, wash: .morselFatWash
                )
            }
            JournalRule()
            ForEach(snapshot.meals.flatMap(\.items)) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .font(.morselBodyStrong)
                        .foregroundStyle(Color.morselInk)
                    Spacer()
                    Text(MorselFormat.number(item.caloriesKcal))
                        .font(.morselDataMedium)
                        .foregroundStyle(Color.morselInk)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

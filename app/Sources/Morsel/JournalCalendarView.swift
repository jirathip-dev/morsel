import SwiftUI

/// V1: hand-tab months and a frameless Monday-first grid. Shared by History and Today's sheet.
struct JournalCalendarView: View {
    @ObservedObject var model: JournalCalendarModel
    let selectedDate: Date
    let openDay: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                monthButton(.backward, symbol: "chevron.left", label: "Previous month")
                ForEach(visibleMonths, id: \.self) { month in
                    Button {
                        Task { await model.showMonth(containing: month) }
                    } label: {
                        VStack(spacing: 2) {
                            Text(month.formatted(.dateTime.month(.abbreviated)).lowercased())
                                .font(.morselHand(size: 22))
                            MarkerStroke(color: month == model.month ? .morselForest : .clear,
                                         width: 34, height: 4)
                        }
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.morselInk)
                    .accessibilityLabel(month.formatted(.dateTime.month(.wide).year()))
                    .accessibilityAddTraits(month == model.month ? .isSelected : [])
                }
                Spacer(minLength: 0)
                monthButton(.forward, symbol: "chevron.right", label: "Next month")
            }
            HStack {
                Text("all history")
                Spacer()
                Text(model.month.formatted(.dateTime.year()))
            }
            .font(.morselFootnote)
            .foregroundStyle(Color.morselInkTwo)
            if let first = model.firstLoggedDay {
                Text("\(first.formatted(date: .abbreviated, time: .omitted)) – " +
                     model.today.formatted(date: .abbreviated, time: .omitted))
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
            }
            JournalRule()
            if let error = model.errorMessage {
                HistoryErrorNotice(message: error) { Task { await model.load() } }
            }
            if model.isLoading && !model.hasIndex {
                HistoryLedgerSkeleton()
            } else {
                grid
                HStack(spacing: 10) {
                    legend("under", .morselForest)
                    legend("on target", .morselCarbsWash)
                    legend("over", .morselOver)
                }
                Text("dots = logged days")
                    .font(.morselHand(size: 20))
                    .foregroundStyle(Color.morselInkTwo)
            }
        }
        .accessibilityIdentifier("diary-calendar")
    }

    // A two-tab window avoids a nested horizontal scroller fighting tab flips.
    private var visibleMonths: [Date] {
        let months = model.months
        let index = months.firstIndex(of: model.month) ?? 0
        return Array(months.dropFirst(max(0, index - 1)).prefix(2))
    }

    private func neighboringMonth(_ direction: PageTurnDirection) -> Date? {
        guard let date = model.calendar.date(byAdding: .month, value: direction == .forward ? 1 : -1,
                                             to: model.month), model.months.contains(date) else { return nil }
        return date
    }

    private func monthButton(_ direction: PageTurnDirection, symbol: String, label: String) -> some View {
        Button {
            if let date = neighboringMonth(direction) { Task { await model.showMonth(containing: date) } }
        } label: { Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Color.morselInk)
            .disabled(neighboringMonth(direction) == nil).accessibilityLabel(label)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
            ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, label in
                Text(label).font(.morselFootnote).foregroundStyle(Color.morselInkTwo)
                    .accessibilityHidden(true)
            }
            ForEach(Array(model.cells.enumerated()), id: \.offset) { _, date in
                if let date { cell(date) } else { Color.clear.frame(height: 44).accessibilityHidden(true) }
            }
        }
    }

    private func cell(_ date: Date) -> some View {
        let logged = model.loggedDates.contains(date)
        return Button { openDay(date) } label: {
            VStack(spacing: 3) {
                Text(date.formatted(.dateTime.day())).font(.morselData)
                Circle().fill(dotColor(date)).frame(width: 6, height: 6).opacity(logged ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(date == selectedDate ? Color.morselAccentSoft : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.morselInk)
        .disabled(!model.allows(date))
        .opacity(model.allows(date) ? 1 : 0.35)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(logged ? "Meals logged" : "No meals")
        .accessibilityAddTraits(date == selectedDate ? .isSelected : [])
        .accessibilityIdentifier("diary-date-" + date.formatted(.iso8601.year().month().day().dateSeparator(.dash)))
    }

    private func dotColor(_ date: Date) -> Color {
        guard let day = model.days.first(where: { $0.date == date }), let target = model.goal?.calorieTargetKcal else {
            return .morselForest
        }
        switch DashboardMath.comparison(delta: day.eatenKcal - target) {
        case .under: return .morselForest
        case .onTarget: return .morselCarbsWash
        case .over: return .morselOver
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.morselFootnote).foregroundStyle(Color.morselInkTwo)
        }
    }
}

struct JournalCalendarSheet: View {
    @ObservedObject var model: JournalCalendarModel
    let selectedDate: Date
    let openDay: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        JournalPage(date: selectedDate, bottomInset: 24) {
            HStack {
                Text("Calendar").font(.morselDisplay)
                Spacer()
                Button { dismiss() } label: {
                    Text("Done").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            JournalCalendarView(model: model, selectedDate: selectedDate) { date in
                openDay(date)
                dismiss()
            }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.morselBackground)
        .task { await model.showMonth(containing: selectedDate) }
    }
}

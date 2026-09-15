import SwiftUI

struct JournalHistoryRangePicker: View {
    @ObservedObject var viewModel: HistoryViewModel
    @Binding var showingCalendar: Bool
    let offersCalendar: Bool

    var body: some View {
        HStack(spacing: 24) {
            ForEach(HistoryViewModel.RangeDays.allCases) { option in
                Button {
                    showingCalendar = false
                    viewModel.range = option
                    Task { await viewModel.load() }
                } label: {
                    tab(option.title, selected: !showingCalendar && viewModel.range == option,
                        width: option == .seven ? 34 : 42)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(!showingCalendar && viewModel.range == option ? .isSelected : [])
            }
            if offersCalendar {
                Button { showingCalendar = true } label: {
                    tab("calendar", selected: showingCalendar, width: 64)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(showingCalendar ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private func tab(_ title: String, selected: Bool, width: CGFloat) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.morselHand(size: 20))
                .foregroundStyle(selected ? Color.morselForest : Color.morselInkTwo)
            MarkerStroke(color: selected ? .morselForest : .clear, width: width, height: 4)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

enum JournalDiaryDraft {
    static func date(on day: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date {
        let time = calendar.dateComponents([.hour, .minute], from: now)
        return calendar.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }
    static func title(for date: Date) -> String {
        Calendar.autoupdatingCurrent.isDateInToday(date) ? "Add meal" : "Add to " + label(date)
    }
    static func saveTitle(for date: Date) -> String {
        Calendar.autoupdatingCurrent.isDateInToday(date) ? "Save meal" : "Save to " + label(date)
    }
    private static func label(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated)) }
}

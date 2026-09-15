import Charts
import SwiftUI

/// Option 1: a signed food-record band below the unchanged weight trace.
struct WeightDeltaBand: View {
    let timeline: WeightDeltaTimeline
    let points: [WeightTrendPoint]
    let today: Date
    @State private var selectedDate: Date?

    private var selectedDay: WeightDeltaDay? {
        timeline.days.first { $0.date == selectedDate } ?? timeline.days.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Eaten − food target · kcal")
                Spacer(minLength: 4)
                Text("±\(MorselFormat.number(timeline.deltaLimit))")
            }
            .font(Font.morselMono(size: 10))
            .foregroundStyle(Color.morselInkTwo)
            chart
            VStack(alignment: .leading, spacing: 3) {
                Text("? food target unavailable · × no food log")
                Text("· food log unavailable · ○ zero delta")
                Text("+ above / − below food target")
            }
            .font(.morselFootnote)
            .foregroundStyle(Color.morselInkTwo)
            if let day = selectedDay {
                receipt(day)
            }
            Text("Logged means at least one meal, not complete intake. These records do not explain weight changes.")
                .font(.morselFootnote)
                .foregroundStyle(Color.morselInkTwo)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var chart: some View {
        Chart {
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Color.morselInkLine)
            ForEach(timeline.days) { day in
                if let delta = day.deltaKcal, delta != 0 {
                    BarMark(x: .value("Date", day.date), yStart: .value("Zero", 0),
                            yEnd: .value("Eaten minus food target", delta),
                            width: .fixed(timeline.days.count > 7 ? 5 : 12))
                        .foregroundStyle(Color.morselInkThree)
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(day.status)
                } else {
                    PointMark(x: .value("Date", day.date), y: .value("Status", 0))
                        .symbol {
                            Text(day.symbol)
                                .font(Font.morselMono(size: 12))
                                .foregroundStyle(Color.morselInk)
                                .padding(2)
                                .background(Color.morselBackground)
                        }
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(day.status)
                }
            }
        }
        .chartXScale(domain: timeline.domain, range: .plotDimension(startPadding: 8, endPadding: 8))
        .chartYScale(domain: -timeline.deltaLimit...timeline.deltaLimit)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: timeline.axisDates) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.day().month(.abbreviated)))
                            .font(Font.morselMono(size: 9))
                            .foregroundStyle(Color.morselInkThree)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).onTapGesture { location in
                    guard let frame = proxy.plotFrame else { return }
                    let position = location.x - geometry[frame].minX
                    guard let date: Date = proxy.value(atX: position) else { return }
                    selectedDate = timeline.days.min {
                        abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                    }?.date
                }
            }
        }
        .frame(height: 120)
        .accessibilityLabel("Per-day food-target comparison")
    }

    private func receipt(_ day: WeightDeltaDay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            JournalRule()
            HStack {
                Text(day.date.formatted(.dateTime.day().month(.wide)))
                    .font(Font.morselHand(size: 24))
                if DashboardMath.startOfLocalDay(day.date) == DashboardMath.startOfLocalDay(today) {
                    Text("partial day").font(.morselFootnote)
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(timeline.days) { row in
                        Button(row.date.formatted(date: .abbreviated, time: .omitted)) {
                            selectedDate = row.date
                        }
                    }
                } label: {
                    Image(systemName: "calendar")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .tint(Color.morselInk)
                .accessibilityLabel("Select comparison date")
            }
            let weight = points.filter {
                DashboardMath.startOfLocalDay($0.date) == DashboardMath.startOfLocalDay(day.date)
            }.max { $0.date < $1.date }
            let weightText = weight.map { "\($0.kilograms.formatted(.number.precision(.fractionLength(1)))) kg" }
            valueRow("Weight", weightText ?? "no weight recorded")
            valueRow("Food recorded", day.eatenKcal.map { "\(MorselFormat.number($0)) kcal" } ?? day.status)
            valueRow("Food target", day.foodTargetKcal.map { "\(MorselFormat.number($0)) kcal" } ?? "unavailable")
            valueRow("Eaten − target", day.status)
            if let source = day.targetSource {
                Text(source).font(.morselFootnote)
            }
        }
        .foregroundStyle(Color.morselInk)
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.morselBody)
            Spacer(minLength: 8)
            Text(value).font(Font.morselMono(size: 11)).multilineTextAlignment(.trailing)
        }
    }
}

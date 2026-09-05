import Charts
import SwiftUI

// Issue #94 — the V1 weight trend (History page): forest ink line + dots over
// a soft sage area, mono axes, and the "kg · delta over 30 days" caption.
// Lives on History, not Today (C2 — Today keeps calories/macros/log only).

struct V1WeightTrendView: View {
    let points: [WeightTrendPoint]
    let delta: Double?
    let isThirtyDay: Bool
    let today: Date

    private var sortedPoints: [WeightTrendPoint] {
        points.sorted { $0.date < $1.date }
    }

    private var domain: ClosedRange<Double> {
        let values = points.map(\.kilograms)
        guard let minValue = values.min(), let maxValue = values.max(), minValue.isFinite, maxValue.isFinite else {
            return 70...75
        }
        let lower = floor(minValue - 0.5)
        let upper = ceil(maxValue + 0.5)
        return max(lower, 20)...min(upper, 300)
    }

    private var xAxisDateValues: [Date] {
        let dates = sortedPoints.map(\.date)
        guard let last = dates.last, dates.count > 1 else { return dates }
        let step = max(1, dates.count / 3)
        return stride(from: 0, to: dates.count, by: step).map { dates[$0] } + [last]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
                title: "Weight trend",
                detail: detailText
            )
            Chart {
                ForEach(sortedPoints) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Baseline", domain.lowerBound),
                        yEnd: .value("Weight", point.kilograms)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.morselLeafSoft.opacity(0.55), Color.morselLeafSoft.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Weight", point.kilograms)
                    )
                    .foregroundStyle(Color.morselForest)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Weight", point.kilograms)
                    )
                    .foregroundStyle(Color.morselForest)
                    .symbolSize(26)
                }
            }
            .chartYScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: xAxisDateValues) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.morselInkLine.opacity(0.4))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.day().month(.abbreviated)))
                                .font(Font.morselMono(size: 9))
                                .foregroundStyle(Color.morselInkThree)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.morselInkLine.opacity(0.3))
                    AxisValueLabel {
                        Text("")
                    }
                }
            }
            .chartYAxisLabel("kg")
                .font(Font.morselMono(size: 9))
                .foregroundStyle(Color.morselInkThree)
            .frame(height: 130)
            .accessibilityLabel("Weight trend line")
            if isThirtyDay {
                VStack(alignment: .leading, spacing: 2) {
                    Text("the line, not one day")
                        .font(.morselFootnote)
                        .foregroundStyle(Color.morselInkTwo)
                    MarkerStroke(color: Color.morselInkLine.opacity(0.8), width: 130, height: 2)
                }
            }
        }
    }

    /// Issue #112 — the caption shows the LATEST value whenever ≥1 sample
    /// exists (a lone or duplicate pair must never read as a fake delta):
    /// e.g. "kg · 72.4 today · −0.6 over 30 days".
    private var detailText: String {
        guard let latest = sortedPoints.last else { return "kg" }
        var text = "kg · \(MorselFormat.number(latest.kilograms))"
        if DashboardMath.startOfUTCDay(latest.date) == DashboardMath.startOfUTCDay(today) {
            text += " today"
        }
        if let delta {
            text += " · \(MorselFormat.number(delta)) over 30 days"
        }
        return text
    }
}

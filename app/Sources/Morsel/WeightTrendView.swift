import Charts
import SwiftUI

struct WeightTrendView: View {
    let points: [WeightTrendPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Weight trend", detail: "kg")
            Chart(points) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Weight", point.kilograms)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.morselUnder, .morselOn],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Weight", point.kilograms)
                )
                .foregroundStyle(Color.morselOn)
            }
            .chartYAxisLabel("kg")
            .frame(height: 130)
            .accessibilityLabel("Weight trend")
        }
    }
}

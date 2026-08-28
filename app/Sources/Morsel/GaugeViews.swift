import SwiftUI

struct GaugeCard: View {
    let totals: DashboardTotals
    let goal: DashboardGoal?

    private var status: GoalStatus {
        DashboardMath.goalStatus(eaten: totals.caloriesKcal, goal: goal?.calorieTargetKcal)
    }

    private var progress: Double {
        DashboardMath.goalProgress(eaten: totals.caloriesKcal, goal: goal?.calorieTargetKcal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                CalorieRing(progress: progress, status: status, eaten: totals.caloriesKcal)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Eaten · Goal")
                        .font(.morselLabel)
                        .foregroundStyle(Color.morselInkThree)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(MorselFormat.number(totals.caloriesKcal))
                            .font(.morselTitle)
                            .foregroundStyle(Color.morselEnergy)
                        Text("/")
                            .font(.morselData)
                            .foregroundStyle(Color.morselInkThree)
                        Text(MorselFormat.number(goal?.calorieTargetKcal))
                            .font(.morselData)
                            .foregroundStyle(Color.morselInk)
                        Text("kcal")
                            .font(.morselData)
                            .foregroundStyle(Color.morselInkTwo)
                    }
                    GoalSummary(status: status, eaten: totals.caloriesKcal, goal: goal?.calorieTargetKcal)
                    if let goal {
                        Text("source: \(goal.source.rawValue)")
                            .font(.morselData)
                            .foregroundStyle(Color.morselInkTwo)
                    }
                }
                Spacer(minLength: 0)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(status.tint)

            VStack(alignment: .leading, spacing: 12) {
                MacroRow(label: "Protein", value: totals.proteinG, target: goal?.proteinG, gradient: .morselProtein)
                MacroRow(label: "Carbs", value: totals.carbsG, target: goal?.carbsG, gradient: .morselCarbs)
                MacroRow(label: "Fat", value: totals.fatG, target: goal?.fatG, gradient: .morselFat)
            }
        }
        .padding(16)
        .background(LinearGradient.morselCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.morselLine, lineWidth: 1)
        }
    }
}

private struct CalorieRing: View {
    let progress: Double
    let status: GoalStatus
    let eaten: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.morselSurfaceTwo, lineWidth: 7)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(status.tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(MorselFormat.number(eaten))
                    .font(.morselGauge)
                    .foregroundStyle(Color.morselInk)
                Text("kcal")
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
            }
        }
        .frame(width: 94, height: 94)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Calories eaten")
        .accessibilityValue("\(MorselFormat.number(eaten)) kilocalories")
    }
}

private struct GoalSummary: View {
    let status: GoalStatus
    let eaten: Double
    let goal: Double?

    var body: some View {
        Group {
            if let goal, status == .over {
                Text("\(MorselFormat.number(eaten - goal)) kcal over")
            } else if let goal {
                Text("\(MorselFormat.number(max(goal - eaten, 0))) kcal left")
            } else {
                Text("Goal unavailable")
            }
        }
        .font(.morselData)
        .foregroundStyle(status.tint)
    }
}

private struct MacroRow: View {
    let label: String
    let value: Double
    let target: Double?
    let gradient: LinearGradient

    private var progress: Double {
        guard let target, target > 0 else {
            return 0
        }
        return min(max(value / target, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInk)
                Spacer()
                Text("\(MorselFormat.number(value)) / \(MorselFormat.number(target))g")
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.morselSurfaceTwo)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(gradient)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 4)
        }
    }
}

extension GoalStatus {
    var tint: Color {
        switch self {
        case .onTrack:
            return .morselAccent
        case .nearGoal:
            return .morselEnergy
        case .over:
            return .morselOver
        case .unavailable:
            return .morselInkThree
        }
    }
}

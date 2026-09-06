import SwiftUI

// Issue #152 — History day drill-down (accordion rows with named-menu set
// grouping). Moved out of HistoryLedgerViews.swift so shipped files stay
// inside the repo lint budgets.

// MARK: - Day drill-down (accordion)

struct DayDrillDown: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = viewModel.daySnapshot {
                dayContent(snapshot)
            } else if viewModel.isExpandedLoading {
                DayDrillDownSkeleton()
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

    private func dayCardHeader(_ snapshot: DashboardSnapshot) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(snapshot.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(Font.morselHand(size: 24))
                .foregroundStyle(Color.morselInk)
            Spacer(minLength: 4)
            // The day card shows the day's first meal photo (agent-logged or
            // in-app); the thumbnail pipeline is identical to Today's.
            if let imagePath = snapshot.meals.compactMap({ $0.imagePath }).first {
                MealThumbnailView(repository: viewModel.repository, userID: viewModel.userID, path: imagePath)
                    .frame(width: 44, height: 44)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.morselInkLine.opacity(0.6), lineWidth: 1)
                    }
            }
        }
    }

    private func dayContent(_ snapshot: DashboardSnapshot) -> some View {
        let totals = DashboardMath.totals(for: snapshot.meals)
        let goal = snapshot.goal?.calorieTargetKcal
        return VStack(alignment: .leading, spacing: 12) {
            dayCardHeader(snapshot)
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
            ForEach(snapshot.meals) { meal in
                ForEach(MealDisplayGrouping.rows(from: meal.items), id: \.rowID) { row in
                    if case let .set(name, _, members) = row {
                        MenuSetHeader(name: name)
                            .padding(.top, 2)
                        ForEach(members, id: \.itemID) { member in
                            historyItemRow(member)
                                .padding(.leading, 14)
                        }
                    } else if case let .loose(item) = row {
                        historyItemRow(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyItemRow(_ item: MealItem) -> some View {
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

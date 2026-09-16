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
                if let error = viewModel.expandedError {
                    ProvenanceLabel(text: error)
                } else if snapshot.readProvenance?.isCached == true {
                    ProvenanceLabel(text: viewModel.isExpandedLoading
                                    ? "Showing saved meals · refreshing…" : "Showing saved meals")
                }
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
            // Issue #199/#223 — the shared row artwork slot: this day summary
            // row is always illustrated (the day's first logged meal), never a
            // stored photo.
            MealArtworkSlot(
                items: snapshot.meals.first(where: { !$0.items.isEmpty })?.items ?? []
            )
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

    /// Issue #223/#229 — the expanded day's food rows carry the same
    /// always-illustrated Variant A row as Today (56pt A artwork, name +
    /// portion, kcal column with the chevron, macro line and hairline); the
    /// stored meal photo stays in detail/edit, never in a row.
    private func historyItemRow(_ item: MealItem) -> some View {
        JournalFoodRow(item: item)
    }

}

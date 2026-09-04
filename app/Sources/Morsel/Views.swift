import SwiftUI

// Issue #94 — Today: V1 journal hero (inked ring + wash macro strips),
// honest states, and the journaled meal log. Net-energy display paths are
// gone (eat-vs-goal is the only readout).

struct TodayView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let showSettings: () -> Void
    /// Issue #105 AC3: Add Meal opens as a journal page route (the shell
    /// presents it in-flow) — never a `.sheet` from Today.
    let addMeal: () -> Void

    @State private var editingItem: MealItem?
    @State private var mealToDelete: MealRecord?

    var body: some View {
        JournalPage(date: viewModel.snapshot?.date ?? Date()) {
            TodayHeader(
                date: viewModel.snapshot?.date ?? Date(),
                showSettings: showSettings,
                addMeal: addMeal
            )
            .padding(.bottom, 18)

            if let errorMessage = viewModel.errorMessage, viewModel.snapshot == nil {
                ErrorNotice(message: errorMessage) {
                    Task { await viewModel.load() }
                }
            } else if viewModel.isLoading && viewModel.snapshot == nil {
                LoadingNotice()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.morselBody)
                            .foregroundStyle(Color.morselOver)
                            .padding(.bottom, 10)
                    }
                    JournalHeroView(viewModel: viewModel)
                    JournalRule()
                        .padding(.vertical, 18)
                    TodayLogSection(
                        viewModel: viewModel,
                        onAddMeal: addMeal,
                        onEdit: { editingItem = $0 },
                        onDelete: { mealToDelete = $0 }
                    )
                    if !viewModel.reviewItems.isEmpty {
                        NeedsReviewSection(items: viewModel.reviewItems) { item in
                            editingItem = item
                        }
                    }
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .sheet(item: $editingItem) { item in
            MealItemEditSheet(item: item) { update in
                let didUpdate = await viewModel.updateMealItem(update)
                if didUpdate {
                    editingItem = nil
                }
                return didUpdate
            }
        }
        .confirmationDialog(
            "Delete this meal?",
            isPresented: Binding(
                get: { mealToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        mealToDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let meal = mealToDelete {
                Button("Delete \(meal.mealType.title)", role: .destructive) {
                    mealToDelete = nil
                    Task { _ = await viewModel.deleteMeal(meal.mealLogID) }
                }
            }
            Button("Cancel", role: .cancel) { mealToDelete = nil }
        } message: {
            if let meal = mealToDelete {
                Text("This removes \(meal.items.count) items and recalculates today's totals.")
            }
        }
    }
}

// MARK: - Header (date line, hand title, add tab + toothed cog)

private struct TodayHeader: View {
    let date: Date
    let showSettings: () -> Void
    let addMeal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.morselFootnote)
                    .foregroundStyle(Color.morselInkThree)
                Text("Today")
                    .font(.morselDisplay)
                    .foregroundStyle(Color.morselInk)
            }
            Spacer(minLength: 8)
            Button(action: showSettings) {
                ToothedCog()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .padding(.top, 2)
            Button(action: addMeal) {
                AddMealTab()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add meal")
            .accessibilityHint("Opens the Add Meal journal page")
        }
    }
}

// MARK: - Hero: ring + readout + macro wash strips + activity margin note

private struct JournalHeroView: View {
    @ObservedObject var viewModel: DashboardViewModel

    private var goal: DashboardGoal? { viewModel.snapshot?.goal }

    private var status: GoalStatus {
        DashboardMath.goalStatus(eaten: viewModel.totals.caloriesKcal, goal: goal?.calorieTargetKcal)
    }

    private var remaining: String? {
        guard let goal else { return nil }
        let delta = viewModel.totals.caloriesKcal - goal.calorieTargetKcal
        if delta > 0 {
            return "\(MorselFormat.number(delta)) kcal over"
        }
        return "\(MorselFormat.number(-delta)) kcal left"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                JournalCalorieRing(
                    eaten: viewModel.totals.caloriesKcal,
                    goal: goal?.calorieTargetKcal,
                    status: status
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text("Eaten · Goal")
                        .morselSectionLabel()
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(MorselFormat.number(viewModel.totals.caloriesKcal))
                            .font(.morselHero)
                            .foregroundStyle(Color.morselInk)
                            .monospacedDigit()
                        if let goal {
                            Text("/ \(MorselFormat.number(goal.calorieTargetKcal)) kcal")
                                .font(.morselBody)
                                .foregroundStyle(Color.morselInkTwo)
                        }
                    }
                    if let remaining {
                        Text(remaining)
                            .font(.morselTitle)
                            .foregroundStyle(Color.morselInk)
                    } else {
                        Text("Goal unavailable")
                            .font(.morselTitle)
                            .foregroundStyle(Color.morselInkThree)
                    }
                    if let goal {
                        ProvenanceLabel(text: "source: \(goal.source.rawValue)")
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 11) {
                MacroWashStrip(
                    label: "Protein",
                    value: viewModel.totals.proteinG,
                    target: goal?.proteinG,
                    wash: .morselProteinWash
                )
                MacroWashStrip(
                    label: "Carbs",
                    value: viewModel.totals.carbsG,
                    target: goal?.carbsG,
                    wash: .morselCarbsWash
                )
                MacroWashStrip(
                    label: "Fat",
                    value: viewModel.totals.fatG,
                    target: goal?.fatG,
                    wash: .morselFatWash
                )
            }

            if viewModel.snapshot?.activeEnergyBurned ?? 0 > 0 {
                // V1 locked semantics: activity is a margin note; it never
                // feeds the eaten readout.
                VStack(alignment: .leading, spacing: 2) {
                    Text("moved \(MorselFormat.number(viewModel.snapshot?.activeEnergyBurned)) kcal today")
                        .font(.morselFootnote)
                        .foregroundStyle(Color.morselInkTwo)
                    MarkerStroke(color: Color.morselInkLine.opacity(0.8), width: 150, height: 2)
                }
            }
        }
    }
}

private struct LoadingNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Color.morselAccent)
            Text("Reading today's log…")
                .font(.morselBody)
                .foregroundStyle(Color.morselInkTwo)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ErrorNotice: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.morselBody)
                .foregroundStyle(Color.morselOver)
            Button("Try again", action: retry)
                .buttonStyle(MorselGhostButtonStyle())
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

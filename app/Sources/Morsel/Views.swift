import SwiftUI

// Issue #94 — Today: V1 journal hero (inked ring + wash macro strips),
// honest states, and the journaled meal log. Net-energy display paths are
// gone (eat-vs-goal is the only readout).

struct TodayView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.trainingFuelHosted) private var trainingFuelHosted
    /// Issue #176 — Today's presentations (item edit, meal delete) are owned
    /// by the shell, OUTSIDE this transient page: a turn can pose, hide or
    /// replace the page while a presentation opens, and settlement must
    /// neither dismiss, duplicate nor orphan it. The page only REQUESTS;
    /// the shell presents.
    /// Issue #176 — the shell owns the instance (a turn must never dismiss,
    /// duplicate or orphan a presentation); previews take a throwaway one.
    @ObservedObject var presentations = JournalPresentationModel()
    let showSettings: () -> Void
    /// Issue #105 AC3: Add Meal opens as a journal page route (the shell
    /// presents it in-flow) — never a `.sheet` from Today.
    let addMeal: () -> Void

    var body: some View {
        if trainingFuelHosted {
            page
        } else {
            // Standalone previews/tests use the same owner as the app shell.
            page.trainingFuel(viewModel: viewModel)
        }
    }

    private var page: some View {
        JournalPage(date: viewModel.selectedDate) {
            TodayHeader(
                date: viewModel.selectedDate,
                showSettings: showSettings,
                addMeal: addMeal
            )
            .padding(.bottom, 18)

            if let errorMessage = viewModel.errorMessage, viewModel.snapshot == nil {
                VStack(spacing: 20) {
                    ErrorNotice(message: errorMessage) {
                        Task { await viewModel.load() }
                    }
                    if viewModel.selectedDate == viewModel.today { TrainingDayUnavailableRow() }
                }
            } else if viewModel.isLoading && viewModel.snapshot == nil {
                VStack(spacing: 20) {
                    if viewModel.selectedDate == viewModel.today { TrainingDayUnavailableRow() }
                    TodaySkeleton()
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // Issue #258 — a day read that failed (cached copy on
                    // screen) or degraded (meals whose items could not be
                    // read) says so above the values it is showing.
                    if viewModel.isShowingCachedDay {
                        CachedDayNotice(lastLoadedAt: viewModel.lastLoadedAt) {
                            Task { await viewModel.load() }
                        }
                    }
                    if viewModel.incompleteMealCount > 0 {
                        IncompleteDayNotice(mealCount: viewModel.incompleteMealCount) {
                            Task { await viewModel.load() }
                        }
                    }
                    if let errorMessage = viewModel.errorMessage {
                        Text("Showing the last loaded diary; refresh failed.")
                            .font(.morselBody).foregroundStyle(Color.morselInkTwo)
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
                        onEdit: { presentations.requestEdit($0) },
                        onDelete: { presentations.requestDelete($0) },
                        confirmationFor: { presentations.savedConfirmation(for: $0) }
                    )
                }
            }
        }
        .task(id: viewModel.selectedDate) {
            await viewModel.load()
        }
    }
}

private struct TrainingDayUnavailableRow: View {
    @EnvironmentObject private var trainingFuel: TrainingFuelModel

    var body: some View { TrainingFuelSection(model: trainingFuel) }
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
                Text(Calendar.autoupdatingCurrent.isDateInToday(date)
                     ? "Today" : date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
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

    @EnvironmentObject private var trainingFuel: TrainingFuelModel

    private var isToday: Bool { viewModel.selectedDate == viewModel.today }
    private var goal: DashboardGoal? { isToday && trainingFuel.isCurrentDay ? trainingFuel.baseline : nil }
    private var target: Double? { isToday ? trainingFuel.target : nil }

    private var status: GoalStatus {
        DashboardMath.goalStatus(eaten: viewModel.totals.caloriesKcal, goal: target)
    }

    private var hasCalories: Bool {
        guard let snapshot = viewModel.snapshot else { return false }
        return snapshot.meals.allSatisfy { !$0.items.isEmpty && $0.items.allSatisfy { $0.caloriesKcal != nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                JournalCalorieRing(
                    eaten: viewModel.totals.caloriesKcal,
                    goal: hasCalories ? target : nil,
                    status: status
                )
                .accessibilityHidden(!hasCalories)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Eaten")
                        .morselSectionLabel()
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(hasCalories ? MorselFormat.number(viewModel.totals.caloriesKcal) : "—")
                            .font(.morselNumber(size: 32, weight: 500))
                            .foregroundStyle(Color.morselInk)
                            .monospacedDigit()
                        if hasCalories {
                            Text("kcal")
                                .font(.morselBody)
                                .foregroundStyle(Color.morselInkTwo)
                        }
                    }
                    Text(hasCalories ? "From your logged food" : "Meal nutrition incomplete")
                        .font(.morselTitle)
                        .foregroundStyle(Color.morselInkTwo)
                }
                Spacer(minLength: 0)
            }

            if isToday {
                TrainingFuelSection(model: trainingFuel)
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
        }
    }
}

// MARK: - Issue #136 paper loading skeletons (soft placeholder blocks; no spinners)

/// Fixed-width paper placeholder block (loading shimmer stand-in).
struct PaperSkeletonBlock: View {
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = 3

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Color.morselInkLine.opacity(0.18))
            .frame(width: width, height: height)
    }
}

/// Flexible-width paper placeholder block (fills the proposed width).
struct PaperSkeletonFill: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.morselInkLine.opacity(0.18))
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

/// Today's first-load skeleton: journal hero + macro wash + log rows in the
/// same vertical rhythm as the loaded page (issue #136 — no text spinner).
private struct TodaySkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                RoundedRectangle(cornerRadius: 46)
                    .fill(Color.morselInkLine.opacity(0.12))
                    .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 9) {
                    PaperSkeletonBlock(width: 74, height: 9, radius: 3)
                    PaperSkeletonBlock(width: 132, height: 24, radius: 4)
                    PaperSkeletonBlock(width: 96, height: 9, radius: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    PaperSkeletonFill(height: 9)
                }
            }
            .padding(.top, 20)
            JournalRule()
                .padding(.vertical, 18)
            TodayLogSkeletonRows()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading today's journal")
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
                .padding(.vertical, -2)
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

// MARK: - Issue #136 paper delete confirmation (no system alert chrome)

/// Red-flagged destructive action: the over token surface carries the page
/// cream label in Paper; Night resolves the pair inverted (cream surface,
/// ink label). Both pairs hold the strict 4.5:1 text contract.
struct MorselDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.morselBodyStrong)
            .foregroundStyle(Color.morselBackground)
            .frame(minHeight: 40)
            .padding(.horizontal, 14)
            .background(Color.morselOver, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .padding(.vertical, 2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Themed paper confirmation sheet: cream surface + ink copy, ghost Cancel
/// and a red-flagged destructive action. Cancel dismisses without deleting;
/// only the destructive button runs `onDelete`.
struct DeleteMealPaperDialog: View {
    let meal: MealRecord
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete this meal?")
                .font(.morselTitle)
                .foregroundStyle(Color.morselInk)
            Text("This removes \(meal.items.count) items and recalculates today's totals.")
                .font(.morselBody)
                .foregroundStyle(Color.morselInkTwo)
            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(MorselGhostButtonStyle())
                    .padding(.vertical, -2)
                    .frame(maxWidth: .infinity)
                Button("Delete \(meal.mealType.title)") {
                    onDelete()
                    dismiss()
                }
                .buttonStyle(MorselDestructiveButtonStyle())
                .padding(.vertical, -2)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.morselSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.morselInkLine.opacity(0.7), lineWidth: 1)
        }
        .padding(8)
        .presentationDetents([.height(232)])
        .presentationBackground(Color.clear)
        .presentationDragIndicator(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Delete this meal?")
    }
}

// MARK: - Issue #176 presentation ownership (shell-owned, page-requested)

/// Today's presentations are owned by the signed-in shell, never by the page
/// that requests them: a turn can pose, hide or replace a page while a
/// presentation opens, and settlement must neither dismiss, duplicate nor
/// orphan what the user asked for. At most ONE presentation exists at a time:
/// a request arriving while one is open (or opening) changes nothing.
/// The shell anchors the presentations it owns, so they outlive any page turn
/// or settle. The sheets keep their shipped chrome and behavior: the #136
/// themed paper confirmation (Cancel dismisses without deleting; only the
/// red-flagged action deletes) and the #105 paper edit page.
extension View {
    func journalPresentations(_ presentations: JournalPresentationModel,
                              viewModel: DashboardViewModel) -> some View {
        self
            .sheet(item: presentations.editBinding) { item in
                MealItemEditSheet(item: item) { update in
                    let didUpdate = await viewModel.updateMealItem(update)
                    if didUpdate {
                        presentations.finishEdit()
                        presentations.noteSaved(update.itemID)
                    }
                    return didUpdate
                }
            }
            .sheet(item: presentations.deleteBinding) { meal in
                DeleteMealPaperDialog(meal: meal) {
                    Task { _ = await viewModel.deleteMeal(meal.mealLogID) }
                }
            }
    }
}

import SwiftUI

// Issue #94 — Today: V1 journal hero (inked ring + wash macro strips),
// honest states, and the journaled meal log. Net-energy display paths are
// gone (eat-vs-goal is the only readout).

struct TodayView: View {
    @ObservedObject var viewModel: DashboardViewModel
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
                TodaySkeleton()
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
                        onEdit: { presentations.requestEdit($0) },
                        onDelete: { presentations.requestDelete($0) }
                    )
                    if !viewModel.reviewItems.isEmpty {
                        NeedsReviewSection(items: viewModel.reviewItems) { item in
                            presentations.requestEdit(item)
                        }
                    }
                }
            }
        }
        .task {
            await viewModel.load()
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

            if let margin = ActiveEnergyMarginNote.line(
                totalKcal: viewModel.snapshot?.activeEnergyBurned ?? 0,
                lastImport: viewModel.lastHealthImportDate
            ) {
                // V1 locked semantics: activity is a margin note; it never
                // feeds the eaten readout (issue #113 C adds the Apple Health
                // source + last-import time to the same note).
                VStack(alignment: .leading, spacing: 2) {
                    Text(margin)
                        .font(.morselFootnote)
                        .foregroundStyle(Color.morselInkTwo)
                    MarkerStroke(color: Color.morselInkLine.opacity(0.8), width: 150, height: 2)
                }
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
private struct MorselDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.morselBodyStrong)
            .foregroundStyle(Color.morselBackground)
            .frame(minHeight: 40)
            .padding(.horizontal, 14)
            .background(Color.morselOver, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
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
                    .frame(maxWidth: .infinity)
                Button("Delete \(meal.mealType.title)") {
                    onDelete()
                    dismiss()
                }
                .buttonStyle(MorselDestructiveButtonStyle())
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
@MainActor
final class JournalPresentationModel: ObservableObject {
    @Published private(set) var editingItem: MealItem?
    @Published private(set) var mealToDelete: MealRecord?

    var isPresenting: Bool { editingItem != nil || mealToDelete != nil }

    func requestEdit(_ item: MealItem) {
        guard !isPresenting else { return }
        editingItem = item
    }

    func requestDelete(_ meal: MealRecord) {
        guard !isPresenting else { return }
        mealToDelete = meal
    }

    /// A successful edit save closes the sheet the way its Cancel does.
    func finishEdit() { editingItem = nil }

    /// `.sheet(item:)` writes its dismissal through these bindings.
    var editBinding: Binding<MealItem?> {
        Binding(get: { self.editingItem }, set: { self.editingItem = $0 })
    }
    var deleteBinding: Binding<MealRecord?> {
        Binding(get: { self.mealToDelete }, set: { self.mealToDelete = $0 })
    }
}

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
                    if didUpdate { presentations.finishEdit() }
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

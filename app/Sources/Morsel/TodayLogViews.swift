import SwiftUI

// Issue #94 — Today's meal log (journal rows). Kept out of Views.swift so the
// shipped files stay inside the repo lint budgets.

// MARK: - Today's log

/// Issue #177 — the empty log's photo prompt: the full-width text action keeps
/// its footnote voice and marker stroke inside a ≥44pt interactive target.
struct PhotoPromptActionLabel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("send a photo of your next meal")
                .font(.morselFootnote)
                .foregroundStyle(Color.morselInkTwo)
            MarkerStroke(color: Color.morselForest, width: 190, height: 2)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

struct TodayLogSection: View {
    @ObservedObject var viewModel: DashboardViewModel
    let onAddMeal: () -> Void
    let onEdit: (MealItem) -> Void
    let onDelete: (MealRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(
                title: "Today's log",
                detail: "\(viewModel.snapshot?.meals.count ?? 0) meals · "
                    + "\(MorselFormat.number(viewModel.totals.caloriesKcal)) kcal"
            )
            if viewModel.mealGroups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No meals logged for this date.")
                        .font(.morselBodyStrong)
                        .foregroundStyle(Color.morselInk)
                    Button(action: onAddMeal) {
                        PhotoPromptActionLabel()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a meal")
                }
                .padding(.vertical, 8)
            } else {
                ForEach(viewModel.mealGroups) { group in
                    MealGroupView(
                        group: group,
                        onEdit: onEdit,
                        onDelete: onDelete
                    )
                    if group.id != viewModel.mealGroups.last?.id {
                        JournalRule()
                            .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

struct MealGroupView: View {
    let group: MealGroup
    let onEdit: (MealItem) -> Void
    let onDelete: (MealRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                // Issue #199/#223 — the shared row artwork slot: this summary
                // row is always illustrated (food study, category fallback or
                // the neutral eating sign), never the meal's stored photo.
                MealArtworkSlot(
                    items: group.meals.first(where: { !$0.items.isEmpty })?.items ?? []
                )
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(group.type.title)
                            .font(.morselTitle)
                            .foregroundStyle(Color.morselInk)
                        if let firstMealTime = group.firstMealTime {
                            Text(firstMealTime.formatted(date: .omitted, time: .shortened))
                                .font(.morselData)
                                .foregroundStyle(Color.morselInkThree)
                        }
                        if group.meals.count == 1, let meal = group.meals.first {
                            MealSyncMarker(meal: meal)
                        }
                    }
                    Text("\(MorselFormat.number(group.totalCalories)) kcal")
                        .font(.morselDataMedium)
                        .foregroundStyle(Color.morselInkTwo)
                }
                Spacer(minLength: 4)
                if group.meals.count == 1, let meal = group.meals.first {
                    Button {
                        onDelete(meal)
                    } label: {
                        InkStrikeX()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(meal.mealType.title) meal")
                }
            }
            .padding(.bottom, 4)

            ForEach(group.meals) { meal in
                if group.meals.count > 1 {
                    HStack {
                        Text(meal.eatenAt.formatted(date: .omitted, time: .shortened))
                            .font(.morselData)
                            .foregroundStyle(Color.morselInkThree)
                        MealSyncMarker(meal: meal)
                        Spacer()
                        Button {
                            onDelete(meal)
                        } label: {
                            InkStrikeX()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(meal.mealType.title) meal")
                    }
                    .padding(.vertical, 2)
                }
                let rows = MealDisplayGrouping.rows(from: meal.items)
                ForEach(rows, id: \.rowID) { row in
                    if case let .set(name, _, _) = row {
                        MenuSetHeader(name: name)
                            .padding(.top, 2)
                    }
                    ForEach(row.items, id: \.itemID) { item in
                        MealItemRow(item: item, onEdit: onEdit)
                    }
                    if row.rowID != rows.last?.rowID {
                        Rectangle()
                            .fill(Color.morselInkLine.opacity(0.35))
                            .frame(height: 0.5)
                            .padding(.leading, 0)
                    }
                }
            }
        }
    }
}

/// Issue #152 — a logged set's nested header inside a meal ('Name (set)').
/// Rendered above the set's snapshot items; loose items beside it stay flat.
struct MenuSetHeader: View {
    let name: String

    var body: some View {
        Text(MealDisplayGrouping.setLabel(name: name))
            .font(.morselBodyStrong)
            .foregroundStyle(Color.morselForest)
            .padding(.vertical, 2)
    }
}

/// Issue #227 — the food row carries only what the log needs: the always-on
/// illustration (#223), the food's name, its portion/macros and its kcal. The
/// confidence/provenance line and the verify action are retired from the row
/// (confidence no longer reserves a line, so no spacing is left behind);
/// tapping anywhere on the row opens the food sheet, which owns source,
/// confidence and agent notes.
struct MealItemRow: View {
    let item: MealItem
    let onEdit: (MealItem) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Issue #223 — every food item row is always illustrated: the
            // item's approved study, its category fallback, or the neutral
            // eating sign. A stored meal photo never appears in a row.
            MealArtworkSlot(items: [item])
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.morselTitle)
                    .foregroundStyle(Color.morselInk)
                Text(
                    "\(MorselFormat.portion(quantity: item.quantity, unit: item.unit))"
                        + " · \(MorselFormat.macroLine(for: item))"
                )
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 0) {
                Text(MorselFormat.number(item.caloriesKcal))
                    .font(Font.morselMonoMedium(size: 15))
                    .monospacedDigit()
                    .foregroundStyle(Color.morselInk)
                Text("kcal")
                    .font(.morselFootnote)
                    .foregroundStyle(Color.morselInkThree)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            onEdit(item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(
            "\(MorselFormat.number(item.caloriesKcal)) kilocalories"
        )
        .accessibilityHint("Opens the correction sheet")
    }
}

// MARK: - Sync marker (issue #106)

/// Honest `pending sync` / `needs attention` journal marker for rows that
/// left the local outbox but have not yet been reconciled with the
/// authoritative server state.
struct MealSyncMarker: View {
    let meal: MealRecord

    var body: some View {
        if let copy = meal.syncState.rowCopy {
            Text(copy)
                .font(.morselFootnote)
                .foregroundStyle(
                    meal.syncState == .needsAttention ? Color.morselOver : Color.morselForest
                )
        }
    }
}

// MARK: - Issue #136 Today log skeleton rows (paper placeholders, no spinner)

/// Journal log-row placeholders used by Today's first-load skeleton: a
/// section line plus thumbnail + text rows in the loaded layout's rhythm.
struct TodayLogSkeletonRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaperSkeletonBlock(width: 96, height: 11, radius: 3)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.morselInkLine.opacity(0.12))
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            PaperSkeletonBlock(width: 132, height: 9, radius: 3)
                            PaperSkeletonBlock(width: 76, height: 8, radius: 3)
                        }
                        Spacer(minLength: 0)
                        PaperSkeletonBlock(width: 46, height: 12, radius: 3)
                    }
                }
            }
        }
    }
}

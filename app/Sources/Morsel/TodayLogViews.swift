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
    /// Issue #229 — the saved-edit confirmation shown inside the row that was
    /// just saved (nil for every other row).
    var confirmationFor: (UUID) -> String? = { _ in nil }

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
                        onDelete: onDelete,
                        confirmationFor: confirmationFor
                    )
                }
            }
        }
    }
}

struct MealGroupView: View {
    let group: MealGroup
    let onEdit: (MealItem) -> Void
    let onDelete: (MealRecord) -> Void
    var confirmationFor: (UUID) -> String? = { _ in nil }

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
                                .font(.morselValue)
                                .foregroundStyle(Color.morselInkThree)
                        }
                        if group.meals.count == 1, let meal = group.meals.first {
                            MealSyncMarker(meal: meal)
                        }
                    }
                    Text("\(MorselFormat.number(group.totalCalories)) kcal")
                        .font(.morselValueMedium)
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
                            .font(.morselValue)
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
                // Issue #229 — the rows stack at the design's own pitch: each
                // row carries its Variant A hairline, so no inter-row spacing
                // is added here (the meal group's spacing stays for the
                // header/summary gaps around the list).
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.rowID) { row in
                        if case let .set(name, _, _) = row {
                            MenuSetHeader(name: name)
                                .padding(.top, 2)
                        }
                        ForEach(row.items, id: \.itemID) { item in
                            MealItemRow(
                                item: item,
                                onEdit: onEdit,
                                confirmation: confirmationFor(item.itemID)
                            )
                        }
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
///
/// Issue #229 — the row body is the approved Variant A row (56pt artwork,
/// 18pt/500 name with its portion beneath, right-aligned kcal column with the
/// Garamond chevron, the macro line and a `1px` line hairline), and it is a
/// Button like the design's `.row` so the press state (`translateY(-1px)`,
/// 100ms) exists — the design disables it under Reduce Motion. Navigation,
/// page turns and gesture mechanics are untouched.
struct MealItemRow: View {
    let item: MealItem
    let onEdit: (MealItem) -> Void
    /// The saved-edit confirmation line (nil unless this row just saved).
    var confirmation: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            onEdit(item)
        } label: {
            JournalFoodRow(item: item, confirmation: confirmation)
        }
        .buttonStyle(JournalRowButtonStyle(reduceMotion: reduceMotion))
        .contentShape(Rectangle())
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

// MARK: - Issue #258 honest day-read states

extension DashboardViewModel {
    /// Meals whose item rows could not be read on this load: the day is
    /// incomplete, never empty, and the notice below says so.
    var incompleteMealCount: Int {
        snapshot?.meals.filter { $0.itemsRead?.isIncomplete == true }.count ?? 0
    }
}

/// Issue #258 — the day on screen is the cached copy after a refresh failed:
/// it stays visible but is labelled as cached, with the last successful load
/// time and a retry, so it is never presented as current.
struct CachedDayNotice: View {
    let lastLoadedAt: Date?
    let retry: () -> Void

    var body: some View {
        DayReadNotice(
            identifier: "today-cached-notice",
            title: lastLoadedAt.map {
                "Cached — last updated \($0.formatted(date: .omitted, time: .shortened))"
            } ?? "Offline — showing cached data",
            detail: "Couldn't refresh today's log. The values below are the last saved copy.",
            retry: retry
        )
    }
}

/// Issue #258 — the fresh read degraded: some meals' items could not be read.
/// The day renders with what is known and says what is missing, so a partial
/// read is never shown as "nothing logged".
struct IncompleteDayNotice: View {
    let mealCount: Int
    let retry: () -> Void

    var body: some View {
        DayReadNotice(
            identifier: "today-incomplete-notice",
            title: mealCount == 1
                ? "1 meal couldn't be fully read"
                : "\(mealCount) meals couldn't be fully read",
            detail: "Some items are missing from today's log and the totals are short. "
                + "Nothing was deleted — try again.",
            retry: retry
        )
    }
}

/// The shared paper/night notice surface for both degraded day-read states.
private struct DayReadNotice: View {
    let identifier: String
    let title: String
    let detail: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.morselBodyStrong)
                .foregroundStyle(Color.morselInk)
            Text(detail)
                .font(.morselFootnote)
                .foregroundStyle(Color.morselInkTwo)
            Button("Try again", action: retry)
                .buttonStyle(MorselGhostButtonStyle())
                .padding(.vertical, -2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.morselAccentSoft, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.morselInkLine.opacity(0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .padding(.bottom, 12)
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

import SwiftUI

// Issue #94 — Today's meal log (journal rows). Kept out of Views.swift so the
// shipped files stay inside the repo lint budgets.

// MARK: - Today's log

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
                        VStack(alignment: .leading, spacing: 3) {
                            Text("send a photo of your next meal")
                                .font(.morselFootnote)
                                .foregroundStyle(Color.morselInkTwo)
                            MarkerStroke(color: Color.morselForest, width: 190, height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a meal")
                }
                .padding(.vertical, 8)
            } else {
                ForEach(viewModel.mealGroups) { group in
                    MealGroupView(
                        group: group,
                        repository: viewModel.repository,
                        userID: viewModel.userID,
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
    let repository: any DashboardRepository
    let userID: UUID
    let onEdit: (MealItem) -> Void
    let onDelete: (MealRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                if let imagePath = group.meals.compactMap({ $0.imagePath }).first {
                    MealThumbnailView(repository: repository, userID: userID, path: imagePath)
                        .frame(width: 44, height: 44)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.morselInkLine.opacity(0.6), lineWidth: 1)
                        }
                }
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
                            .frame(width: 34, height: 34)
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
                        Spacer()
                        Button {
                            onDelete(meal)
                        } label: {
                            InkStrikeX()
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(meal.mealType.title) meal")
                    }
                    .padding(.vertical, 2)
                }
                ForEach(meal.items) { item in
                    MealItemRow(item: item, onEdit: onEdit)
                    if item.id != meal.items.last?.id {
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

struct MealItemRow: View {
    let item: MealItem
    let onEdit: (MealItem) -> Void

    private var needsReview: Bool {
        item.needsReview
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
                HStack(spacing: 8) {
                    ProvenanceLabel(text: item.provenance.rawValue)
                    ConfidenceBox(value: item.confidence)
                    if needsReview {
                        Button {
                            onEdit(item)
                        } label: {
                            Text("verify")
                                .font(.morselData)
                                .foregroundStyle(Color.morselReview)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.morselAccentSoft, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Correct \(item.name)")
                    }
                }
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
        .padding(.horizontal, needsReview ? 8 : 0)
        .background(needsReview ? Color.morselAccentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
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

// MARK: - Needs review

struct NeedsReviewSection: View {
    let items: [MealItem]
    let onReview: (MealItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Needs review")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.morselBodyStrong)
                                .foregroundStyle(Color.morselInk)
                            Text("\(MorselFormat.confidence(item.confidence)) confidence")
                                .font(.morselData)
                                .foregroundStyle(Color.morselReview)
                            if let notes = item.notes, !notes.isEmpty {
                                Text("// agent: \(notes)")
                                    .font(.morselData)
                                    .foregroundStyle(Color.morselInkTwo)
                            }
                        }
                        Spacer(minLength: 4)
                        Button("Correct") {
                            onReview(item)
                        }
                        .buttonStyle(MorselGhostButtonStyle())
                    }
                }
            }
            .padding(12)
            .background(Color.morselAccentSoft, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.morselInkLine.opacity(0.5), lineWidth: 1)
            }
        }
    }
}

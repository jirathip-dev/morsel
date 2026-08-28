import SwiftUI

struct TodayView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var reviewItem: MealItem?
    @State private var isShowingAddMeal = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    TodayHeader(date: viewModel.snapshot?.date ?? Date())

                    if let errorMessage = viewModel.errorMessage, viewModel.snapshot == nil {
                        ErrorNotice(message: errorMessage) {
                            Task { await viewModel.load() }
                        }
                    } else if viewModel.isLoading && viewModel.snapshot == nil {
                        LoadingNotice()
                    } else {
                        GaugeCard(totals: viewModel.totals, goal: viewModel.snapshot?.goal)
                        TodayLogSection(viewModel: viewModel)
                        if !viewModel.reviewItems.isEmpty {
                            NeedsReviewSection(items: viewModel.reviewItems) { item in
                                reviewItem = item
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)
                .padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .background(Color.morselBackground.ignoresSafeArea())
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarBackground(.regularMaterial, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingAddMeal = true
                    } label: {
                        Label("Add meal", systemImage: "plus")
                    }
                    .buttonStyle(MorselGhostButtonStyle())
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .sheet(item: $reviewItem) { item in
            ReviewSheet(item: item) {
                if await viewModel.markReviewed(item.itemID) {
                    reviewItem = nil
                }
            }
        }
        .sheet(isPresented: $isShowingAddMeal) {
            AddMealView(viewModel: viewModel)
        }
    }
}

private struct TodayHeader: View {
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("morsel")
                .font(.morselData)
                .foregroundStyle(Color.morselAccent)
            Text("Today")
                .font(.morselDisplay)
                .foregroundStyle(Color.morselInk)
            Text(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.morselBody)
                .foregroundStyle(Color.morselInkTwo)
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.morselEnergySoft, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TodayLogSection: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                title: "Today's log",
                detail: "\(viewModel.snapshot?.meals.count ?? 0) meals · "
                    + "\(MorselFormat.number(viewModel.totals.caloriesKcal)) kcal"
            )
            if viewModel.mealGroups.isEmpty {
                Text("No meals logged for this date.")
                    .font(.morselBody)
                    .foregroundStyle(Color.morselInkTwo)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.mealGroups) { group in
                    MealGroupView(
                        group: group,
                        repository: viewModel.repository,
                        userID: viewModel.userID
                    )
                }
            }
        }
    }
}

private struct SectionHeading: View {
    let title: String
    let detail: String?

    init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .morselSectionLabel()
            Spacer()
            if let detail {
                Text(detail)
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
            }
        }
    }
}

private struct MealGroupView: View {
    let group: MealGroup
    let repository: any DashboardRepository
    let userID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if let imagePath = group.meals.compactMap({ $0.imagePath }).first {
                    MealThumbnailView(repository: repository, userID: userID, path: imagePath)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(group.type.title)
                        .font(.morselBodyStrong)
                        .foregroundStyle(Color.morselInk)
                    if let firstMealTime = group.firstMealTime {
                        Text(firstMealTime.formatted(date: .omitted, time: .shortened))
                            .font(.morselData)
                            .foregroundStyle(Color.morselInkThree)
                    }
                    Spacer()
                    Text("\(MorselFormat.number(group.totalCalories)) kcal")
                        .font(.morselData)
                        .foregroundStyle(Color.morselEnergy)
                }
            }
            .padding(.bottom, 4)

            ForEach(group.meals) { meal in
                ForEach(meal.items) { item in
                    MealItemRow(item: item, source: meal.source)
                    if item.id != meal.items.last?.id {
                        Divider()
                            .overlay(Color.morselLine)
                    }
                }
            }
        }
    }
}

private struct MealItemRow: View {
    let item: MealItem
    let source: MealSource

    private var badge: ConfidenceBadge {
        DashboardMath.confidenceBadge(for: item.confidence)
    }

    private var needsReview: Bool {
        badge.needsReview
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInk)
                Text(MorselFormat.portion(quantity: item.quantity, unit: item.unit))
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
                Text(MorselFormat.macroLine(for: item))
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
                HStack(spacing: 6) {
                    Text(source.rawValue)
                        .morselTag(foreground: Color.morselInkTwo, background: Color.morselSurface)
                    ConfidenceTag(badge: badge, value: item.confidence)
                    if needsReview {
                        Text("verify")
                            .morselTag(foreground: Color.morselLow, background: Color.morselEnergySoft)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(MorselFormat.number(item.caloriesKcal))
                    .font(.morselTitle)
                    .foregroundStyle(Color.morselEnergy)
                Text("kcal")
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, needsReview ? 8 : 0)
        .background(needsReview ? Color.morselEnergySoft : Color.morselBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ConfidenceTag: View {
    let badge: ConfidenceBadge
    let value: Double?

    var body: some View {
        switch badge {
        case .high:
            Text(MorselFormat.confidence(value))
                .morselTag(foreground: Color.morselAccent, background: Color.morselAccentSoft)
        case .low:
            Text(MorselFormat.confidence(value))
                .morselTag(foreground: Color.morselLow, background: Color.morselEnergySoft)
        case .missing:
            Text("confidence —")
                .morselTag(foreground: Color.morselLow, background: Color.morselEnergySoft)
        }
    }
}

private struct NeedsReviewSection: View {
    let items: [MealItem]
    let onReview: (MealItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Needs review")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.name)
                                .font(.morselBodyStrong)
                                .foregroundStyle(Color.morselInk)
                            Text("\(MorselFormat.confidence(item.confidence)) confidence")
                                .font(.morselData)
                                .foregroundStyle(Color.morselLow)
                            if let notes = item.notes, !notes.isEmpty {
                                Text("// agent: \(notes)")
                                    .font(.morselData)
                                    .foregroundStyle(Color.morselInkTwo)
                            }
                        }
                        Spacer(minLength: 4)
                        Button("Review") {
                            onReview(item)
                        }
                        .buttonStyle(MorselGhostButtonStyle())
                    }
                }
            }
            .padding(12)
            .background(Color.morselEnergySoft, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.morselLine, lineWidth: 1)
            }
        }
    }
}

private struct ReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: MealItem
    let onConfirm: () async -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.name)
                    .font(.morselDisplay)
                    .foregroundStyle(Color.morselInk)
                Text(MorselFormat.portion(quantity: item.quantity, unit: item.unit))
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
                Text(MorselFormat.macroLine(for: item))
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
                if let notes = item.notes, !notes.isEmpty {
                    Text("// agent: \(notes)")
                        .font(.morselData)
                        .foregroundStyle(Color.morselInkTwo)
                }
                Spacer()
                Button("Looks right") {
                    Task { await onConfirm() }
                }
                    .buttonStyle(MorselPrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .background(Color.morselBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.morselInkTwo)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

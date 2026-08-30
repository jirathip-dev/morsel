// swiftlint:disable line_length
import Combine
import SwiftUI

enum GoalDirection: String, CaseIterable, Sendable {
    case cut
    case maintain
    case bulk

    var title: String {
        switch self {
        case .cut: "Cut"
        case .maintain: "Maintain"
        case .bulk: "Bulk"
        }
    }

    var subtitle: String {
        switch self {
        case .cut: "steady loss"
        case .maintain: "hold steady"
        case .bulk: "steady gain"
        }
    }
}

@MainActor
final class GoalsEditorViewModel: ObservableObject {
    @Published private(set) var goal: DashboardGoal?
    @Published private(set) var sources: [String: GoalSource] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedDirection: GoalDirection?
    @Published private(set) var didSave = false
    @Published private(set) var todayCalories = 0.0
    @Published var calories = ""
    @Published var protein = ""
    @Published var carbs = ""
    @Published var fat = ""

    private let repository: any DashboardRepository
    private let userID: UUID
    private let onSaved: () async -> Void
    private let onSeeToday: () -> Void

    init(
        repository: any DashboardRepository,
        userID: UUID,
        onSaved: @escaping () async -> Void = {},
        onSeeToday: @escaping () -> Void = {}
    ) {
        self.repository = repository
        self.userID = userID
        self.onSaved = onSaved
        self.onSeeToday = onSeeToday
    }

    var isValid: Bool {
        [calories, protein, carbs, fat].allSatisfy { value in
            guard let number = Double(value) else { return false }
            return number.isFinite && number >= 0 && Self.isOnTenthGrid(number)
        }
    }

    var sourceIndicator: String {
        "writes source: \(sources.values.contains(.manual) ? "manual" : "computed")"
    }

    static func calorieConsequence(goal: Double, eaten: Double) -> String {
        let remaining = goal - eaten
        return remaining >= 0
            ? "\(MorselFormat.number(remaining)) KCAL LEFT"
            : "\(MorselFormat.number(abs(remaining))) KCAL OVER"
    }

    var whatChangesText: String {
        let consequence = Self.calorieConsequence(goal: goal?.calorieTargetKcal ?? 0, eaten: todayCalories)
        return "Today: \(MorselFormat.number(todayCalories)) eaten · \(consequence)"
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let today = try await repository.loadToday(userID: userID, date: Date())
            todayCalories = DashboardMath.totals(for: today.meals).caloriesKcal
            let stored = try await repository.loadGoals(userID: userID)
            guard let stored,
                  let calories = stored.calorieTargetKcal,
                  let protein = stored.proteinG,
                  let carbs = stored.carbsG,
                  let fat = stored.fatG else { return }
            apply(DashboardGoal(calorieTargetKcal: calories, proteinG: protein, carbsG: carbs, fatG: fat, source: stored.source), source: stored.source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func choose(_ direction: GoalDirection) async {
        do {
            let computed = try await repository.computeGoals(userID: userID, direction: direction)
            apply(computed, source: .computed)
            selectedDirection = direction
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func edit(_ field: String, value: String) {
        switch field {
        case "calories": calories = value
        case "protein": protein = value
        case "carbs": carbs = value
        case "fat": fat = value
        default: return
        }
        sources[field] = .manual
        didSave = false
    }

    func fieldError(_ field: String) -> String? {
        let value: String
        switch field {
        case "calories": value = calories
        case "protein": value = protein
        case "carbs": value = carbs
        case "fat": value = fat
        default: return nil
        }
        guard let number = Double(value), number.isFinite, number >= 0 else {
            return "Enter a number of 0 or more."
        }
        guard Self.isOnTenthGrid(number) else {
            return "One decimal is plenty — 2000.5 not 2000.55"
        }
        return nil
    }

    func save() async -> Bool {
        guard let calories = Double(calories), calories.isFinite, calories >= 0,
              let protein = Double(protein), protein.isFinite, protein >= 0,
              let carbs = Double(carbs), carbs.isFinite, carbs >= 0,
              let fat = Double(fat), fat.isFinite, fat >= 0 else {
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let source: GoalSource = ["calories", "protein", "carbs", "fat"]
            .allSatisfy { sources[$0] == .computed } ? .computed : .manual
        // One-decimal normalization at the boundary: normalize every value to
        // the 0.1 grid (round half-up) before writing so the payload, the
        // stored row, and the response guard all agree. Store the normalized
        // value back in view-model state so the fields show what was saved.
        let savedGoal = SupabaseDashboardRepository.normalizedGoal(DashboardGoal(
            calorieTargetKcal: calories, proteinG: protein, carbsG: carbs, fatG: fat, source: source
        ))
        self.calories = Self.displayValue(savedGoal.calorieTargetKcal)
        self.protein = Self.displayValue(savedGoal.proteinG)
        self.carbs = Self.displayValue(savedGoal.carbsG)
        self.fat = Self.displayValue(savedGoal.fatG)
        do {
            try await repository.saveGoals(userID: userID, goal: savedGoal)
            goal = savedGoal
            didSave = true
            await onSaved()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func seeToday() {
        onSeeToday()
    }

    /// True when the numeric value sits on the 0.1 grid the app writes (one
    /// decimal place or fewer). Validation parses the input to a Double first
    /// and tests numeric equivalence here — a lexical "count the dots" check
    /// would miss exponent spellings like `1e-2` (0.01, off-grid) or wrongly
    /// reject `1.2e3` (1200.0, on-grid). Used to keep reload lossless: values
    /// the app can store render with the canonical one-decimal formatter
    /// (identity round trip); legacy off-grid stored values render exactly so
    /// validation can reject them instead of silently rounding stored precision.
    static func isOnTenthGrid(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        let scaled = value * 10
        return abs(scaled - scaled.rounded()) < 1e-9
    }

    /// Formats a goal value for display. On-grid values (everything the app
    /// writes under the one-decimal contract) use the canonical one-decimal
    /// formatter, so reload is identity. Off-grid legacy values are shown
    /// exactly — never truncated — and validation rejects them until the user
    /// edits to one decimal.
    static func displayValue(_ value: Double) -> String {
        if isOnTenthGrid(value) {
            return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return String(value)
    }

    private func apply(_ goal: DashboardGoal, source: GoalSource) {
        self.goal = goal
        calories = Self.displayValue(goal.calorieTargetKcal)
        protein = Self.displayValue(goal.proteinG)
        carbs = Self.displayValue(goal.carbsG)
        fat = Self.displayValue(goal.fatG)
        sources = ["calories": source, "protein": source, "carbs": source, "fat": source]
    }
}

struct GoalsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: GoalsEditorViewModel

    init(
        repository: any DashboardRepository,
        userID: UUID,
        onSaved: @escaping () async -> Void = {},
        onSeeToday: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(
            wrappedValue: GoalsEditorViewModel(
                repository: repository, userID: userID, onSaved: onSaved, onSeeToday: onSeeToday
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("morsel · agent voice").font(.morselData).foregroundStyle(Color.morselAccent)
                    Text(viewModel.sourceIndicator).font(.morselData).foregroundStyle(Color.morselInkTwo)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.morselAccent, lineWidth: 1) }
                Text("What are we aiming for?").font(.morselDisplay)
                Text("Pick a direction, then change any number before I save it.").font(.morselBody).foregroundStyle(Color.morselInkTwo)
                HStack(spacing: 8) {
                    ForEach(GoalDirection.allCases, id: \.self) { direction in
                        Button { Task { await viewModel.choose(direction) } } label: {
                            VStack { Text(direction.title); Text(direction.subtitle).font(.morselData) }
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(MorselGhostButtonStyle())
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(viewModel.selectedDirection == direction ? Color.morselAccent : .clear, lineWidth: 2) }
                    }
                }
                Text("YOUR TARGET").morselSectionLabel()
                GoalField(label: "Calories", unit: "kcal", value: $viewModel.calories, source: viewModel.sources["calories"], error: viewModel.fieldError("calories")) { viewModel.edit("calories", value: $0) }
                HStack {
                    GoalField(label: "Protein", unit: "g", value: $viewModel.protein, source: viewModel.sources["protein"], error: viewModel.fieldError("protein")) { viewModel.edit("protein", value: $0) }
                    GoalField(label: "Carbs", unit: "g", value: $viewModel.carbs, source: viewModel.sources["carbs"], error: viewModel.fieldError("carbs")) { viewModel.edit("carbs", value: $0) }
                    GoalField(label: "Fat", unit: "g", value: $viewModel.fat, source: viewModel.sources["fat"], error: viewModel.fieldError("fat")) { viewModel.edit("fat", value: $0) }
                }
                if !viewModel.isValid { Text("One more pass…").foregroundStyle(Color.morselOver).font(.morselBody) }
                if let errorMessage = viewModel.errorMessage { Text(errorMessage).foregroundStyle(Color.morselOver).font(.morselBody) }
                if viewModel.didSave { Text("Goals saved ✓").foregroundStyle(Color.morselAccent).font(.morselBodyStrong) }
                Button(viewModel.didSave ? "Goals saved ✓" : "Use these goals") { Task { await viewModel.save() } }
                    .buttonStyle(.borderedProminent).tint(Color.morselAccent).disabled(!viewModel.isValid || viewModel.isSaving)
                Text("WHAT CHANGES").morselSectionLabel()
                Text(viewModel.whatChangesText).font(.morselBody).foregroundStyle(Color.morselInkTwo)
                Button("See it") {
                    dismiss()
                    viewModel.seeToday()
                }
                .buttonStyle(MorselGhostButtonStyle())
            }.padding(18)
        }
        .background(Color.morselBackground.ignoresSafeArea())
        .navigationTitle("Daily goals")
        .task { await viewModel.load() }
    }
}

private struct GoalField: View {
    let label: String
    let unit: String
    @Binding var value: String
    let source: GoalSource?
    let error: String?
    let onEdit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.morselBodyStrong)
            HStack {
                TextField(label, text: Binding(get: { value }, set: { value = $0; onEdit($0) }))
                    .keyboardType(.numbersAndPunctuation).font(.morselData).multilineTextAlignment(.trailing)
                Text(unit).font(.morselData).foregroundStyle(Color.morselInkThree)
            }.padding(10).background(Color.morselSurfaceTwo).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(error == nil ? .clear : Color.morselOver, lineWidth: 1) }
            Text("source: \(source?.rawValue ?? "—")").font(.morselData).foregroundStyle(Color.morselInkThree)
            if let error { Text(error).font(.morselData).foregroundStyle(Color.morselOver) }
        }
    }
}

// swiftlint:enable line_length

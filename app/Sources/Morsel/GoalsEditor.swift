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
            errorMessage = DashboardUserMessage.userMessage(for: error)
        }
    }

    func choose(_ direction: GoalDirection) async {
        do {
            let computed = try await repository.computeGoals(userID: userID, direction: direction)
            apply(computed, source: .computed)
            selectedDirection = direction
            errorMessage = nil
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
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
              let fat = Double(fat), fat.isFinite, fat >= 0,
              Self.isOnTenthGrid(calories),
              Self.isOnTenthGrid(protein),
              Self.isOnTenthGrid(carbs),
              Self.isOnTenthGrid(fat) else {
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let source: GoalSource = ["calories", "protein", "carbs", "fat"]
            .allSatisfy { sources[$0] == .computed } ? .computed : .manual
        // Reject-before-normalize contract: off-grid values never reach the
        // repository. Only values already on the 0.1 grid pass the guard above,
        // so normalization below is identity for every write and exists purely
        // as defense-in-depth for the persistence boundary. Store the value in
        // view-model state so the fields show exactly what was saved.
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
            errorMessage = DashboardUserMessage.userMessage(for: error)
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

// Issue #94: Goals is a PRIMARY tab — the journal editor page below, never a
// secondary route. See-it jumps to Today.

/// Editable goal fields, keyed for the shared AC6 focus contract.
private enum GoalsFieldKey: Hashable {
    case calories, protein, carbs, fat
}

struct GoalsView: View {
    @StateObject private var viewModel: GoalsEditorViewModel
    /// Issue #105: page-turn revisit bump — the persistent pager keeps pages
    /// mounted, so returning to Goals reloads when this key changes.
    private let reloadKey: Int
    @FocusState private var focusedField: GoalsFieldKey?

    init(
        repository: any DashboardRepository,
        userID: UUID,
        reloadKey: Int = 0,
        onSaved: @escaping () async -> Void = {},
        seeToday: @escaping () -> Void = {}
    ) {
        self.reloadKey = reloadKey
        _viewModel = StateObject(
            wrappedValue: GoalsEditorViewModel(
                repository: repository, userID: userID, onSaved: onSaved, onSeeToday: seeToday
            )
        )
    }

    var body: some View {
        JournalPage(date: Date(), bottomInset: 56) {
            VStack(alignment: .leading, spacing: 18) {
                header
                Text("What are we aiming for?")
                    .font(Font.morselHand(size: 30))
                    .foregroundStyle(Color.morselInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Pick a direction, then change any number before I save it.")
                    .font(.morselBody)
                    .foregroundStyle(Color.morselInkTwo)
                directions
                Text("Your target").morselSectionLabel()
                GoalJournalField(
                    label: "Calories",
                    unit: "kcal",
                    value: $viewModel.calories,
                    focus: $focusedField,
                    key: .calories,
                    source: viewModel.sources["calories"],
                    error: viewModel.fieldError("calories"),
                    prominent: true
                ) { viewModel.edit("calories", value: $0) }
                HStack(alignment: .top, spacing: 14) {
                    GoalJournalField(label: "Protein", unit: "g", value: $viewModel.protein, focus: $focusedField, key: .protein, source: viewModel.sources["protein"], error: viewModel.fieldError("protein")) { viewModel.edit("protein", value: $0) }
                    GoalJournalField(label: "Carbs", unit: "g", value: $viewModel.carbs, focus: $focusedField, key: .carbs, source: viewModel.sources["carbs"], error: viewModel.fieldError("carbs")) { viewModel.edit("carbs", value: $0) }
                    GoalJournalField(label: "Fat", unit: "g", value: $viewModel.fat, focus: $focusedField, key: .fat, source: viewModel.sources["fat"], error: viewModel.fieldError("fat")) { viewModel.edit("fat", value: $0) }
                }
                if !viewModel.isValid {
                    Text("One more pass…")
                        .foregroundStyle(Color.morselOver)
                        .font(.morselBody)
                }
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(Color.morselOver)
                        .font(.morselBody)
                }
                if viewModel.didSave {
                    Text("Goals saved ✓")
                        .foregroundStyle(Color.morselForest)
                        .font(.morselBodyStrong)
                }
                Button(viewModel.didSave ? "Goals saved ✓" : "Use these goals") {
                    JournalKeyboardDismisser.resign()
                    Task { await viewModel.save() }
                }
                .buttonStyle(MorselPrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(!viewModel.isValid || viewModel.isSaving)
                Text("What changes").morselSectionLabel()
                Text(viewModel.whatChangesText)
                    .font(.morselBody)
                    .foregroundStyle(Color.morselInkTwo)
                Button {
                    viewModel.seeToday()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("See it")
                            .font(.morselFootnote)
                            .foregroundStyle(Color.morselForest)
                        MarkerStroke(color: Color.morselForest, width: 40, height: 2)
                    }
                }
                .buttonStyle(.plain)
                .morselResignsKeyboardOnTap()
                .accessibilityLabel("See today's readout")
            }
        }
        .morselNumericDoneBar(focused: $focusedField) { _ in .numbersAndPunctuation }
        .task(id: reloadKey) { await viewModel.load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Daily goals")
                    .font(.morselFootnote)
                    .foregroundStyle(Color.morselInkThree)
                Text(viewModel.sourceIndicator)
                    .font(.morselFootnote)
                    .foregroundStyle(Color.morselInkThree)
            }
            Spacer()
            Text("morsel · agent voice")
                .font(.morselFootnote)
                .foregroundStyle(Color.morselInkThree)
        }
        .padding(.bottom, 6)
    }

    private var directions: some View {
        HStack(spacing: 6) {
            ForEach(GoalDirection.allCases, id: \.self) { direction in
                Button {
                    Task { await viewModel.choose(direction) }
                } label: {
                    VStack(spacing: 2) {
                        Text(direction.title)
                            .font(Font.morselHand(size: 20))
                            .foregroundStyle(
                                viewModel.selectedDirection == direction ? Color.morselForest : Color.morselInk
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                viewModel.selectedDirection == direction
                                    ? Color.morselForest.opacity(0.14)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        Text(direction.subtitle)
                            .font(.morselFootnote)
                            .foregroundStyle(Color.morselInkTwo)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .morselResignsKeyboardOnTap()
                .accessibilityAddTraits(viewModel.selectedDirection == direction ? .isSelected : [])
            }
        }
    }
}

private struct GoalJournalField<Key: Hashable>: View {
    let label: String
    let unit: String
    @Binding var value: String
    var focus: FocusState<Key?>.Binding
    var key: Key
    let source: GoalSource?
    let error: String?
    var prominent = false
    let onEdit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Issue #105: shared ruled paper field (label, inkline rule, mono
            // value, unit readout, error on the rule) — the same component
            // Add Meal and Edit Item use.
            JournalPaperField(
                label: label,
                text: $value,
                focus: focus,
                key: key,
                unit: unit,
                keyboardType: .numbersAndPunctuation,
                monospacedValue: true,
                prominent: prominent,
                trailingValue: true,
                error: error,
                onEdit: onEdit
            )
            HStack {
                ProvenanceLabel(text: "source: \(source?.rawValue ?? "—")")
                Spacer()
            }
        }
    }
}

// swiftlint:enable line_length

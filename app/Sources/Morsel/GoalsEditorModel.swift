import Combine
import Foundation

// Issue #113 — Goals page model. Load reads the FULL page context (stored
// goals row + profile row + newest synced weight via GoalPageContext) so
// the page mirrors the server's get_goals recency rule: a stale complete
// manual row (older than the profile) is replaced on screen by the freshly
// computed targets and reported in the one-line calm note; a current
// manual row keeps the existing Cut/Maintain/Bulk + manual-edit flow, and
// saving without edits keeps `source: computed`. Amendment B renders the
// read-only profile line from the same context.

@MainActor
final class GoalsEditorViewModel: ObservableObject {
    @Published private(set) var goal: DashboardGoal?
    @Published private(set) var sources: [String: GoalSource] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedDirection: GoalDirection?
    /// Issue #123 — the phase the profile diet goal implies
    /// (lose→cut / maintain→maintain / gain→bulk). While a manual goal is
    /// effective no chip is filled; this lighter "profile" chip tells which
    /// phase the numbers belong to. Nil without a profile row.
    @Published private(set) var profileDirection: GoalDirection?
    @Published private(set) var didSave = false
    @Published private(set) var todayCalories = 0.0
    @Published private(set) var supersededNote: String?
    @Published private(set) var profileLine: String?
    @Published var calories = ""
    @Published var protein = ""
    @Published var carbs = ""
    @Published var fat = ""

    private let repository: any DashboardRepository
    private let userID: UUID
    private let onSaved: () async -> Void
    private let onSeeToday: () -> Void
    /// Issue #123 — fields the user has edited (even to empty). A pristine
    /// empty field is the pre-load state, not an error: validation appears
    /// once the field is edited or carries an invalid value.
    private var editedFields: Set<String> = []

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

    /// Issue #123 — the very first paint has not arrived yet (no cached row
    /// and the remote load is still in flight): the view shows a calm
    /// loading state instead of empty fields and validation.
    var isAwaitingFirstGoal: Bool {
        isLoading && goal == nil
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
        // Issue #123 — local-first first paint: the cached stored goal row
        // (last known remote snapshot) paints immediately so the page never
        // opens as empty fields with validation errors while the remote
        // round-trip is in flight. The remote refresh below reconciles.
        if let cached = try? await repository.cachedGoals(userID: userID) {
            apply(GoalsPageContext(
                stored: cached, profile: nil, latestWeight: nil, profileRowRead: false
            ))
        }
        do {
            let today = try await repository.loadToday(userID: userID, date: Date())
            todayCalories = DashboardMath.totals(for: today.meals).caloriesKcal
            let context = try await repository.loadGoalsContext(userID: userID)
            apply(context)
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
        }
    }

    /// Fills the fields with the EFFECTIVE goal (server get_goals mirror):
    /// a current manual row shows its own numbers; a stale manual row (and
    /// every non-manual row) shows the freshly computed targets. The
    /// superseded note and the profile line come from the same context.
    private func apply(_ context: GoalsPageContext) {
        profileLine = GoalsPageCopy.profileLine(context: context)
        supersededNote = GoalsPageCopy.supersededLine(
            stored: context.stored, profile: context.profile
        )
        profileDirection = context.profile.map { GoalDirection(profileDietGoal: $0.dietGoal) }
        guard let stored = context.stored else { return }
        guard let effective = DashboardMath.effectiveGoal(
            stored: stored,
            profile: context.profile,
            latestWeightKg: context.latestWeight?.kilograms
        ) else {
            // Rows the mirror cannot resolve without a profile (legacy
            // computed-source rows): keep showing the stored values when
            // complete, exactly as before #113.
            guard let calories = stored.calorieTargetKcal,
                  let protein = stored.proteinG,
                  let carbs = stored.carbsG,
                  let fat = stored.fatG else {
                return
            }
            apply(
                DashboardGoal(
                    calorieTargetKcal: calories, proteinG: protein,
                    carbsG: carbs, fatG: fat, source: stored.source
                ),
                source: stored.source
            )
            selectedDirection = nil
            return
        }
        apply(effective, source: effective.source)
        // Issue #123 — the filled chip is derived, not tap-only: a computed
        // effective goal fills the chip matching the profile diet goal
        // (lose→cut / maintain→maintain / gain→bulk). A current manual goal
        // fills nothing — its numbers are typed, not chosen — and the
        // profileDirection chip renders as the lighter hint instead.
        if effective.source == .manual {
            selectedDirection = nil
        } else if let profile = context.profile {
            selectedDirection = GoalDirection(profileDietGoal: profile.dietGoal)
        } else {
            selectedDirection = nil
        }
    }

    func choose(_ direction: GoalDirection) async {
        do {
            let computed = try await repository.computeGoals(userID: userID, direction: direction)
            apply(computed, source: .computed)
            selectedDirection = direction
            supersededNote = nil
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
        editedFields.insert(field)
        sources[field] = .manual
        didSave = false
        supersededNote = nil
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
        // Issue #123 — a pristine empty field is the pre-load state, not an
        // error: validation appears once the user edits the field (even to
        // empty) or the field carries an invalid value.
        if value.isEmpty && !editedFields.contains(field) {
            return nil
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
            supersededNote = nil
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

// Issue #113 — calm page copy (superseded note + read-only profile line).
enum GoalsPageCopy {
    static func profileLine(context: GoalsPageContext) -> String? {
        guard let profile = context.profile else {
            return context.profileRowRead
                ? "no profile yet — tell your agent your height, weight, age and activity"
                : nil
        }
        let sample = context.latestWeight
        var text = "computed from \(trimmed(sample?.kilograms ?? profile.weightKg)) kg"
        if let sample {
            text += " (Health · \(MorselStamp.dayMonth(sample.measuredAt)))"
        } else {
            text += " (profile)"
        }
        text += " · \(trimmed(profile.heightCm)) cm · \(profile.ageYears) y"
            + " · \(activityWord(profile.activityLevel)) · \(dietWord(profile.dietGoal))"
        if let updatedAt = profile.updatedAt {
            text += " — set via your agent \(MorselStamp.dayMonth(updatedAt))"
        }
        return text
    }

    /// One-line calm note for the stale-manual state: the profile changed
    /// after the manual row, so the fields now hold the new computed
    /// targets and the note names the manual numbers they replaced.
    static func supersededLine(stored: StoredDashboardGoal?, profile: DashboardProfile?) -> String? {
        guard let superseded = DashboardMath.supersededManual(stored: stored, profile: profile) else {
            return nil
        }
        let prefix = profile?.updatedAt.map { "your profile changed on \(MorselStamp.dayMonth($0));" }
            ?? "your profile changed;"
        return "\(prefix) these are the new computed targets — your earlier manual numbers were "
            + "\(MorselFormat.number(superseded.calorieTargetKcal)) / \(MorselFormat.number(superseded.proteinG))"
            + " / \(MorselFormat.number(superseded.carbsG)) / \(MorselFormat.number(superseded.fatG))"
    }

    private static func activityWord(_ level: ProfileActivityLevel) -> String {
        switch level {
        case .sedentary: return "sedentary"
        case .light: return "light"
        case .moderate: return "moderate"
        case .active: return "active"
        case .veryActive: return "very active"
        }
    }

    private static func dietWord(_ goal: ProfileDietGoal) -> String {
        switch goal {
        case .lose: return "lose"
        case .maintain: return "maintain"
        case .gain: return "gain"
        }
    }

    /// 63 → "63", 61.5 → "61.5", 167 → "167" (fixed POSIX decimal).
    private static func trimmed(_ value: Double) -> String {
        trimmedFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let trimmedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

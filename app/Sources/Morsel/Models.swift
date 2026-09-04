import Foundation

struct MealItem: Identifiable, Equatable, Sendable {
    let itemID: UUID
    let name: String
    let quantity: Double
    let unit: FoodUnit
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fiberG: Double?
    let sugarG: Double?
    let confidence: Double?
    let notes: String?
    let source: MealSource

    init(
        itemID: UUID,
        name: String,
        quantity: Double,
        unit: FoodUnit,
        caloriesKcal: Double?,
        proteinG: Double?,
        carbsG: Double?,
        fatG: Double?,
        fiberG: Double?,
        sugarG: Double?,
        confidence: Double?,
        notes: String?,
        source: MealSource = .manual
    ) {
        self.itemID = itemID
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.sugarG = sugarG
        self.confidence = confidence
        self.notes = notes
        self.source = source
    }

    var id: UUID { itemID }

    var isManualEdit: Bool {
        notes == MealSource.manualEdit.rawValue
    }

    var provenance: MealSource {
        isManualEdit ? .manualEdit : source
    }

    var needsReview: Bool {
        !isManualEdit && DashboardMath.confidenceBadge(for: confidence).needsReview
    }
}

enum FoodUnit: String, CaseIterable, Sendable {
    case gram = "g"
    case milliliter = "ml"
    case serving
    case piece
    case cup
}

enum MealSource: String, CaseIterable, Sendable {
    case manual
    case manualEdit = "manual_edit"
    case photoVision = "photo_vision"
    case barcode
    case imported = "import"
    case voice
}

enum ProfileSex: String, Sendable {
    case male
    case female
}

enum ProfileActivityLevel: String, Sendable {
    case sedentary
    case light
    case moderate
    case active
    case veryActive = "very_active"
}

enum ProfileDietGoal: String, Sendable {
    case lose
    case maintain
    case gain
}

struct DashboardProfile: Equatable, Sendable {
    let sex: ProfileSex
    let ageYears: Int
    let heightCm: Double
    let weightKg: Double
    let activityLevel: ProfileActivityLevel
    let dietGoal: ProfileDietGoal
    let goalWeightKg: Double?
}

enum MealType: String, CaseIterable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snack

    var title: String {
        rawValue.capitalized
    }
}

struct MealRecord: Identifiable, Equatable, Sendable {
    let mealLogID: UUID
    let mealType: MealType
    let eatenAt: Date
    let source: MealSource
    let imagePath: String?
    let items: [MealItem]

    init(
        mealLogID: UUID,
        mealType: MealType,
        eatenAt: Date,
        source: MealSource,
        imagePath: String? = nil,
        items: [MealItem]
    ) {
        self.mealLogID = mealLogID
        self.mealType = mealType
        self.eatenAt = eatenAt
        self.source = source
        self.imagePath = imagePath
        self.items = items
    }

    var id: UUID { mealLogID }
}

struct DashboardTotals: Equatable, Sendable {
    let caloriesKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
}

struct WeightTrendPoint: Equatable, Sendable, Identifiable {
    let date: Date
    let kilograms: Double
    var id: Date { date }
}

enum GoalSource: String, Sendable {
    case computed
    case manual
}

struct DashboardGoal: Equatable, Sendable {
    let calorieTargetKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let source: GoalSource
}

struct StoredDashboardGoal: Equatable, Sendable {
    let calorieTargetKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let source: GoalSource
}

struct DashboardSnapshot: Equatable, Sendable {
    let date: Date
    let meals: [MealRecord]
    let goal: DashboardGoal?
    let weightTrend: [WeightTrendPoint]
    let activeEnergyBurned: Double

    init(
        date: Date, meals: [MealRecord], goal: DashboardGoal?, weightTrend: [WeightTrendPoint] = [],
        activeEnergyBurned: Double = 0
    ) {
        self.date = date
        self.meals = meals
        self.goal = goal
        self.weightTrend = weightTrend
        self.activeEnergyBurned = activeEnergyBurned
    }
}

enum ConfidenceBadge: Equatable, Sendable {
    case high
    case low
    case missing

    var needsReview: Bool {
        self != .high
    }
}

enum GoalStatus: Equatable, Sendable {
    case onTrack
    case nearGoal
    case over
    case unavailable
}

enum DashboardMath {
    static let lowConfidenceThreshold = 0.8
    static let nearGoalThreshold = 0.85
    /// V1 goal tolerance: the History "soft ±50 kcal" band — a day within ±50
    /// of the target reads "on target"; beyond it reads under/over.
    static let onTargetToleranceKcal = 50.0

    /// The ONE displayed delta semantics (issue #94): eaten minus goal. Active
    /// energy is never subtracted — it is context only.
    static func eatenMinusGoal(eaten: Double, goal: Double?) -> Double? {
        guard let goal, goal.isFinite, goal > 0 else { return nil }
        return eaten - goal
    }

    /// Signed state word for a day delta: under / on target / over (±50).
    static func comparison(delta: Double?) -> DayComparison {
        guard let delta, delta.isFinite else { return .onTarget }
        if delta > onTargetToleranceKcal { return .over }
        if delta < -onTargetToleranceKcal { return .under }
        return .onTarget
    }

    static func totals(for meals: [MealRecord]) -> DashboardTotals {
        meals.reduce(into: DashboardTotals(caloriesKcal: 0, proteinG: 0, carbsG: 0, fatG: 0)) { totals, meal in
            for item in meal.items {
                totals = DashboardTotals(
                    caloriesKcal: totals.caloriesKcal + (item.caloriesKcal ?? 0),
                    proteinG: totals.proteinG + (item.proteinG ?? 0),
                    carbsG: totals.carbsG + (item.carbsG ?? 0),
                    fatG: totals.fatG + (item.fatG ?? 0)
                )
            }
        }
    }

    static func effectiveGoal(
        stored: StoredDashboardGoal?,
        profile: DashboardProfile?
    ) -> DashboardGoal? {
        if let stored,
           stored.source == .manual,
           let calorieTargetKcal = stored.calorieTargetKcal,
           let proteinG = stored.proteinG,
           let carbsG = stored.carbsG,
           let fatG = stored.fatG {
            return DashboardGoal(
                calorieTargetKcal: calorieTargetKcal,
                proteinG: proteinG,
                carbsG: carbsG,
                fatG: fatG,
                source: .manual
            )
        }
        guard let profile else {
            return nil
        }
        let computed = computedGoal(for: profile)
        guard let stored, stored.source == .manual else {
            return computed
        }
        return DashboardGoal(
            calorieTargetKcal: stored.calorieTargetKcal ?? computed.calorieTargetKcal,
            proteinG: stored.proteinG ?? computed.proteinG,
            carbsG: stored.carbsG ?? computed.carbsG,
            fatG: stored.fatG ?? computed.fatG,
            source: .manual
        )
    }

    static func computedGoal(for profile: DashboardProfile) -> DashboardGoal {
        let sexOffset: Double = profile.sex == .male ? 5 : -161
        let weightTerm = 10 * profile.weightKg
        let heightTerm = 6.25 * profile.heightCm
        let ageTerm = 5 * Double(profile.ageYears)
        let bmr = weightTerm + heightTerm - ageTerm + sexOffset
        let activityFactor: Double = switch profile.activityLevel {
        case .sedentary:
            1.2
        case .light:
            1.375
        case .moderate:
            1.55
        case .active:
            1.725
        case .veryActive:
            1.9
        }
        let tdee = (bmr * activityFactor).rounded()
        let calorieTarget: Double = switch profile.dietGoal {
        case .lose:
            max(1_200, tdee - 500)
        case .maintain:
            tdee
        case .gain:
            tdee + 300
        }
        return DashboardGoal(
            calorieTargetKcal: calorieTarget,
            proteinG: (calorieTarget * 0.3 / 4).rounded(),
            carbsG: (calorieTarget * 0.45 / 4).rounded(),
            fatG: (calorieTarget * 0.25 / 9).rounded(),
            source: .computed
        )
    }

    static func confidenceBadge(for confidence: Double?) -> ConfidenceBadge {
        guard let confidence, confidence.isFinite else {
            return .missing
        }
        return confidence < lowConfidenceThreshold ? .low : .high
    }

    static func goalStatus(eaten: Double, goal: Double?) -> GoalStatus {
        guard let goal, goal.isFinite, goal > 0 else {
            return .unavailable
        }
        if eaten > goal {
            return .over
        }
        if eaten >= goal * nearGoalThreshold {
            return .nearGoal
        }
        return .onTrack
    }

    static func goalProgress(eaten: Double, goal: Double?) -> Double {
        guard let goal, goal.isFinite, goal > 0 else {
            return 0
        }
        return min(max(eaten / goal, 0), 1)
    }

}

enum MorselError: LocalizedError, Equatable {
    case configurationMissing
    case invalidInput(String)
    case invalidData(String)
    case requestFailed(Int, String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "Morsel is not configured for this build."
        case let .invalidInput(message), let .invalidData(message):
            return message
        // #94 (AC5): the friendly boundary. Status/backend payloads never
        // reach users — the request error is a human "try again", never raw
        // Supabase/Postgres text.
        case .requestFailed:
            return "The request could not be completed. Try again."
        case .decodingFailed:
            return "The response could not be read. Try again."
        }
    }
}

/// #94 (AC5): the friendly user-facing boundary for dashboard flows. Morsel
/// errors keep their curated copy; anything else (transport/decoding details)
/// becomes a human message — raw Supabase/Postgres/backend text never reaches
/// users.
enum DashboardUserMessage {
    static let unexpected = "Something went wrong. Please try again."

    static func userMessage(for error: Error) -> String {
        if let morselError = error as? MorselError {
            return morselError.errorDescription ?? unexpected
        }
        return unexpected
    }
}

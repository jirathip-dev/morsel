import Foundation

struct MealItemUpdate: Equatable, Sendable {
    let itemID: UUID
    let name: String?
    let quantity: Double?
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let source: MealSource

    init(
        itemID: UUID,
        name: String? = nil,
        quantity: Double? = nil,
        caloriesKcal: Double? = nil,
        proteinG: Double? = nil,
        carbsG: Double? = nil,
        fatG: Double? = nil,
        source: MealSource = .manualEdit
    ) {
        self.itemID = itemID
        self.name = name
        self.quantity = quantity
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.source = source
    }

    var hasChanges: Bool {
        name != nil
            || quantity != nil
            || caloriesKcal != nil
            || proteinG != nil
            || carbsG != nil
            || fatG != nil
    }
}

enum MealItemUpdateValidation {
    static func validate(_ update: MealItemUpdate) throws {
        guard update.hasChanges else {
            throw MorselError.invalidInput("Provide at least one meal item field to update.")
        }
        if let name = update.name,
           name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MorselError.invalidInput("Food name cannot be empty.")
        }
        if let quantity = update.quantity,
           !quantity.isFinite || quantity <= 0 {
            throw MorselError.invalidInput("Quantity must be a positive number.")
        }
        try validate(update.caloriesKcal, field: "Calories")
        try validate(update.proteinG, field: "Protein")
        try validate(update.carbsG, field: "Carbs")
        try validate(update.fatG, field: "Fat")
    }

    private static func validate(_ value: Double?, field: String) throws {
        guard let value else {
            return
        }
        guard value.isFinite, value >= 0 else {
            throw MorselError.invalidInput("\(field) must be zero or greater.")
        }
    }
}

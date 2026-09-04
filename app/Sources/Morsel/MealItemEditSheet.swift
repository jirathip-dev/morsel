import SwiftUI

struct MealItemEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: MealItem
    let onSave: (MealItemUpdate) async -> Bool

    @State private var name: String
    @State private var quantity: String
    @State private var calories: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fat: String
    @State private var isSaving = false
    @State private var message: String?

    init(item: MealItem, onSave: @escaping (MealItemUpdate) async -> Bool) {
        self.item = item
        self.onSave = onSave
        _name = State(initialValue: item.name)
        _quantity = State(initialValue: String(item.quantity))
        _calories = State(initialValue: Self.text(for: item.caloriesKcal))
        _protein = State(initialValue: Self.text(for: item.proteinG))
        _carbs = State(initialValue: Self.text(for: item.carbsG))
        _fat = State(initialValue: Self.text(for: item.fatG))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    TextField("Food name", text: $name)
                    HStack {
                        TextField("Quantity", text: $quantity)
                            .keyboardType(.decimalPad)
                        Text("\(item.unit.rawValue)")
                            .font(.morselData)
                            .foregroundStyle(Color.morselInkTwo)
                    }
                }

                Section("Nutrition") {
                    TextField("Calories (optional)", text: $calories)
                        .keyboardType(.decimalPad)
                    TextField("Protein grams (optional)", text: $protein)
                        .keyboardType(.decimalPad)
                    TextField("Carbs grams (optional)", text: $carbs)
                        .keyboardType(.decimalPad)
                    TextField("Fat grams (optional)", text: $fat)
                        .keyboardType(.decimalPad)
                }

                Section("Provenance") {
                    Text("source: \(item.provenance.rawValue)")
                        .font(.morselData)
                        .foregroundStyle(Color.morselInkTwo)
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.morselBody)
                            .foregroundStyle(Color.morselOver)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.morselBackground)
            .navigationTitle("Edit item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        save()
                    }
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        isSaving = true
        message = nil
        Task { @MainActor in
            do {
                let update = try makeUpdate()
                if await onSave(update) {
                    dismiss()
                } else {
                    message = "The item could not be updated."
                }
            } catch {
                message = DashboardUserMessage.userMessage(for: error)
            }
            isSaving = false
        }
    }

    private func makeUpdate() throws -> MealItemUpdate {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw MorselError.invalidInput("Food name cannot be empty.")
        }
        guard let quantityValue = Double(quantity), quantityValue.isFinite, quantityValue > 0 else {
            throw MorselError.invalidInput("Quantity must be a positive number.")
        }
        return MealItemUpdate(
            itemID: item.itemID,
            name: trimmedName,
            quantity: quantityValue,
            caloriesKcal: try optionalValue(calories, label: "Calories"),
            proteinG: try optionalValue(protein, label: "Protein"),
            carbsG: try optionalValue(carbs, label: "Carbs"),
            fatG: try optionalValue(fat, label: "Fat"),
            source: .manualEdit
        )
    }

    private func optionalValue(_ text: String, label: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let value = Double(trimmed), value.isFinite, value >= 0 else {
            throw MorselError.invalidInput("\(label) must be zero or greater.")
        }
        return value
    }

    private static func text(for value: Double?) -> String {
        guard let value else {
            return ""
        }
        return String(value)
    }
}

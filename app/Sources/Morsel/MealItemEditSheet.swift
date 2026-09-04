import SwiftUI
import UIKit

// Issue #105 — Edit Item stays a modal (issue AC3 permits it) but now reads
// as the journal contract: paper ground, spine furniture, ruled paper fields
// (AC5), and the shared focus/keyboard rules (AC6) instead of stock Form
// cells.

struct MealItemEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: MealItem
    let onSave: (MealItemUpdate) async -> Bool

    /// Editable keys for the shared AC6 focus contract.
    private enum EditItemFieldKey: Hashable {
        case name, quantity, calories, protein, carbs, fat
    }

    @FocusState private var focusedField: EditItemFieldKey?

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
        JournalPage(date: Date(), bottomInset: 24) {
            VStack(alignment: .leading, spacing: 0) {
                JournalPageHeader(
                    title: "Edit item",
                    leadingTitle: "Cancel",
                    leadingAction: cancel,
                    trailingTitle: isSaving ? "Saving…" : "Save",
                    trailingDisabled: isSaving,
                    trailingAction: save
                )

                if let message {
                    Text(message)
                        .font(.morselBody)
                        .foregroundStyle(Color.morselOver)
                        .padding(.bottom, 10)
                }

                SectionHeading(title: "Food")
                    .padding(.bottom, 10)
                JournalPaperField(
                    label: "Food name",
                    text: $name,
                    focus: $focusedField,
                    key: .name,
                    keyboardType: .default,
                    hint: "Required"
                )
                .padding(.bottom, 14)
                HStack(alignment: .top, spacing: 14) {
                    JournalPaperField(
                        label: "Quantity",
                        text: $quantity,
                        focus: $focusedField,
                        key: .quantity,
                        unit: item.unit.rawValue,
                        keyboardType: .decimalPad,
                        monospacedValue: true,
                        prominent: true,
                        hint: "Positive number"
                    )
                    .frame(maxWidth: 180)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 14)

                SectionHeading(title: "Nutrition")
                    .padding(.bottom, 10)
                HStack(alignment: .top, spacing: 14) {
                    JournalPaperField(
                        label: "Calories",
                        text: $calories,
                        focus: $focusedField,
                        key: .calories,
                        unit: "kcal",
                        prompt: "Optional",
                        keyboardType: .decimalPad,
                        monospacedValue: true,
                        hint: "Zero or greater"
                    )
                    JournalPaperField(
                        label: "Protein",
                        text: $protein,
                        focus: $focusedField,
                        key: .protein,
                        unit: "g",
                        prompt: "Optional",
                        keyboardType: .decimalPad,
                        monospacedValue: true,
                        hint: "Zero or greater"
                    )
                }
                .padding(.bottom, 14)
                HStack(alignment: .top, spacing: 14) {
                    JournalPaperField(
                        label: "Carbs",
                        text: $carbs,
                        focus: $focusedField,
                        key: .carbs,
                        unit: "g",
                        prompt: "Optional",
                        keyboardType: .decimalPad,
                        monospacedValue: true,
                        hint: "Zero or greater"
                    )
                    JournalPaperField(
                        label: "Fat",
                        text: $fat,
                        focus: $focusedField,
                        key: .fat,
                        unit: "g",
                        prompt: "Optional",
                        keyboardType: .decimalPad,
                        monospacedValue: true,
                        hint: "Zero or greater"
                    )
                }

                JournalRule()
                    .padding(.vertical, 16)
                SectionHeading(title: "Provenance")
                    .padding(.bottom, 8)
                ProvenanceLabel(text: "source: \(item.provenance.rawValue)")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .morselNumericDoneBar(focused: $focusedField, keyboardType: keyboardType(for:))
    }

    private func keyboardType(for key: EditItemFieldKey) -> UIKeyboardType {
        switch key {
        case .name:
            return .default
        case .quantity, .calories, .protein, .carbs, .fat:
            return .decimalPad
        }
    }

    private func cancel() {
        JournalKeyboardDismisser.resign()
        dismiss()
    }

    private func save() {
        JournalKeyboardDismisser.resign()
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

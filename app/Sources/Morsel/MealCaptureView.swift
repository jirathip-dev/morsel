import PhotosUI
import SwiftUI
import UIKit

// Issue #105 — Add Meal is a full journal page (AC3), not the primary sheet:
// paper ground with spine furniture, ruled paper fields (AC5), native photo
// controls, and the shared focus/keyboard contract (AC6 — numeric Done bar,
// blank/scroll/picker dismissal). Cancel/back and save-close both return to
// the Today pages through the shell route model.

struct AddMealView: View {
    @ObservedObject var viewModel: DashboardViewModel
    /// Route dismissal (Cancel/back or save-close → Today pages).
    let onClose: () -> Void
    /// Issue #152 — menu library shared with the Menus screen.
    @ObservedObject var menuLibrary: MenuLibraryModel
    /// Opens the Menus screen (create/edit/delete templates).
    let onOpenMenus: () -> Void

    /// Editable keys for the shared AC6 focus contract.
    private enum AddMealFieldKey: Hashable {
        case notes, name, quantity, calories, protein, carbs, fat
    }

    @FocusState private var focusedField: AddMealFieldKey?

    @State private var mealType = MealType.lunch
    @State private var eatenAt = Date()
    @State private var notes = ""
    @State private var itemName = ""
    @State private var quantity = "1"
    @State private var unit = FoodUnit.serving
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var photo: FoodImageUpload?
    /// Photo prep in flight (owned by the page so Save stands down).
    @State private var isProcessingPhoto = false
    @State private var isSubmitting = false
    @State private var message: String?

    var body: some View {
        JournalPage(date: Date(), bottomInset: 24) {
            VStack(alignment: .leading, spacing: 0) {
                JournalPageHeader(
                    title: "Add meal",
                    leadingTitle: "Cancel",
                    leadingAction: onClose,
                    trailingTitle: isSubmitting ? "Saving…" : "Save meal",
                    trailingDisabled: !canSave,
                    trailingAction: save
                )

                if let message {
                    Text(message)
                        .font(.morselBody)
                        .foregroundStyle(Color.morselOver)
                        .padding(.bottom, 10)
                }

                AddMealPhotoSection(
                    pickerItem: $pickerItem,
                    photo: $photo,
                    message: $message,
                    isSubmitting: isSubmitting,
                    isProcessingPhoto: $isProcessingPhoto
                )
                JournalRule()
                    .padding(.vertical, 16)
                SectionHeading(title: "Meal")
                    .padding(.bottom, 10)
                mealTypeRow
                    .padding(.bottom, 6)
                eatenAtRow
                    .padding(.bottom, 14)
                JournalPaperField(
                                  label: "Notes", text: $notes, focus: $focusedField,
                                  key: .notes, prompt: "Notes (optional)", axis: .vertical,
                                  keyboardType: .default,
                                  hint: "Optional notes about the meal"
                )

                JournalRule()
                    .padding(.vertical, 16)
                SectionHeading(title: "Log from menu")
                    .padding(.bottom, 10)
                menuLogContent

                JournalRule()
                    .padding(.vertical, 16)
                SectionHeading(title: "Food")
                    .padding(.bottom, 10)
                JournalPaperField(
                                  label: "Food name", text: $itemName, focus: $focusedField, key: .name,
                                  prompt: "Food name", keyboardType: .default, hint: "Required"
                )
                .padding(.bottom, 14)

                HStack(alignment: .top, spacing: 14) {
                    JournalPaperField(
                                  label: "Quantity", text: $quantity, focus: $focusedField, key: .quantity,
                                  keyboardType: .decimalPad, monospacedValue: true,
                                  prominent: true, hint: "Positive number"
                    )
                    .frame(maxWidth: 130)
                    unitColumn
                        .padding(.top, 0)
                }
                .padding(.bottom, 14)

                nutritionGrid(calories: $calories, protein: $protein, carbs: $carbs, fat: $fat)
            }
        }
        .morselNumericDoneBar(focused: $focusedField, keyboardType: keyboardType(for:))
        .task { await menuLibrary.loadMenus() }
    }
}

// Issue #105 helpers (same-file extension keeps the type-body budget).
private extension AddMealView {
    private var canSave: Bool {
        !isSubmitting
            && !isProcessingPhoto
            && !itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var mealTypeRow: some View {
        HStack {
            Text("Meal type")
                .font(.morselBodyStrong)
                .foregroundStyle(Color.morselInk)
            Spacer()
            Picker("Meal type", selection: $mealType) {
                ForEach(MealType.allCases, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Color.morselInkTwo)
        }
        .morselResignsKeyboardOnTap()
    }
    private var eatenAtRow: some View {
        HStack {
            Text("Eaten at")
                .font(.morselBodyStrong)
                .foregroundStyle(Color.morselInk)
            Spacer()
            DatePicker(
                "Eaten at",
                selection: $eatenAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .tint(Color.morselInkTwo)
        }
        .morselResignsKeyboardOnTap()
    }
    private var unitColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unit")
                .font(.morselBodyStrong)
                .foregroundStyle(Color.morselInk)
            HStack {
                Picker("Unit", selection: $unit) {
                    ForEach(FoodUnit.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Color.morselInkTwo)
                .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)
            Rectangle()
                .fill(Color.morselInkLine.opacity(0.75))
                .frame(height: 1)
                .padding(.bottom, 1)
        }
        .morselResignsKeyboardOnTap()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func nutritionGrid(
        calories: Binding<String>,
        protein: Binding<String>,
        carbs: Binding<String>,
        fat: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                JournalPaperField(
                                  label: "Calories", text: calories, focus: $focusedField, key: .calories,
                                  unit: "kcal", prompt: "Optional", keyboardType: .decimalPad, monospacedValue: true,
                                  hint: "Zero or greater"
                )
                JournalPaperField(
                                  label: "Protein", text: protein, focus: $focusedField, key: .protein,
                                  unit: "g", prompt: "Optional", keyboardType: .decimalPad, monospacedValue: true,
                                  hint: "Zero or greater"
                )
            }
            HStack(alignment: .top, spacing: 14) {
                JournalPaperField(
                                  label: "Carbs", text: carbs, focus: $focusedField, key: .carbs,
                                  unit: "g", prompt: "Optional", keyboardType: .decimalPad, monospacedValue: true,
                                  hint: "Zero or greater"
                )
                JournalPaperField(
                                  label: "Fat", text: fat, focus: $focusedField, key: .fat,
                                  unit: "g", prompt: "Optional", keyboardType: .decimalPad, monospacedValue: true,
                                  hint: "Zero or greater"
                )
            }
        }
    }

    private func keyboardType(for key: AddMealFieldKey) -> UIKeyboardType {
        switch key {
        case .notes, .name:
            return .default
        case .quantity, .calories, .protein, .carbs, .fat:
            return .decimalPad
        }
    }
    private func save() {
        JournalKeyboardDismisser.resign()
        isSubmitting = true
        message = nil
        Task { @MainActor in
            do {
                let draft = try makeDraft()
                let didSave = await viewModel.addMeal(draft: draft, photo: photo)
                if didSave {
                    onClose()
                } else {
                    message = viewModel.errorMessage ?? "The meal could not be saved."
                }
            } catch {
                message = DashboardUserMessage.userMessage(for: error)
            }
            isSubmitting = false
        }
    }

    private func makeDraft() throws -> MealDraft {
        let trimmedName = itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw MorselError.invalidInput("Add a food name before saving.")
        }
        guard let quantityValue = Double(quantity), quantityValue.isFinite, quantityValue > 0 else {
            throw MorselError.invalidInput("Quantity must be a positive number.")
        }
        return MealDraft(
            mealType: mealType,
            eatenAt: eatenAt,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes,
            items: [
                MealItemDraft(
                    name: trimmedName,
                    quantity: quantityValue,
                    unit: unit,
                    caloriesKcal: try optionalValue(calories, label: "Calories"),
                    proteinG: try optionalValue(protein, label: "Protein"),
                    carbsG: try optionalValue(carbs, label: "Carbs"),
                    fatG: try optionalValue(fat, label: "Fat")
                )
            ]
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

    // MARK: - Issue #152 'Log from menu'

    @ViewBuilder
    private var menuLogContent: some View {
        if menuLibrary.isLoading && menuLibrary.isEmpty {
            HStack(spacing: 8) {
                ProgressView().tint(Color.morselAccent)
                Text("Loading menus")
                    .font(.morselBody)
                    .foregroundStyle(Color.morselInkTwo)
            }
            .padding(.vertical, 4)
        } else if let menuError = menuLibrary.errorMessage {
            Text(menuError)
                .font(.morselBody)
                .foregroundStyle(Color.morselOver)
            manageMenusRow
        } else if menuLibrary.isEmpty {
            Text("No menus yet — menus bundle foods you log often.")
                .font(.morselBody)
                .foregroundStyle(Color.morselInkTwo)
            manageMenusRow
        } else {
            ForEach(menuLibrary.menus) { menu in
                menuLogRow(menu)
            }
            manageMenusRow
        }
    }

    private var manageMenusRow: some View {
        Button {
            JournalKeyboardDismisser.resign()
            onOpenMenus()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselForest)
                Text("Manage menus")
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInk)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private func menuLogRow(_ menu: NamedMenu) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(menu.name)
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInk)
                Text(menu.summaryLine)
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkThree)
            }
            Spacer(minLength: 8)
            Button("Log") {
                logFromMenu(menu)
            }
            .font(.morselBodyStrong)
            .foregroundStyle(Color.morselForest)
            .buttonStyle(.plain)
            .disabled(isSubmitting)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(menu.name), \(menu.summaryLine), log")
    }

    /// Logs one named menu: every item is copied into the draft with the
    /// shared snapshot group id + menu name copy, then saved exactly like a
    /// manual meal (same outbox/sync path). The page's meal type, eaten-at,
    /// notes and photo still apply — menus are meal-type free (A9).
    private func logFromMenu(_ menu: NamedMenu) {
        guard !isSubmitting else { return }
        JournalKeyboardDismisser.resign()
        isSubmitting = true
        message = nil
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = UUID()
        Task { @MainActor in
            let draft = MealDraft(
                mealType: mealType,
                eatenAt: eatenAt,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                items: menu.items.map { item in
                    item.draft(menuGroupID: groupID, menuName: menu.name)
                }
            )
            let didSave = await viewModel.addMeal(draft: draft, photo: photo)
            if didSave {
                onClose()
            } else {
                message = viewModel.errorMessage ?? "The meal could not be saved."
                isSubmitting = false
            }
        }
    }
}

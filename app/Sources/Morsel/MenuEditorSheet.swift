import SwiftUI

// Issue #152 — paper editor sheet for one named menu (create or edit).
// The menu name is meal-type-free; items carry name + quantity + unit and
// optional calories. Saving validates through MenuEditorDraft and lets the
// shared MenuLibraryModel own the repository write + list refresh.

struct MenuEditorSheet: View {
    let title: String
    @ObservedObject var model: MenuLibraryModel
    /// Existing menu being edited (nil = create new).
    let menu: NamedMenu?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var rows: [EditableMenuItem] = []
    @State private var isSaving = false
    @State private var errorText: String?
    /// AC6 focus contract: each ruled field owns one key (rows keyed by id).
    private enum MenuKey: Hashable {
        case name, food(UUID), quantity(UUID), calories(UUID)
    }

    @FocusState private var focusedKey: MenuKey?

    init(
        title: String,
        model: MenuLibraryModel,
        menu: NamedMenu? = nil,
        onSaved: @escaping () -> Void
    ) {
        self.title = title
        self.model = model
        self.menu = menu
        self.onSaved = onSaved
        _name = State(initialValue: menu?.name ?? "")
        _rows = State(initialValue: menu.map { menu in
            menu.items.map(EditableMenuItem.init)
        } ?? [EditableMenuItem()])
    }

    private var canSave: Bool {
        !isSaving && draft.isValid
    }

    private var draft: MenuEditorDraft {
        MenuEditorDraft(
            name: name,
            items: rows.compactMap { $0.templateItem() }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.morselBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        if let errorText {
                            Text(errorText)
                                .font(.morselBody)
                                .foregroundStyle(Color.morselOver)
                                .padding(.bottom, 8)
                        }
                        JournalPaperField(
                            label: "Menu name", text: $name, focus: $focusedKey, key: .name,
                            prompt: "e.g. Breakfast set", keyboardType: .default,
                            hint: "Required — menus are meal-type free"
                        )
                        .padding(.bottom, 16)
                        SectionHeading(title: "Items")
                            .padding(.bottom, 10)
                        ForEach($rows) { $row in
                            itemRow($row)
                            Rectangle()
                                .fill(Color.morselInkLine.opacity(0.3))
                                .frame(height: 0.5)
                                .padding(.vertical, 4)
                        }
                        Button {
                            rows.append(EditableMenuItem())
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.morselForest)
                                Text("Add item")
                                    .font(.morselBodyStrong)
                                    .foregroundStyle(Color.morselInk)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                    }
                    .padding(16)
                }
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .morselResignsKeyboardOnTap()
    }

    private var header: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .font(.morselBodyStrong)
            .foregroundStyle(Color.morselForest)
            .disabled(isSaving)
            Spacer()
            Text(title)
                .font(Font.morselHand(size: 20))
                .foregroundStyle(Color.morselInk)
            Spacer()
            Button(isSaving ? "Saving…" : "Save") {
                save()
            }
            .font(.morselBodyStrong)
            .foregroundStyle(canSave ? Color.morselForest : Color.morselInkThree)
            .disabled(!canSave)
        }
        .padding(.bottom, 14)
    }

    private func itemRow(_ row: Binding<EditableMenuItem>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                JournalPaperField(
                    label: "Food", text: row.name, focus: $focusedKey, key: .food(row.wrappedValue.id),
                    prompt: "Food name", keyboardType: .default,
                    hint: "Required"
                )
                Button {
                    rows.removeAll { $0.id == row.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.morselBodyStrong)
                        .foregroundStyle(Color.morselInkThree)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove item")
                .padding(.top, 6)
            }
            HStack(alignment: .top, spacing: 10) {
                JournalPaperField(
                    label: "Quantity", text: row.quantity, focus: $focusedKey, key: .quantity(row.wrappedValue.id),
                    keyboardType: .decimalPad, monospacedValue: true,
                    hint: "Positive number"
                )
                .frame(maxWidth: 120)
                Picker("Unit", selection: row.unit) {
                    ForEach(FoodUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Color.morselInkTwo)
                .fixedSize()
                Spacer(minLength: 0)
            }
            JournalPaperField(
                label: "Calories", text: row.calories, focus: $focusedKey, key: .calories(row.wrappedValue.id),
                unit: "kcal", prompt: "Optional", keyboardType: .decimalPad, monospacedValue: true
            )
        }
        .padding(.vertical, 6)
    }

    private func save() {
        errorText = nil
        guard draft.isValid else {
            errorText = "Give the menu a name and at least one item before saving."
            return
        }
        isSaving = true
        Task { @MainActor in
            let saved = await model.save(editor: draft, editing: menu?.menuID)
            if saved {
                onSaved()
                dismiss()
            } else {
                errorText = model.errorMessage ?? "The menu could not be saved."
                isSaving = false
            }
        }
    }
}

/// One editable item row inside the menu editor (string fields until save).
struct EditableMenuItem: Identifiable {
    let id = UUID()
    var name = ""
    var quantity = "1"
    var unit = FoodUnit.serving
    var calories = ""

    init() {}

    init(_ item: MenuTemplateItem) {
        name = item.name
        quantity = Self.quantityText(item.quantity)
        unit = item.unit
        calories = item.caloriesKcal.map(Self.quantityText) ?? ""
    }

    func templateItem() -> MenuTemplateItem? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let quantityValue = Double(quantity), quantityValue.isFinite, quantityValue > 0 else {
            return nil
        }
        let trimmedKcal = calories.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKcal.isEmpty {
            guard let kcalValue = Double(trimmedKcal), kcalValue.isFinite, kcalValue >= 0 else {
                return nil
            }
            return MenuTemplateItem(
                name: trimmedName, quantity: quantityValue, unit: unit, caloriesKcal: kcalValue
            )
        }
        return MenuTemplateItem(
            name: trimmedName, quantity: quantityValue, unit: unit, caloriesKcal: nil
        )
    }

    /// Quantity/calories text that keeps meaningful fractions ("1.5") but
    /// drops noise ("1.500000").
    private static func quantityText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }
}

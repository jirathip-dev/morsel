import SwiftUI
import UIKit

// Issue #105 — Edit Item stays a modal (issue AC3 permits it) but reads as the
// journal contract: paper ground, spine furniture, ruled paper fields (AC5),
// and the shared focus/keyboard rules (AC6) instead of stock Form cells.
// Issue #153 adds the meal-photo surface (view + attach/replace).
// Issue #229 — the sheet body now follows the approved Variant A detail/edit
// composition: the design's head (eyebrow + subject), its subject/summary line,
// the evidence block (source · confidence · estimation notes), the photo
// figure, and the `.state` + `.save` block with the local note. The native
// navigation and gesture mechanics are deliberately untouched (Cancel keeps
// its header affordance; the save action moves onto A's own button), and the
// ruled journal fields stay the #105 input language.

struct MealItemEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Issue #153 — the photo surface loads through the same repository the
    /// shell journal uses and attaches through the outbox/image pipeline;
    /// the shell injects the shared view model into the environment.
    @EnvironmentObject private var viewModel: DashboardViewModel
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
    /// Issue #153 — photo picked for attach/replace; saved with the item.
    @State private var pendingPhoto: FoodImageUpload?
    @State private var isProcessingPhoto = false

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
                    trailingDisabled: isSaving || isProcessingPhoto
                )

                detailHead

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
                Text("Corrections are saved as a manual edit; macros you change stay as you typed them.")
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
                    .padding(.top, 10)

                MealItemDetails(item: item)

                // Issue #153/#229 — the meal photo is part of the correction
                // sheet (shows the photo the item's meal was logged with, fresh
                // re-mint; queued rows render their durable local bytes), and
                // attach/replace saves through the outbox/image pipeline.
                SectionHeading(title: "Photo")
                    .padding(.bottom, 10)
                MealPhotoEditorSection(
                    item: item,
                    repository: viewModel.repository,
                    userID: viewModel.userID,
                    pendingPhoto: $pendingPhoto,
                    isDisabled: isSaving,
                    isProcessingPhoto: $isProcessingPhoto
                )

                saveBlock
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
                // Issue #153 — a picked photo attaches through the SAME
                // outbox/image pipeline as Add Meal before the item update;
                // a refusal keeps the sheet open with the honest message.
                if let pendingPhoto {
                    let didAttach = await viewModel.attachPhoto(pendingPhoto, toItem: item.itemID)
                    guard didAttach else {
                        message = viewModel.errorMessage ?? "The photo could not be attached."
                        isSaving = false
                        return
                    }
                }
                let update = try makeUpdate()
                if await onSave(update) {
                    dismiss()
                } else {
                    message = viewModel.errorMessage ?? "The item could not be updated."
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

/// Issue #229 — the sheet's Variant A chrome (the design's `.sheet-head`,
/// `.evidence`-adjacent summary and `.state`/`.save` block). A file-scope
/// extension so the shipped struct stays inside the repo lint budget.
private extension MealItemEditSheet {
    /// The design's sheet head: the small eyebrow over the subject line, then
    /// the recorded portion/macros the sheet is correcting.
    var detailHead: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Food detail")
                .morselSectionLabel()
            Text(item.name)
                .font(Font.morselHand(size: 30))
                .foregroundStyle(Color.morselInk)
                .padding(.top, 5)
            Text(summaryLine)
                .font(.morselSerif(size: 18))
                .foregroundStyle(Color.morselInkTwo)
                .padding(.top, 6)
        }
        .padding(.bottom, 18)
    }

    var summaryLine: String {
        var parts = [MorselFormat.portion(quantity: item.quantity, unit: item.unit)]
        if let protein = item.proteinG { parts.append("P \(MorselFormat.number(protein))g") }
        if let carbs = item.carbsG { parts.append("C \(MorselFormat.number(carbs))g") }
        if let fat = item.fatG { parts.append("F \(MorselFormat.number(fat))g") }
        return parts.joined(separator: " · ")
    }

    /// The design's `.state` line and `.save` button plus its local note:
    /// pending is stated while the save runs, a refusal keeps the edit in
    /// place and states the failure, and Save stays available for a retry.
    /// Nothing here claims a result that did not happen.
    var saveBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message {
                Text(message)
                    .font(.morselSerif(size: 17))
                    .foregroundStyle(Color.morselOver)
                    .padding(.leading, 10)
                    .padding(.vertical, 2)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.morselOver).frame(width: 2)
                    }
                    .padding(.top, 14)
            } else if isSaving {
                Text("Saving…")
                    .font(.morselSerif(size: 17))
                    .foregroundStyle(Color.morselInkTwo)
                    .padding(.top, 14)
            }
            Button(action: save) {
                Text("Save edit")
                    .font(.morselSerif(size: 20))
                    .foregroundStyle(Color.morselLabelOnAccent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.morselAccent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(isSaving || isProcessingPhoto)
            .opacity(isSaving || isProcessingPhoto ? 0.6 : 1)
            .morselResignsKeyboardOnTap()
            .padding(.top, 14)
            Text("Changes stay in your journal; a row that has not synced keeps its marker.")
                .font(.morselSerif(size: 13))
                .foregroundStyle(Color.morselInkTwo)
                .padding(.top, 8)
        }
        .padding(.top, 4)
    }
}

/// Issue #227 — the food sheet's compact secondary details area: the source
/// line (unchanged), the confidence value, the low-confidence cue the row's
/// retired tint used to carry, and any agent estimation notes. Everything
/// here is read-only metadata: the sheet's fields own every edit and Save
/// keeps its shipped behaviour. Issue #229 — laid out as the design's
/// `.evidence` block: hairline-ruled, source and confidence on the first line,
/// the estimation notes beneath.
private struct MealItemDetails: View {
    let item: MealItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Source: \(item.provenance.rawValue) · Confidence:")
                    .font(.morselSerif(size: 16))
                    .foregroundStyle(Color.morselInk)
                Text(MorselFormat.confidence(item.confidence))
                    .font(.morselMono(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.morselInk)
                Spacer(minLength: 0)
            }
            if let confidenceNote {
                Text(confidenceNote)
                    .font(.morselData)
                    .foregroundStyle(Color.morselReview)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.morselAccentSoft, in: RoundedRectangle(cornerRadius: 4))
            }
            Text(agentNotes ?? "No estimation notes were recorded.")
                .font(.morselSerif(size: 16))
                .foregroundStyle(Color.morselInkTwo)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.morselLine).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.morselLine).frame(height: 1)
        }
        .padding(.top, 16)
        .accessibilityElement(children: .combine)
    }

    /// The row's former warning tint is re-homed here, behind the SAME
    /// `needsReview` predicate, so uncertainty handling is preserved.
    private var confidenceNote: String? {
        guard item.needsReview else { return nil }
        return DashboardMath.confidenceBadge(for: item.confidence) == .missing
            ? "confidence missing"
            : "low confidence"
    }

    /// Agent estimation notes verbatim; the manual-edit sentinel is source
    /// bookkeeping, never estimation copy.
    private var agentNotes: String? {
        guard let notes = item.notes, !notes.isEmpty, notes != MealSource.manualEdit.rawValue else {
            return nil
        }
        return notes
    }
}

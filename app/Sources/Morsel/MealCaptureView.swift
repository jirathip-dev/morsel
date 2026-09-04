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
    @State private var isShowingCamera = false
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

                SectionHeading(title: "Photo")
                    .padding(.vertical, 10)
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    paperActionRow(icon: "photo.on.rectangle", title: "Choose a meal photo")
                }
                .disabled(isProcessingPhoto || isSubmitting)

                Button {
                    JournalKeyboardDismisser.resign()
                    isShowingCamera = true
                } label: {
                    paperActionRow(icon: "camera", title: "Take a photo")
                }
                .buttonStyle(.plain)
                .disabled(
                    !UIImagePickerController.isSourceTypeAvailable(.camera)
                        || isProcessingPhoto
                        || isSubmitting
                )
                .opacity(
                    !UIImagePickerController.isSourceTypeAvailable(.camera)
                        || isProcessingPhoto
                        || isSubmitting ? 0.55 : 1
                )

                if !UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Text("Camera is unavailable in this simulator.")
                        .font(.morselData)
                        .foregroundStyle(Color.morselInkTwo)
                }

                if isProcessingPhoto {
                    HStack(spacing: 8) {
                        ProgressView().tint(Color.morselAccent)
                        Text("Preparing photo")
                            .font(.morselBody)
                            .foregroundStyle(Color.morselInkTwo)
                    }
                    .padding(.top, 4)
                }

                if let photo {
                    HStack(spacing: 10) {
                        if let image = UIImage(data: photo.data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Photo ready")
                                .font(.morselBodyStrong)
                            Text("JPEG · \(photo.data.count / 1_024) KB")
                                .font(.morselData)
                                .foregroundStyle(Color.morselInkTwo)
                        }
                        Spacer()
                        Button("Remove") {
                            self.photo = nil
                            pickerItem = nil
                        }
                        .font(.morselData)
                        .foregroundStyle(Color.morselForest)
                    }
                    .padding(.top, 6)
                }

                JournalRule()
                    .padding(.vertical, 16)
                SectionHeading(title: "Meal")
                    .padding(.bottom, 10)
                mealTypeRow
                    .padding(.bottom, 6)
                eatenAtRow
                    .padding(.bottom, 14)
                JournalPaperField(
                    label: "Notes",
                    text: $notes,
                    focus: $focusedField,
                    key: .notes,
                    prompt: "Notes (optional)",
                    axis: .vertical,
                    keyboardType: .default,
                    hint: "Optional notes about the meal"
                )

                JournalRule()
                    .padding(.vertical, 16)
                SectionHeading(title: "Food")
                    .padding(.bottom, 10)
                JournalPaperField(
                    label: "Food name",
                    text: $itemName,
                    focus: $focusedField,
                    key: .name,
                    prompt: "Food name",
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
                        keyboardType: .decimalPad,
                        monospacedValue: true,
                        prominent: true,
                        hint: "Positive number"
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
        .onChange(of: pickerItem) { _, item in
            guard let item else {
                return
            }
            loadPhoto(item)
        }
        .sheet(isPresented: $isShowingCamera) {
            CameraPicker(
                onCapture: { image in
                    isShowingCamera = false
                    prepareCameraImage(image)
                },
                onCancel: {
                    isShowingCamera = false
                }
            )
            .ignoresSafeArea()
        }
    }

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
                    label: "Calories",
                    text: calories,
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
                    text: protein,
                    focus: $focusedField,
                    key: .protein,
                    unit: "g",
                    prompt: "Optional",
                    keyboardType: .decimalPad,
                    monospacedValue: true,
                    hint: "Zero or greater"
                )
            }
            HStack(alignment: .top, spacing: 14) {
                JournalPaperField(
                    label: "Carbs",
                    text: carbs,
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
                    text: fat,
                    focus: $focusedField,
                    key: .fat,
                    unit: "g",
                    prompt: "Optional",
                    keyboardType: .decimalPad,
                    monospacedValue: true,
                    hint: "Zero or greater"
                )
            }
        }
    }

    private func paperActionRow(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.morselBodyStrong)
                .foregroundStyle(Color.morselForest)
            Text(title)
                .font(.morselBodyStrong)
                .foregroundStyle(Color.morselInk)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func keyboardType(for key: AddMealFieldKey) -> UIKeyboardType {
        switch key {
        case .notes, .name:
            return .default
        case .quantity, .calories, .protein, .carbs, .fat:
            return .decimalPad
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        isProcessingPhoto = true
        message = nil
        Task { @MainActor in
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw FoodImageError.invalidImage
                }
                let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? ""
                photo = try FoodImageCompressor.prepare(data: data, mimeType: mimeType)
            } catch {
                message = DashboardUserMessage.userMessage(for: error)
            }
            isProcessingPhoto = false
        }
    }

    private func prepareCameraImage(_ image: UIImage) {
        isProcessingPhoto = true
        message = nil
        Task { @MainActor in
            do {
                photo = try FoodImageCompressor.compress(image)
            } catch {
                message = DashboardUserMessage.userMessage(for: error)
            }
            isProcessingPhoto = false
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
}

struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        _ = picker
        _ = context
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            } else {
                parent.onCancel()
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
            picker.dismiss(animated: true)
        }
    }
}

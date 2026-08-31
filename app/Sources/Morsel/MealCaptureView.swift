import PhotosUI
import SwiftUI
import UIKit

struct AddMealView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
            Form {
                Section("Photo") {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose a meal photo", systemImage: "photo.on.rectangle")
                    }
                    .disabled(isProcessingPhoto || isSubmitting)

                    Button {
                        isShowingCamera = true
                    } label: {
                        Label("Take a photo", systemImage: "camera")
                    }
                    .disabled(
                        !UIImagePickerController.isSourceTypeAvailable(.camera)
                            || isProcessingPhoto
                            || isSubmitting
                    )

                    if !UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Text("Camera is unavailable in this simulator.")
                            .font(.morselData)
                            .foregroundStyle(Color.morselInkTwo)
                    }

                    if isProcessingPhoto {
                        ProgressView("Preparing photo")
                            .tint(Color.morselAccent)
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
                    }
                }

                Section("Meal") {
                    Picker("Meal type", selection: $mealType) {
                        ForEach(MealType.allCases, id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    DatePicker("Eaten at", selection: $eatenAt)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                }

                Section("Food") {
                    TextField("Food name", text: $itemName)
                    HStack {
                        TextField("Quantity", text: $quantity)
                            .keyboardType(.decimalPad)
                        Picker("Unit", selection: $unit) {
                            ForEach(FoodUnit.allCases, id: \.self) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    TextField("Calories (optional)", text: $calories)
                        .keyboardType(.decimalPad)
                    TextField("Protein grams (optional)", text: $protein)
                        .keyboardType(.decimalPad)
                    TextField("Carbs grams (optional)", text: $carbs)
                        .keyboardType(.decimalPad)
                    TextField("Fat grams (optional)", text: $fat)
                        .keyboardType(.decimalPad)
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
            .navigationTitle("Add meal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Saving…" : "Save meal") {
                        save()
                    }
                    .disabled(
                        isSubmitting
                            || isProcessingPhoto
                            || itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
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
                message = error.localizedDescription
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
                message = error.localizedDescription
            }
            isProcessingPhoto = false
        }
    }

    private func save() {
        isSubmitting = true
        message = nil
        Task { @MainActor in
            do {
                let draft = try makeDraft()
                let didSave = await viewModel.addMeal(draft: draft, photo: photo)
                if didSave {
                    dismiss()
                } else {
                    message = viewModel.errorMessage ?? "The meal could not be saved."
                }
            } catch {
                message = error.localizedDescription
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

import PhotosUI
import SwiftUI
import UIKit

// Issue #152 — Add-Meal photo capture section. Extracted from MealCaptureView
// (the Add Meal page grew a 'Log from menu' section; the shipped file budget
// requires the photo chrome to live in its own file). Behavior is unchanged:
// pick/photo, camera sheet, preparing state, ready summary with remove.

struct AddMealPhotoSection: View {
    @Binding var pickerItem: PhotosPickerItem?
    @Binding var photo: FoodImageUpload?
    /// Add-Meal page error line (photo failures surface there, above the
    /// section, exactly like save failures).
    @Binding var message: String?
    /// Save in flight — photo controls stand down while submitting.
    let isSubmitting: Bool
    /// Photo prep in flight (page-owned so the Save button stands down too).
    @Binding var isProcessingPhoto: Bool

    @State private var isShowingCamera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
}

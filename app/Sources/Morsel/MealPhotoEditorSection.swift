import PhotosUI
import SwiftUI
import UIKit

// Issue #153 — the Edit-item sheet photo surface. The meal's existing photo
// renders through the SAME re-minting download pipeline as the Today/History
// thumbnails (a fresh download per appearance — an expired read-model signed
// URL never hides a stored photo, #133 contract), and the user can attach or
// replace it from the library or camera. The prepared upload is handed to the
// hosting sheet via `pendingPhoto` and saved through the outbox/image
// pipeline when the sheet's Save runs — never a direct storage write.
struct MealPhotoEditorSection: View {
    let item: MealItem
    let repository: any DashboardRepository
    let userID: UUID
    /// Photo chosen for this edit but not yet saved (replaces on Save).
    @Binding var pendingPhoto: FoodImageUpload?
    /// Disables the pickers while the sheet is saving (mirrors Add Meal).
    let isDisabled: Bool
    /// True while a picked photo is being compressed; the sheet blocks Save
    /// so an in-flight pick is never silently dropped (mirrors Add Meal).
    @Binding var isProcessingPhoto: Bool

    @State private var pickerItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var existingImage: UIImage?
    @State private var existingImageFailed = false
    @State private var message: String?

    private var existingPath: String? {
        item.mealImage?.path
    }

    /// Issue #199 — the shared artwork decision for THIS item: a stored photo
    /// wins; otherwise the approved offline illustration (or nil when the food
    /// is not in the approved library).
    private var illustrationResolution: FoodArtworkResolution? {
        guard case let .illustration(resolution) = MealArtworkPresentation.resolve(
            photoPath: existingPath, items: [item]
        ) else {
            return nil
        }
        return resolution
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message {
                Text(message)
                    .font(.morselBody)
                    .foregroundStyle(Color.morselOver)
                    .padding(.bottom, 10)
            }

            if let pendingPhoto {
                pendingPreview(pendingPhoto)
                    .padding(.bottom, 8)
            } else if let existingPath {
                existingPhotoRow(path: existingPath)
                    .padding(.bottom, 8)
            } else if let illustrationResolution {
                // Issue #199 — no meal photo yet: the approved offline
                // illustration stands in, labeled; an unmatched food shows
                // nothing (exactly today's behavior).
                illustrationRow(illustrationResolution)
                    .padding(.bottom, 8)
            }

            PhotosPicker(selection: $pickerItem, matching: .images) {
                actionRow(icon: "photo.on.rectangle", title: "Choose a meal photo")
            }
            .disabled(isDisabled || isProcessingPhoto)

            Button {
                JournalKeyboardDismisser.resign()
                isShowingCamera = true
            } label: {
                actionRow(icon: "camera", title: "Take a photo")
            }
            .buttonStyle(.plain)
            .disabled(
                !UIImagePickerController.isSourceTypeAvailable(.camera)
                    || isDisabled
                    || isProcessingPhoto
            )
            .opacity(
                !UIImagePickerController.isSourceTypeAvailable(.camera)
                    || isDisabled
                    || isProcessingPhoto ? 0.55 : 1
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

    private func pendingPreview(_ photo: FoodImageUpload) -> some View {
        HStack(spacing: 10) {
            if let image = UIImage(data: photo.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Photo ready")
                    .font(.morselBodyStrong)
                Text("JPEG · \\(photo.data.count / 1_024) KB")
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
            }
            Spacer()
            Button("Remove") {
                self.pendingPhoto = nil
                pickerItem = nil
            }
            .font(.morselData)
            .foregroundStyle(Color.morselForest)
            .disabled(isDisabled)
        }
    }

    private func existingPhotoRow(path: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let existingImage {
                    Image(uiImage: existingImage)
                        .resizable()
                        .scaledToFill()
                } else if existingImageFailed {
                    ZStack {
                        Image(systemName: "photo")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.morselInkThree)
                    }
                } else {
                    ZStack {
                        Image(systemName: "photo")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.morselInkThree)
                        ProgressView()
                            .tint(Color.morselAccent)
                    }
                }
            }
            .frame(width: 72, height: 72)
            .background(Color.morselSurfaceTwo)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Meal photo")

            VStack(alignment: .leading, spacing: 3) {
                Text("Meal photo")
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInk)
                Text("The photo this meal was logged with")
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
            }
            Spacer(minLength: 0)
        }
        .task(id: path) {
            await loadExistingPhoto(path: path)
        }
    }

    /// Issue #199 — the photo-less stand-in: the approved 64px study beside
    /// its honest label. Food studies read "Illustration · not a meal photo";
    /// category fallbacks keep their category label (ART-SPEC) and are never
    /// presented as an identified food.
    private func illustrationRow(_ resolution: FoodArtworkResolution) -> some View {
        HStack(alignment: .center, spacing: 12) {
            MealArtworkSlot.illustration(
                resolution, size: CGFloat(FoodArtworkImageStore.pixelSize)
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(illustrationTitle(resolution))
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInk)
                Text(illustrationCopy(resolution))
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
            }
            Spacer(minLength: 0)
        }
    }

    private func illustrationTitle(_ resolution: FoodArtworkResolution) -> String {
        switch resolution {
        case let .food(asset): return asset.name
        case let .category(asset): return "\(asset.categoryLabel) · fallback"
        case .none: return ""
        }
    }

    private func illustrationCopy(_ resolution: FoodArtworkResolution) -> String {
        switch resolution {
        case .food: return "Illustration · not a meal photo"
        case .category: return "Category fallback · not identified food"
        case .none: return ""
        }
    }

    private func actionRow(icon: String, title: String) -> some View {
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

    private func loadExistingPhoto(path: String) async {
        existingImage = nil
        existingImageFailed = false
        do {
            let data = try await repository.loadMealImage(userID: userID, path: path)
            existingImage = data.isEmpty ? nil : UIImage(data: data)
            existingImageFailed = existingImage == nil
        } catch {
            existingImageFailed = true
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
                pendingPhoto = try FoodImageCompressor.prepare(data: data, mimeType: mimeType)
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
                pendingPhoto = try FoodImageCompressor.compress(image)
            } catch {
                message = DashboardUserMessage.userMessage(for: error)
            }
            isProcessingPhoto = false
        }
    }
}

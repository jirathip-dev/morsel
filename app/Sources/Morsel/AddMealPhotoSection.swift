import PhotosUI
import SwiftUI
import UIKit

// Issue #152 — Add-Meal photo capture section. Extracted from MealCaptureView
// (the Add Meal page grew a 'Log from menu' section; the shipped file budget
// requires the photo chrome to live in its own file). Behavior is unchanged:
// pick/photo, camera sheet, preparing state, ready summary with remove.

// Issue #187 — the publication gate both photo surfaces share (Add Meal here
// and the Edit-item sheet's MealPhotoEditorSection): a newer pick, Remove, or
// leaving the route retires the in-flight preparation, so its late result or
// error can never publish, and a failure that IS current reports the error
// line while the previous photo/draft stays exactly as it was.

/// The settled outcome of one preparation, resolved against its stamp.
enum MealPhotoPreparationOutcome: Equatable {
    /// Still the newest preparation: store this upload.
    case publish(FoodImageUpload)
    /// Still the newest preparation: show this error line; the previous photo
    /// (or draft) is left untouched.
    case report(String)
    /// Retired by a newer pick, Remove, or leaving the route: publish nothing.
    case discard
}

struct MealPhotoPreparationGate: Equatable {
    private(set) var generation = 0

    /// Starts a preparation and returns its stamp; every older stamp retires.
    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    /// Retires every in-flight preparation (Remove / leaving the route).
    mutating func invalidate() {
        generation += 1
    }

    func isCurrent(_ stamp: Int) -> Bool {
        stamp == generation
    }

    /// Settles a finished preparation: a retired stamp publishes nothing, a
    /// current failure reports its message, and a current result is the only
    /// thing that replaces the surface's photo.
    func settle(
        _ result: Result<FoodImageUpload, Error>,
        for stamp: Int
    ) -> MealPhotoPreparationOutcome {
        guard isCurrent(stamp) else {
            return .discard
        }
        switch result {
        case let .success(upload):
            return .publish(upload)
        case let .failure(error):
            return .report(DashboardUserMessage.userMessage(for: error))
        }
    }

    /// The shipped settle mapping, shared by both surfaces (only `.publish`
    /// replaces the photo, only `.report` writes the error line).
    static func apply(
        _ outcome: MealPhotoPreparationOutcome,
        photo: inout FoodImageUpload?,
        message: inout String?
    ) {
        switch outcome {
        case let .publish(upload):
            photo = upload
        case let .report(text):
            message = text
        case .discard:
            break
        }
    }
}

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
    /// Issue #187 — stamps every preparation so a late result or error from a
    /// replaced pick, a removed photo, or a left page never publishes.
    @State private var preparation = MealPhotoPreparationGate()
    /// Issue #187 — the in-flight off-main preparation, cancelled by a newer
    /// pick, Remove, or the page going away.
    @State private var preparationTask: Task<Void, Never>?

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
                        cancelPreparation()
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
        .onDisappear {
            // Issue #187 — leaving the page retires the in-flight preparation
            // so its late result/error publishes nothing.
            cancelPreparation()
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
        preparePhoto {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw FoodImageError.invalidImage
            }
            let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? ""
            return try await MealPhotoPreparationWorker.shared.prepare(data: data, mimeType: mimeType)
        }
    }

    private func prepareCameraImage(_ image: UIImage) {
        preparePhoto {
            try await MealPhotoPreparationWorker.shared.compress(image)
        }
    }

    /// Issue #187 — runs ONE preparation on the bounded off-main worker and
    /// settles it through the gate: only the newest stamp publishes, and a
    /// failure leaves the current photo exactly as it was.
    private func preparePhoto(_ work: @escaping () async throws -> FoodImageUpload) {
        let stamp = beginPreparation()
        preparationTask = Task { @MainActor in
            let outcome: MealPhotoPreparationOutcome
            do {
                outcome = preparation.settle(.success(try await work()), for: stamp)
            } catch {
                outcome = preparation.settle(.failure(error), for: stamp)
            }
            if preparation.isCurrent(stamp) {
                isProcessingPhoto = false
            }
            MealPhotoPreparationGate.apply(outcome, photo: &photo, message: &message)
        }
    }

    /// Starts a preparation: the page shows the honest "Preparing photo" state
    /// until THIS stamp settles, and every older stamp retires (its late
    /// result/error can no longer publish).
    private func beginPreparation() -> Int {
        preparationTask?.cancel()
        message = nil
        isProcessingPhoto = true
        return preparation.begin()
    }

    /// Retires the in-flight preparation (newer pick, Remove, leaving the
    /// page): its late result/error publishes nothing.
    private func cancelPreparation() {
        preparationTask?.cancel()
        preparationTask = nil
        preparation.invalidate()
        isProcessingPhoto = false
    }
}

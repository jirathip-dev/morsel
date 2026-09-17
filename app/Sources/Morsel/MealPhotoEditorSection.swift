import PhotosUI
import SwiftUI
import UIKit

// Issue #153 — the Edit-item sheet photo surface. The meal's existing photo
// renders through the #188 prepared-thumbnail cache (issue #188: one coalesced
// fetch + one off-body preparation per account/object/revision/target-pixels
// identity, warm revisits reuse the prepared image, memory bounded), and the
// user can attach or replace it from the library or camera. The prepared
// upload is handed to the hosting sheet via `pendingPhoto` and saved through
// the outbox/image pipeline when the sheet's Save runs — never a direct
// storage write.
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
    /// Issue #188 — the prepared-thumbnail cache this surface reads through.
    var thumbnailCache: MealThumbnailCache = .shared

    @State private var pickerItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var existingImage: UIImage?
    @State private var existingImageFailed = false
    @Environment(\.displayScale) private var displayScale
    @State private var message: String?
    /// Issue #187 — stamps every preparation so a late result or error from a
    /// replaced pick, a removed photo, or a left sheet never publishes.
    @State private var preparation = MealPhotoPreparationGate()
    /// Issue #187 — the in-flight off-main preparation, cancelled by a newer
    /// pick, Remove, or the sheet going away.
    @State private var preparationTask: Task<Void, Never>?

    private var existingPath: String? {
        item.mealImage?.path
    }

    /// Issue #199/#223 — the shared artwork decision for THIS item: a stored
    /// photo wins in detail/edit; otherwise the approved offline illustration
    /// (an approved Variant A study first — issue #229 — then the #199 library
    /// study/category fallback, and the neutral eating sign for an unmatched
    /// food; an unknown food no longer shows nothing).
    private var journalArtwork: JournalRowArtwork {
        JournalRowArtwork.resolve(items: [item])
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
            } else if journalArtwork != .none {
                // Issue #199/#223/#229 — no meal photo yet: the approved
                // offline illustration stands in, labeled (an A study, a
                // library study/category fallback, or the neutral sign).
                illustrationRow(journalArtwork)
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
                    .font(.morselValue)
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
        .onDisappear {
            // Issue #187 — leaving the sheet retires the in-flight preparation
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

    private func pendingPreview(_ photo: FoodImageUpload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            photoFigure(UIImage(data: photo.data), unavailable: false)
            HStack(spacing: 8) {
                Text("Photo ready · JPEG · \(photo.data.count / 1_024) KB")
                    .font(.morselSerif(size: 13))
                    .foregroundStyle(Color.morselInkTwo)
                Spacer(minLength: 0)
                Button("Remove") {
                    self.pendingPhoto = nil
                    pickerItem = nil
                    cancelPreparation()
                }
                .font(.morselValue)
                .foregroundStyle(Color.morselForest)
                .disabled(isDisabled)
            }
        }
    }

    private func existingPhotoRow(path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            photoFigure(existingImage, unavailable: existingImageFailed)
            Text("The photo this meal was logged with.")
                .font(.morselSerif(size: 13))
                .foregroundStyle(Color.morselInkTwo)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meal photo")
        .task(id: path) {
            await loadExistingPhoto(path: path)
        }
    }

    /// Issue #229 — the design's `.photo` figure: a full-width 145pt frame on
    /// the field ground with the image contained (never cropped), and its
    /// caption under it. The shipped loading/failure states are unchanged.
    private func photoFigure(_ image: UIImage?, unavailable: Bool) -> some View {
        ZStack {
            Color.morselSurfaceTwo
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if unavailable {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.morselInkThree)
            } else {
                ProgressView()
                    .tint(Color.morselAccent)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 145)
        .accessibilityHidden(true)
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

    /// Issue #188 — reads the prepared thumbnail through the cache: the
    /// account/object/revision/target-pixels identity, one coalesced fetch and
    /// one off-body preparation, bounded memory. `@MainActor` because the result
    /// lands in this view's state — a `@State` write that happens off the main
    /// actor does not invalidate the view (the base loader's shape, an
    /// unisolated async function, wrote state from whichever executor resumed
    /// it).
    @MainActor
    private func loadExistingPhoto(path: String) async {
        existingImage = nil
        existingImageFailed = false
        do {
            existingImage = try await thumbnailCache.thumbnail(
                MealThumbnailRequest(
                    accountID: userID,
                    objectPath: path,
                    displayBox: MealThumbnailMetrics.photoFigureBox,
                    displayScale: displayScale
                ),
                from: MealPhotoSource(repository: repository)
            )
        } catch {
            existingImageFailed = true
        }
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
    /// settles it through the gate: only the newest stamp publishes (as the
    /// sheet's pending photo), and a failure reports the error line while the
    /// pending photo/draft stays exactly as it was.
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
            MealPhotoPreparationGate.apply(outcome, photo: &pendingPhoto, message: &message)
        }
    }

    /// Starts a preparation: the sheet shows the honest "Preparing photo"
    /// state (and blocks Save) until THIS stamp settles, and every older stamp
    /// retires so a late result/error can no longer publish.
    private func beginPreparation() -> Int {
        preparationTask?.cancel()
        message = nil
        isProcessingPhoto = true
        return preparation.begin()
    }

    /// Retires the in-flight preparation (newer pick, Remove, leaving the
    /// sheet): its late result/error publishes nothing.
    private func cancelPreparation() {
        preparationTask?.cancel()
        preparationTask = nil
        preparation.invalidate()
        isProcessingPhoto = false
    }
}

/// Issue #229 — the photo-less stand-in helpers (a file-scope extension so
/// the shipped struct stays inside the repo lint budget).
private extension MealPhotoEditorSection {
    /// Issue #199/#229 — the photo-less stand-in: the approved study beside
    /// its honest label. Food studies read "Illustration · not a meal photo";
    /// category fallbacks keep their category label (ART-SPEC) and are never
    /// presented as an identified food; the neutral sign is never an
    /// identified food either.
    private func illustrationRow(_ artwork: JournalRowArtwork) -> some View {
        HStack(alignment: .center, spacing: 12) {
            MealArtworkSlot.artwork(
                artwork, size: CGFloat(FoodArtworkImageStore.pixelSize)
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(illustrationTitle(artwork))
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInk)
                Text(illustrationCopy(artwork))
                    .font(.morselValue)
                    .foregroundStyle(Color.morselInkTwo)
            }
            Spacer(minLength: 0)
        }
    }

    private func illustrationTitle(_ artwork: JournalRowArtwork) -> String {
        switch artwork {
        case let .study(study): return study.displayName
        case let .library(resolution): return libraryIllustrationTitle(resolution)
        case .none: return ""
        }
    }

    private func libraryIllustrationTitle(_ resolution: FoodArtworkResolution) -> String {
        switch resolution {
        case let .food(asset): return asset.name
        case let .category(asset): return "\(asset.categoryLabel) · fallback"
        // The neutral sign keeps the catalog's own fallback name: it is never
        // presented as an identified food.
        case let .neutral(asset): return asset.name
        case .none: return ""
        }
    }

    private func illustrationCopy(_ artwork: JournalRowArtwork) -> String {
        switch artwork {
        case let .study(study):
            return study.isNeutralSign
                ? "Neutral sign · not identified food"
                : "Illustration · not a meal photo"
        case let .library(resolution): return libraryIllustrationCopy(resolution)
        case .none: return ""
        }
    }

    private func libraryIllustrationCopy(_ resolution: FoodArtworkResolution) -> String {
        switch resolution {
        case .food: return "Illustration · not a meal photo"
        case .category: return "Category fallback · not identified food"
        case .neutral: return "Neutral sign · not identified food"
        case .none: return ""
        }
    }
}

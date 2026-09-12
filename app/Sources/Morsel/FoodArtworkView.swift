import SwiftUI
import UIKit

// Issue #199 — the ONE illustration renderer and the ONE shared artwork slot
// used by the real Today/History rows and the item/detail sheet. The photo
// pipeline (`MealThumbnailView`) stays exactly as shipped: it is still the
// authoritative path whenever a stored meal photo exists. Illustrations only
// fill the missing-photo case, from the bundled bytes — never a fetch.

/// Paper/Night artwork selection follows the resolved journal appearance, the
/// same seam that inks the palette tokens (`MorselAppearance`).
enum FoodArtworkTheme: String, CaseIterable, Sendable {
    case paper
    case night

    static func resolve(_ scheme: ColorScheme) -> FoodArtworkTheme {
        scheme == .dark ? .night : .paper
    }

    /// Bundled PNG base name — the approved 64px export for the theme.
    func resourceName(assetID: String) -> String { "\(assetID)-\(rawValue)-64" }
}

/// Offline bundle reads for the approved library. A `Bundle` lookup only: no
/// URLSession, no image host, no generation API, nothing to wait for.
enum FoodArtworkImageStore {
    /// The approved export size bundled by this lane (64px is the ART-SPEC
    /// review target; 192/512 are not bundled because no app surface renders
    /// larger than 64pt).
    static let pixelSize = 64

    private static let cache = NSCache<NSString, UIImage>()

    static func data(assetID: String, theme: FoodArtworkTheme, bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(
            forResource: theme.resourceName(assetID: assetID), withExtension: "png"
        ) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    static func image(assetID: String, theme: FoodArtworkTheme, bundle: Bundle = .main) -> UIImage? {
        let key = "\(assetID)-\(theme.rawValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let data = data(assetID: assetID, theme: theme, bundle: bundle),
              let image = UIImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Draws one bundled 64px study at its native size with the ART-SPEC label
/// contract (a food study is labeled with its name; a category fallback is
/// labeled with its category and is never announced as an identified food).
struct FoodArtworkImageView: View {
    let assetID: String
    let label: String
    let hint: String
    var size: CGFloat = CGFloat(FoodArtworkImageStore.pixelSize)

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = FoodArtworkImageStore.image(
                assetID: assetID, theme: FoodArtworkTheme.resolve(colorScheme)
            ) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text(hint))
    }
}

/// The shared artwork slot. A stored meal photo always wins (unchanged
/// `MealThumbnailView` semantics, including loading/missing placeholders for
/// queued rows); the illustration renders only for a photo-less meal that maps
/// to an approved study; an unknown meal keeps today's empty slot.
struct MealArtworkSlot: View {
    let repository: any DashboardRepository
    let userID: UUID
    let photoPath: String?
    let items: [MealItem]
    /// Ledger photo slot — unchanged from the shipped rows.
    var photoSize: CGFloat = 44
    /// Approved native illustration placement.
    var illustrationSize: CGFloat = CGFloat(FoodArtworkImageStore.pixelSize)

    var body: some View {
        switch MealArtworkPresentation.resolve(photoPath: photoPath, items: items) {
        case let .photo(path):
            MealThumbnailView(repository: repository, userID: userID, path: path)
                .frame(width: photoSize, height: photoSize)
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.morselInkLine.opacity(0.6), lineWidth: 1)
                }
        case let .illustration(resolution):
            MealArtworkSlot.illustration(resolution, size: illustrationSize)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    static func illustration(_ resolution: FoodArtworkResolution, size: CGFloat) -> some View {
        switch resolution {
        case let .food(asset):
            FoodArtworkImageView(
                assetID: asset.id,
                label: "\(asset.name) illustration",
                hint: "Generic artwork, not a meal photo",
                size: size
            )
        case let .category(asset):
            FoodArtworkImageView(
                assetID: asset.id,
                label: "\(asset.categoryLabel) category illustration",
                hint: "Category fallback, not an identified food or meal photo",
                size: size
            )
        case .none:
            EmptyView()
        }
    }
}

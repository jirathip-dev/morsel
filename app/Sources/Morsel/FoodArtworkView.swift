import SwiftUI
import UIKit

// Issue #199 — the ONE illustration renderer and the ONE shared row artwork
// slot used by the real Today rows, the History day card/day detail rows and
// the meal/item summary rows. Issue #223 — rows are ALWAYS illustrated: a
// stored meal photo never appears in a row, and every item resolves to an
// approved study, a labeled category fallback or the neutral eating sign. The
// photo pipeline (`MealThumbnailView`) stays exactly as shipped and is the
// authoritative path inside detail/edit, never in a row.

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
/// labeled with its category and is never announced as an identified food; the
/// neutral sign is labeled as a food fallback).
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

extension MealArtworkPresentation {
    /// Issue #223 — ROW presentation: a row shows the resolved illustration and
    /// never a stored meal photo (a photo path is deliberately not an input, so
    /// the photo-first detail decision cannot leak into a row).
    static func row(
        items: [MealItem],
        assets: [FoodArtworkAsset] = FoodArtworkCatalog.bundled
    ) -> FoodArtworkResolution {
        FoodArtworkResolver.resolve(items: items, in: assets)
    }
}

/// The shared row artwork slot: the real food-item rows in Today, History and
/// the day detail, plus the meal/day summary rows. Always an approved bundled
/// illustration — exact food study, labeled category fallback, or the neutral
/// eating sign for an unknown or mixed item list; only an empty item list
/// draws nothing.
struct MealArtworkSlot: View {
    /// The items this row depicts: an item row passes its single food; a
    /// meal/day summary row passes that meal's (or day's) items.
    let items: [MealItem]
    /// Approved native illustration placement (ART-SPEC review target: 64px).
    var size: CGFloat = CGFloat(FoodArtworkImageStore.pixelSize)

    var body: some View {
        MealArtworkSlot.illustration(MealArtworkPresentation.row(items: items), size: size)
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
        case let .neutral(asset):
            FoodArtworkImageView(
                assetID: asset.id,
                label: "Food fallback illustration",
                hint: "Neutral eating sign for an unknown or mixed meal, not a meal photo",
                size: size
            )
        case .none:
            EmptyView()
        }
    }
}

import CoreGraphics
import Foundation

// Issue #188 — the identity of one prepared thumbnail, and the reason a
// prepared image can be reused at all.
//
// The audit found the deleted 56pt loader downloaded full object bytes per
// appearance, built a `UIImage` from them in the body, and shared nothing with
// any other loader. A prepared image is only reusable when the app can name
// exactly what it depicts: the ACCOUNT, the OBJECT, the REVISION of that
// object's bytes, and the TARGET PIXEL SIZE — never a bare path, a signed URL
// or a screen position.

/// The revision identity of one photo object's bytes, as this device can know
/// it WITHOUT fetching.
enum MealThumbnailRevision: Hashable, Sendable {
    /// The local outbox still holds exactly these bytes (#135 local-first
    /// reads): the revision is the content fingerprint itself, so a replaced
    /// queued photo changes the key with no extra signal.
    case queued(fingerprint: Int)
    /// The bytes come from the remote object: the revision is this device's
    /// own revalidation epoch for that object (0 until an app write or an
    /// account event bumps it — external changes are never polled).
    case remote(epoch: Int)

    var token: String {
        switch self {
        case let .queued(fingerprint): return "queued-\(fingerprint)"
        case let .remote(epoch): return "remote-\(epoch)"
        }
    }
}

/// A size in device pixels, in the cache's own terms: `CGSize` only gained
/// `Hashable` in iOS 18 and this app supports iOS 17.
struct MealThumbnailPixelSize: Hashable, Sendable {
    let width: Int
    let height: Int

    var cgSize: CGSize { CGSize(width: width, height: height) }
}

/// One prepared thumbnail's whole identity.
struct MealThumbnailKey: Hashable, Sendable {
    let accountID: UUID
    let objectPath: String
    let revision: String
    /// The display box in DEVICE PIXELS (points × display scale), so the same
    /// photo at 56pt @3x and 84pt @2x is two identities and a photo prepared
    /// for one surface is never served to another.
    let targetPixels: MealThumbnailPixelSize
}

/// One request for a prepared thumbnail: the display box in points plus the
/// display scale that box is rendered at.
struct MealThumbnailRequest: Sendable {
    let accountID: UUID
    let objectPath: String
    let displayBox: CGSize
    let displayScale: CGFloat

    /// The box in device pixels, rounded UP so a prepared image is never
    /// smaller than the pixels the surface paints.
    var targetPixels: MealThumbnailPixelSize {
        let scale = displayScale > 0 ? displayScale : 1
        return MealThumbnailPixelSize(
            width: Int(max(1, (displayBox.width * scale).rounded(.up))),
            height: Int(max(1, (displayBox.height * scale).rounded(.up)))
        )
    }

    func key(revision: String) -> MealThumbnailKey {
        MealThumbnailKey(
            accountID: accountID, objectPath: objectPath, revision: revision, targetPixels: targetPixels
        )
    }
}

/// Why a prepared thumbnail could not be produced. `missingPhoto` and
/// `corruptImage` are the shipped surface's honest "photo" state, and neither
/// caches anything.
enum MealThumbnailError: Error, Equatable {
    /// The object answered with no bytes (the #135 "no photo" answer).
    case missingPhoto
    /// The bytes are not a decodable image. Nothing is cached.
    case corruptImage
    /// The bytes decode, but no thumbnail could be rendered from them.
    case preparationFailed
}

/// The declared display boxes the shipped photo surfaces paint: the prepared
/// image is sized for the box at the device scale, so it is never upscaled.
enum MealThumbnailMetrics {
    /// `MealPhotoEditorSection`'s `.photo` figure: the sheet's full width ×
    /// the #229 design's 145pt. The width is the widest iPhone portrait width
    /// (430pt; the target device family is iPhone-only), i.e. an upper bound
    /// for the shipped figure — a phone surface never upscales it.
    static let photoFigureBox = CGSize(width: 430, height: 145)
}

import CoreGraphics
import Foundation
import ImageIO
import UIKit

// Issue #188 — off-body thumbnail preparation, plus the content fingerprint
// and pixel accounting the cache bounds itself by.

/// Issue #188 — a cheap, deterministic content fingerprint (FNV-1a, 64-bit)
/// over encoded bytes.
///
/// The SAME function names a queued photo's outbox bytes and the bytes a fetch
/// returned, so a queued→remote transition (identical payload) re-files the
/// prepared pixels instead of decoding the photo a second time.
enum MealThumbnailFingerprint {
    static func of(_ data: Data) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(truncatingIfNeeded: hash)
    }
}

/// Issue #188 — what a prepared image actually occupies, and what it costs.
enum MealThumbnailPixels {
    /// A `UIImage`'s pixel size (scale-aware).
    static func size(of image: UIImage) -> CGSize {
        let scale = image.scale > 0 ? image.scale : 1
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    /// The declared memory cost of one prepared image: RGBA bytes at its pixel
    /// size. The cache bounds resident thumbnails by this number — source
    /// bytes are never retained, so no original can accumulate.
    static func byteCost(of image: UIImage) -> Int {
        let pixels = size(of: image)
        return Int(pixels.width.rounded(.up)) * Int(pixels.height.rounded(.up)) * 4
    }
}

/// Issue #188 — the off-body thumbnail preparer.
///
/// ONE bounded worker renders prepared thumbnails: `CGImageSource` decodes the
/// source bytes directly at the target size — no full-size intermediate ever
/// exists — `kCGImageSourceCreateThumbnailWithTransform` applies the EXIF
/// orientation, and the whole synchronous body runs on this actor's executor:
/// never the main actor, never a view body.
actor MealThumbnailPreparer {
    /// What one preparation measured (the #187 trace pattern, for thumbnails):
    /// the source's oriented pixels, the pixels the surface will paint, the
    /// pixels produced, and where this synchronous body really ran.
    struct Trace: Equatable, Sendable {
        let sourcePixels: CGSize
        let targetPixels: CGSize
        let outputPixels: CGSize
        let ranOffMainThread: Bool
    }

    /// Runtime witness for the bounded-memory claim: the highest number of
    /// preparations ever in flight at once. The bodies never suspend, so this
    /// stays 1 unless the worker is made concurrent.
    private(set) var peakConcurrentPreparations = 0
    private var activePreparations = 0

    func prepare(data: Data, box: CGSize, displayScale: CGFloat) throws -> UIImage {
        try prepareTraced(data: data, box: box, displayScale: displayScale).image
    }

    /// `prepare` plus that preparation's trace.
    func prepareTraced(
        data: Data,
        box: CGSize,
        displayScale: CGFloat
    ) throws -> (image: UIImage, trace: Trace) {
        activePreparations += 1
        peakConcurrentPreparations = max(peakConcurrentPreparations, activePreparations)
        defer { activePreparations -= 1 }
        let ranOffMainThread = !Thread.isMainThread

        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw MealThumbnailError.corruptImage
        }
        let sourcePixels = try Self.orientedPixelSize(of: source)
        let target = Self.fittedPixelSize(source: sourcePixels, box: box, displayScale: displayScale)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(target.width, target.height).rounded(.up)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MealThumbnailError.preparationFailed
        }
        let image = UIImage(cgImage: thumbnail)
        return (
            image,
            Trace(
                sourcePixels: sourcePixels,
                targetPixels: target,
                outputPixels: MealThumbnailPixels.size(of: image),
                ranOffMainThread: ranOffMainThread
            )
        )
    }

    /// The source's pixel size AFTER its EXIF orientation — how the surface
    /// will display it — read from the metadata without decoding.
    static func orientedPixelSize(of source: CGImageSource) throws -> CGSize {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            throw MealThumbnailError.corruptImage
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let isQuarterTurn = [5, 6, 7, 8].contains(orientation)
        return CGSize(
            width: isQuarterTurn ? height : width,
            height: isQuarterTurn ? width : height
        )
    }

    /// The pixel size the surface will actually paint: the oriented source
    /// fitted into the display box exactly as `.scaledToFit()` fits it, then
    /// scaled by the display scale. Rounded UP, so a prepared image is never
    /// smaller than the pixels it is painted at (and never a full-size
    /// original either).
    static func fittedPixelSize(source: CGSize, box: CGSize, displayScale: CGFloat) -> CGSize {
        guard source.width > 0, source.height > 0, box.width > 0, box.height > 0, displayScale > 0 else {
            return source
        }
        let fit = min(box.width / source.width, box.height / source.height)
        return CGSize(
            width: max(1, (source.width * fit * displayScale).rounded(.up)),
            height: max(1, (source.height * fit * displayScale).rounded(.up))
        )
    }
}

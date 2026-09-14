import UIKit
import XCTest
@testable import Morsel

// Issue #188 — the off-body preparation itself, and the controls that keep the
// pixel assertions honest: the fingerprint that names a queued photo's bytes,
// the pixel probe's own orientation contract, and the EXIF-honouring,
// off-main-thread preparation.

final class MealThumbnailPreparationTests: MealThumbnailTestCase {
    func testContentFingerprintIsDeterministicAndByteSensitive() throws {
        let payload = try panorama(red)
        XCTAssertEqual(MealThumbnailFingerprint.of(payload), MealThumbnailFingerprint.of(Data(payload)))
        XCTAssertNotEqual(MealThumbnailFingerprint.of(payload), MealThumbnailFingerprint.of(try panorama(blue)))
        XCTAssertNotEqual(MealThumbnailFingerprint.of(payload), MealThumbnailFingerprint.of(Data()))
    }

    /// The control that keeps every pixel assertion below honest: the probe
    /// really measures the region it is asked for, in top-left pixel origin.
    func testPixelProbeMeasuresTopLeftOriginRegions() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).image { context in
            red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            blue.setFill()
            context.fill(CGRect(x: 0, y: 20, width: 40, height: 20))
        }

        let halves = ThumbnailPixelProbe.halves(of: image)
        XCTAssertTrue(halves.top.isDominantlyRed, "the top half of the image is the red one")
        XCTAssertTrue(halves.bottom.isDominantlyBlue)
        XCTAssertFalse(
            halves.left.isDominantlyRed || halves.left.isDominantlyBlue,
            "the left half spans both rows — neither colour dominates it"
        )
        XCTAssertEqual(halves.pixels, CGSize(width: 40, height: 40))
    }

    @MainActor
    func testPreparationRunsOffMainThreadAndHonoursExifOrientation() async throws {
        let preparer = MealThumbnailPreparer()
        let fixture = try MealThumbnailFixture.orientedJPEG(
            width: 2_400,
            height: 3_200,
            orientation: .right,
            left: red,
            right: blue
        )
        let (image, trace) = try await preparer.prepareTraced(
            data: fixture, box: CGSize(width: 430, height: 150), displayScale: 1
        )

        XCTAssertTrue(trace.ranOffMainThread, "the body must not run on the calling main actor")
        XCTAssertEqual(
            trace.sourcePixels, CGSize(width: 3_200, height: 2_400),
            "the EXIF quarter turn decides the displayed pixels, read without decoding"
        )
        XCTAssertEqual(trace.targetPixels, CGSize(width: 200, height: 150))
        XCTAssertEqual(trace.outputPixels, CGSize(width: 200, height: 150), "prepared pixels ARE painted pixels")

        let halves = ThumbnailPixelProbe.halves(of: image)
        let redOnTop = halves.top.isDominantlyRed && halves.bottom.isDominantlyBlue
        let redOnBottom = halves.bottom.isDominantlyRed && halves.top.isDominantlyBlue
        XCTAssertTrue(
            redOnTop || redOnBottom,
            "the EXIF quarter turn maps the RAW left/right halves onto display ROWS"
        )
        XCTAssertFalse(
            halves.left.isDominantlyRed && halves.right.isDominantlyBlue,
            "an orientation-ignoring preparation would paint the RAW halves as display COLUMNS"
        )
        let peak = await preparer.peakConcurrentPreparations
        XCTAssertEqual(peak, 1, "one preparation at a time (bounded memory)")
        print(
            "ISSUE-188-ORIENTATION source=3200x2400 output=200x150 off_main=\(trace.ranOffMainThread)"
                + " red_on_top=\(redOnTop) red_on_bottom=\(redOnBottom)"
        )
    }
}

import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #188 — the shipped surface and the prepared-image paint path.
//
// 1. The Edit-item sheet's existing-photo figure reads through the
//    prepared-thumbnail cache: a mounted `MealPhotoEditorSection` costs exactly
//    one fetch + one off-body preparation, and a re-mounted sheet (the warm
//    revisit) costs no fetch and no decode — counted, never timed.
// 2. A mounted SwiftUI body that awaits the SAME cache seam paints the prepared
//    image: the painted pixels are the photo's, at the exact device-pixel size
//    of the display box.
//
// Honest scope note: the shipped figure's own painted pixels could not be read
// back through `drawHierarchy` in this unit bundle — the section's `.task`
// loader runs deferred (after the capture pump) and the capture kept the
// previous frame — so the shipped surface is proven by its COUNTED read and the
// paint is proven by the mounted body control below.

@MainActor
final class MealPhotoThumbnailSurfaceTests: XCTestCase {
    private let account = UUID()
    private let red = UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)

    private struct Mounted {
        let window: UIWindow
        let host: UIHostingController<AnyView>
    }

    private func makeItem(path: String) -> MealItem {
        MealItem(
            itemID: UUID(),
            name: "toast",
            quantity: 1,
            unit: .serving,
            caloriesKcal: 100,
            proteinG: 3,
            carbsG: 12,
            fatG: 2,
            fiberG: 1,
            sugarG: 2,
            confidence: nil,
            notes: nil,
            mealImage: MealImage(path: path)
        )
    }

    private func mount(_ root: AnyView) throws -> Mounted {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the unit bundle is hosted by the app, so a real window scene exists"
        )
        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return Mounted(window: window, host: host)
    }

    /// Pins the surface to the top of the window so the figure band starts at
    /// the window's origin (a centered root would move it).
    private func topPinned(_ content: AnyView) -> AnyView {
        AnyView(
            VStack(spacing: 0) {
                content
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
        )
    }

    private func mountEditor(item: MealItem, remote: MealThumbnailRemote, cache: MealThumbnailCache) throws -> Mounted {
        let section = MealPhotoEditorSection(
            item: item,
            repository: remote,
            userID: account,
            pendingPhoto: .constant(nil),
            isDisabled: false,
            isProcessingPhoto: .constant(false),
            thumbnailCache: cache
        )
        return try mount(topPinned(AnyView(section)))
    }

    private func capture(_ mounted: Mounted) -> UIImage? {
        mounted.window.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: mounted.host.view.bounds)
        return renderer.image { _ in
            mounted.host.view.drawHierarchy(in: mounted.host.view.bounds, afterScreenUpdates: true)
        }
    }

    /// Bounded wait for a COUNTED read condition (no wall-clock claim): pump the
    /// main run loop until the shipped section's read has completed.
    private func pump(limit: Int = 400, until condition: () -> Bool) {
        for _ in 0..<limit {
            if condition() {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testPhotoFigureReadsThroughThePreparedCacheAndAWarmRemountCostsNothing() async throws {
        let remote = MealThumbnailRemote()
        let path = FoodImageStore.objectPath(userID: account, imageID: UUID())
        remote.seed(path: path, data: try MealThumbnailFixture.solidJPEG(width: 2_400, height: 1_200, color: red))
        let cache = MealThumbnailCache()
        let item = makeItem(path: path)

        let cold = try mountEditor(item: item, remote: remote, cache: cache)
        pump(until: { cache.residentEntryCount() > 0 || cache.snapshotCounters().failures > 0 })
        let coldCounters = cache.snapshotCounters()
        XCTAssertEqual(coldCounters.fetches, 1, "a cold sheet fetches the object bytes exactly once")
        XCTAssertEqual(coldCounters.preparations, 1, "a cold sheet prepares the thumbnail off-body exactly once")
        XCTAssertEqual(remote.mealImageLoads, 1, "the bytes came through the injected repository once")
        cold.window.isHidden = true
        cold.window.rootViewController = nil

        // The warm revisit: the sheet is torn down and opened again with the
        // same account/object/revision/target identity.
        let warm = try mountEditor(item: item, remote: remote, cache: cache)
        pump(until: { cache.snapshotCounters().hits > 0 })
        let warmCounters = cache.snapshotCounters()
        XCTAssertEqual(warmCounters.fetches, 1, "a warm revisit fetches nothing")
        XCTAssertEqual(warmCounters.preparations, 1, "a warm revisit decodes nothing")
        XCTAssertEqual(warmCounters.hits, 1, "the warm revisit is a memory hit")
        XCTAssertEqual(remote.mealImageLoads, 1, "no second read of the object bytes")
        XCTAssertEqual(cache.residentEntryCount(), 1)
        XCTAssertEqual(
            cache.residentKeys().first?.targetPixels,
            MealThumbnailPixelSize(width: 1_290, height: 435),
            "the shipped figure's box (430pt × 145pt at 3x) is the key's target pixel size"
        )
        warm.window.isHidden = true
        warm.window.rootViewController = nil
        print(
            "ISSUE-188-SURFACE cold_fetches=1 cold_preparations=1 warm_fetches=1 warm_preparations=1"
                + " warm_hits=1 remote_loads=1 target_pixels=1290x435"
        )
    }

    /// The paint path: a mounted SwiftUI body awaiting the same cache seam draws
    /// the prepared image at the display's own pixel size.
    private final class ProbeReport: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func record(_ value: String) {
            lock.lock()
            defer { lock.unlock() }
            values.append(value)
        }

        var summary: String {
            lock.lock()
            defer { lock.unlock() }
            return values.joined(separator: ",")
        }
    }

    private struct PreparedImageProbe: View {
        let cache: MealThumbnailCache
        let source: MealPhotoSource
        let request: MealThumbnailRequest
        let report: ProbeReport

        @State private var image: UIImage?

        var body: some View {
            ZStack {
                Color.white
                if let image {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    Color.green
                }
            }
            .frame(width: 390, height: 145)
            .task(id: request.objectPath) {
                do {
                    let loaded = try await cache.thumbnail(request, from: source)
                    report.record("loaded \(MealThumbnailPixels.size(of: loaded))")
                    image = loaded
                } catch {
                    report.record("error \(error)")
                }
            }
        }
    }

    func testMountedBodyPaintsThePreparedImageAtDisplayPixelSize() throws {
        let remote = MealThumbnailRemote()
        let path = FoodImageStore.objectPath(userID: account, imageID: UUID())
        try remote.seed(path: path, data: MealThumbnailFixture.solidJPEG(width: 2_400, height: 1_200, color: red))
        let cache = MealThumbnailCache()
        let report = ProbeReport()
        let probe = PreparedImageProbe(
            cache: cache,
            source: MealPhotoSource(repository: remote),
            request: MealThumbnailRequest(
                accountID: account,
                objectPath: path,
                displayBox: MealThumbnailMetrics.photoFigureBox,
                displayScale: 3
            ),
            report: report
        )
        let mounted = try mount(topPinned(AnyView(probe)))

        var sample = ThumbnailPixelProbe.Color(red: 0, green: 0, blue: 0)
        for _ in 0..<300 {
            if let image = capture(mounted) {
                let scale = image.scale > 0 ? image.scale : 1
                sample = ThumbnailPixelProbe.averageColor(
                    of: image, region: CGRect(x: 120 * scale, y: 20 * scale, width: 150 * scale, height: 105 * scale)
                )
                if sample.isDominantlyRed {
                    break
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertTrue(sample.isDominantlyRed, "the mounted body paints the prepared photo, not a placeholder")
        XCTAssertEqual(report.summary, "loaded (870.0, 435.0)", "the body consumed the display-exact prepared image")
        let counters = cache.snapshotCounters()
        XCTAssertEqual(counters.fetches, 1)
        XCTAssertEqual(counters.preparations, 1)
        mounted.window.isHidden = true
        mounted.window.rootViewController = nil
        print("ISSUE-188-SURFACE mounted_body painted=red image=870x435 fetches=1 preparations=1")
    }
}

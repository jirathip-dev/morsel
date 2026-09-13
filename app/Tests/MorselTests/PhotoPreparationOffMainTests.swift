import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Morsel

/// Issue #187 — the off-main photo-preparation seam.
///
/// The shipped surfaces cannot be driven from the unit bundle (a
/// `PhotosPickerItem` has no programmatic selection and the camera sheet is
/// unavailable in the simulator), so these tests drive the two pieces both
/// surfaces share — the bounded `MealPhotoPreparationWorker` and the
/// `FoodImageCompressor` trace — and measure the claims that matter:
///
///  * the synchronous decode / downsample / JPEG-search body runs OFF the
///    main thread (`trace.ranOffMainThread` is sampled inside that body) while
///    the MainActor keeps being serviced for a large photo (heartbeat ticks);
///  * the same fixture produces byte-identical uploads on the caller's actor
///    and on the worker — only the executing thread changes;
///  * large / oriented / invalid fixtures keep today's constraints, and the
///    worker serializes every preparation so concurrency and memory stay
///    bounded.
final class PhotoPreparationOffMainTests: XCTestCase {
    @MainActor
    func testWorkerPreparationRunsOffMainAndKeepsTheMainActorServiced() async throws {
        let fixture = try OffMainPhotoFixture.jpeg(width: 3_024, height: 4_032)
        let heartbeat = PhotoPreparationHeartbeat()
        let start = Date()
        let (upload, trace) = try await MealPhotoPreparationWorker.shared.prepareTraced(
            data: fixture,
            mimeType: "image/jpeg"
        )
        let end = Date()
        heartbeat.stop()

        XCTAssertTrue(trace.ranOffMainThread, "the preparation body must not run on the main thread")
        XCTAssertEqual(trace.sourcePixels, CGSize(width: 3_024, height: 4_032))
        XCTAssertEqual(Int(max(trace.outputPixels.width, trace.outputPixels.height).rounded()), 2_048)
        XCTAssertLessThanOrEqual(trace.outputBytes, FoodImageStore.targetMaxBytes)
        XCTAssertEqual(trace.outputBytes, upload.data.count)
        XCTAssertEqual(upload.mimeType, "image/jpeg")

        let decoded = try XCTUnwrap(UIImage(data: upload.data), "the upload must be a real JPEG")
        XCTAssertEqual(Int(max(decoded.size.width, decoded.size.height).rounded()), 2_048)
        XCTAssertGreaterThan(
            heartbeat.ticks(in: start...end),
            0,
            "the MainActor must keep running while a large photo is prepared off-main"
        )
    }

    @MainActor
    func testIssue187TraceRecordsBeforeAndAfterWithPixelDimensions() async throws {
        let fixture = try OffMainPhotoFixture.jpeg(width: 3_024, height: 4_032)

        // BEFORE — the audited mechanism (sync body on the caller's actor);
        // AFTER — the shipped seam (identical body on the off-main worker).
        let before = try measureOnCaller(fixture)
        let after = try await measureOnWorker(fixture)

        print(
            "ISSUE-187-TRACE fixture=3024x4032"
                + " before_on_caller=\(before.trace.ranOffMainThread)"
                + " before_out=\(before.pixelSizeLine)"
                + " before_bytes=\(before.trace.outputBytes)"
                + " before_ms=\(before.milliseconds)"
                + " before_heartbeat_ticks=\(before.heartbeatTicks)"
                + " after_off_main=\(after.trace.ranOffMainThread)"
                + " after_out=\(after.pixelSizeLine)"
                + " after_bytes=\(after.trace.outputBytes)"
                + " after_ms=\(after.milliseconds)"
                + " after_heartbeat_ticks=\(after.heartbeatTicks)"
        )

        XCTAssertFalse(
            before.trace.ranOffMainThread,
            "the audited mechanism prepared photos on the caller's actor"
        )
        XCTAssertEqual(
            before.heartbeatTicks,
            0,
            "the audited MainActor call monopolises the main actor for the whole preparation"
        )
        XCTAssertTrue(after.trace.ranOffMainThread, "the shipped mechanism prepares off the main thread")
        XCTAssertEqual(
            before.upload.data,
            after.upload.data,
            "the off-main move must change the executing thread only — not the produced bytes"
        )
        XCTAssertGreaterThan(
            after.heartbeatTicks,
            0,
            "the MainActor must stay serviced while the worker prepares"
        )
    }

    /// The audited mechanism: the synchronous body on the caller's (MainActor)
    /// task. The direct call blocks the MainActor for its whole duration, so a
    /// heartbeat scheduled on it cannot tick inside the window.
    @MainActor
    private func measureOnCaller(_ fixture: Data) throws -> MeasuredPreparation {
        let heartbeat = PhotoPreparationHeartbeat()
        let start = Date()
        let (upload, trace) = try FoodImageCompressor.prepareTraced(
            data: fixture,
            mimeType: "image/jpeg"
        )
        let end = Date()
        heartbeat.stop()
        return MeasuredPreparation(
            upload: upload,
            trace: trace,
            milliseconds: Self.milliseconds(start, end),
            heartbeatTicks: heartbeat.ticks(in: start...end)
        )
    }

    /// The shipped seam: the same body awaited on the off-main worker.
    @MainActor
    private func measureOnWorker(_ fixture: Data) async throws -> MeasuredPreparation {
        let heartbeat = PhotoPreparationHeartbeat()
        let start = Date()
        let (upload, trace) = try await MealPhotoPreparationWorker.shared.prepareTraced(
            data: fixture,
            mimeType: "image/jpeg"
        )
        let end = Date()
        heartbeat.stop()
        return MeasuredPreparation(
            upload: upload,
            trace: trace,
            milliseconds: Self.milliseconds(start, end),
            heartbeatTicks: heartbeat.ticks(in: start...end)
        )
    }

    func testLargeOrientedAndInvalidFixturesKeepTheirConstraints() async throws {
        let worker = MealPhotoPreparationWorker.shared

        do {
            _ = try await worker.prepare(data: Data([0x00, 0x01, 0x02, 0x03]), mimeType: "image/jpeg")
            XCTFail("undecodable bytes must be refused")
        } catch let error as FoodImageError {
            XCTAssertEqual(error, .invalidImage)
        }

        do {
            _ = try await worker.prepare(data: Data([0x00]), mimeType: "text/plain")
            XCTFail("a non-image MIME type must be refused")
        } catch let error as FoodImageError {
            XCTAssertEqual(error, .unsupportedMimeType)
        }

        // EXIF orientation 6 (rotate 90° CW): raw pixels are portrait, the
        // user's photo is landscape. The preparation must honour the tag.
        let oriented = try OffMainPhotoFixture.orientedJPEG(
            width: 3_024,
            height: 4_032,
            orientation: .right
        )
        let source = try XCTUnwrap(UIImage(data: oriented))
        XCTAssertEqual(source.imageOrientation, .right, "the fixture really carries EXIF orientation")
        XCTAssertEqual(
            CGSize(width: source.size.width * source.scale, height: source.size.height * source.scale),
            CGSize(width: 4_032, height: 3_024)
        )

        let (orientedUpload, orientedTrace) = try await worker.prepareTraced(
            data: oriented,
            mimeType: "image/jpeg"
        )
        let output = try XCTUnwrap(UIImage(data: orientedUpload.data))
        XCTAssertEqual(orientedTrace.sourcePixels, CGSize(width: 4_032, height: 3_024))
        XCTAssertGreaterThan(output.size.width, output.size.height, "an orientation-ignoring path would stay portrait")
        XCTAssertEqual(Int(max(output.size.width, output.size.height).rounded()), 2_048)
        XCTAssertEqual(
            output.size.width / output.size.height,
            4_032 / 3_024,
            accuracy: 0.01,
            "the oriented aspect ratio must survive the downsample"
        )
        XCTAssertLessThanOrEqual(orientedUpload.data.count, FoodImageStore.targetMaxBytes)

        // the source-size constraint still lives at its own seam
        XCTAssertThrowsError(
            try FoodImageStore.validate(
                data: Data(repeating: 0, count: FoodImageStore.maxBytes + 1),
                mimeType: "image/jpeg"
            )
        ) { error in
            XCTAssertEqual(error as? FoodImageError, .tooLarge)
        }
    }

    func testConcurrentPreparationsAreSerializedAndStayBounded() async throws {
        let fixtures = [
            try OffMainPhotoFixture.jpeg(width: 1_600, height: 1_200),
            try OffMainPhotoFixture.jpeg(width: 1_200, height: 1_600),
            try OffMainPhotoFixture.jpeg(width: 2_400, height: 1_800),
            try OffMainPhotoFixture.jpeg(width: 1_800, height: 2_400)
        ]

        let uploads = await withTaskGroup(of: FoodImageUpload?.self, returning: [FoodImageUpload?].self) { group in
            for fixture in fixtures {
                group.addTask {
                    try? await MealPhotoPreparationWorker.shared.prepare(data: fixture, mimeType: "image/jpeg")
                }
            }
            var results: [FoodImageUpload?] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(uploads.count, fixtures.count)
        for result in uploads {
            let upload = try XCTUnwrap(result, "every concurrent preparation must succeed")
            XCTAssertLessThanOrEqual(upload.data.count, FoodImageStore.targetMaxBytes)
        }
        let peak = await MealPhotoPreparationWorker.shared.peakConcurrentPreparations
        XCTAssertEqual(peak, 1, "the shared worker prepares one photo at a time (bounded concurrency + memory)")
    }

    func testSupersededPreparationStopsWithoutProducingAnUpload() async throws {
        let fixture = try OffMainPhotoFixture.jpeg(width: 3_024, height: 4_032)
        let parked = PhotoPreparationLatch()
        let task = Task { () -> FoodImageUpload in
            await parked.wait()
            return try await MealPhotoPreparationWorker.shared.prepare(data: fixture, mimeType: "image/jpeg")
        }
        await parked.waitUntilWaiting()
        task.cancel()
        await parked.open()

        do {
            _ = try await task.value
            XCTFail("a superseded preparation must not finish the work or produce an upload")
        } catch is CancellationError {
            // Expected: the body observes the retired caller at its first
            // downscale bound and stops (bounded wasted work).
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    private static func milliseconds(_ start: Date, _ end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1_000).rounded())
    }
}

/// Issue #187 — one measured preparation: the upload, its trace, and the
/// main-actor servicing observed while it ran.
private struct MeasuredPreparation {
    let upload: FoodImageUpload
    let trace: FoodImageCompressor.Trace
    let milliseconds: Int
    let heartbeatTicks: Int

    var pixelSizeLine: String {
        "\(Int(trace.outputPixels.width))x\(Int(trace.outputPixels.height))"
    }
}

/// Issue #187 — a MainActor heartbeat: while the test awaits an off-main
/// preparation this task keeps being scheduled on the MainActor and records
/// when, so "the main actor stayed responsive" is measured, not asserted in
/// prose.
@MainActor
private final class PhotoPreparationHeartbeat {
    private var ticks: [Date] = []
    private var task: Task<Void, Never>?

    init() {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.ticks.append(Date())
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    func ticks(in window: ClosedRange<Date>) -> Int {
        ticks.filter { window.contains($0) }.count
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Issue #187 — a one-shot deterministic gate for the cancellation test: the
/// test parks the preparation until it decides to cancel it (no wall-clock
/// waits anywhere).
private actor PhotoPreparationLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    /// Returns as soon as the parked task is really waiting (bounded).
    func waitUntilWaiting() async {
        for _ in 0..<10_000 {
            if !waiters.isEmpty {
                return
            }
            await Task.yield()
        }
    }
}

/// Issue #187 — synthetic fixtures owned by the repo (generated here, never
/// committed bytes): real encoded JPEGs with high-frequency detail so the
/// decode / downsample / encode work is real.
private enum OffMainPhotoFixture {
    enum FixtureError: Error {
        case encodingFailed
    }

    static func jpeg(width: Int, height: Int) throws -> Data {
        guard let data = image(width: width, height: height).jpegData(compressionQuality: 0.9) else {
            throw FixtureError.encodingFailed
        }
        return data
    }

    /// A JPEG whose EXIF orientation tag is set, as a camera/library file
    /// carries it.
    static func orientedJPEG(
        width: Int,
        height: Int,
        orientation: CGImagePropertyOrientation
    ) throws -> Data {
        guard let cgImage = image(width: width, height: height).cgImage else {
            throw FixtureError.encodingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw FixtureError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            cgImage,
            [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.encodingFailed
        }
        return data as Data
    }

    private static func image(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            let cgContext = context.cgContext
            var seed: UInt64 = 0x2545_F491_4F6C_DD1D
            var offsetY = 0
            while offsetY < height {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let value = CGFloat((seed >> 40) & 0xFF) / 255
                cgContext.setFillColor(UIColor(white: value, alpha: 1).cgColor)
                cgContext.fill(CGRect(x: 0, y: offsetY, width: width, height: 4))
                offsetY += 4
            }
        }
    }
}

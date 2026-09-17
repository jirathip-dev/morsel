import SwiftUI
import UIKit
import XCTest
@testable import Morsel

@MainActor
final class TodayRefreshLifecycleTests: TodayRefreshTestCase {
    func testSupersessionPublishesNewBeforeNonCooperativeOldCompletion() async {
        let old = Task { await model.load() }
        await until("old read entered") { harness.reads.count == 1 }
        let fresh = Task { await model.load(superseding: true) }
        await until("superseding read entered") { harness.reads.count == 2 }
        harness.finish(1, marker: 2500)
        await fresh.value
        harness.finish(0, marker: 1000)
        await old.value
        await Task.yield()
        XCTAssertEqual(model.snapshot?.goal?.calorieTargetKcal, 2500)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testCancellingOneDuplicateDoesNotCancelOtherWaiter() async {
        let first = Task { await model.load() }
        await until("read entered") { harness.reads.count == 1 }
        var joined = false
        let other = Task { joined = true; await model.load() }
        await until("other caller joined") { joined }
        first.cancel()
        await first.value
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(harness.reads.count, 1)
        harness.finish(0)
        await other.value
        XCTAssertEqual(model.snapshot?.goal?.calorieTargetKcal, 2000)
        XCTAssertFalse(model.isLoading)
    }

    func testTeardownDuringFirstCacheReleasesFlagsAndRejectsLateCacheWithoutRemoteRead() async {
        harness.parkCache = true
        harness.cached = harness.value(date: date, marker: 1700)
        let old = Task { await model.load() }
        await until("cache entered") { harness.cacheCalls == 1 }
        XCTAssertTrue(model.isLoading)
        model.cancelRefresh()
        await old.value
        XCTAssertFalse(model.isLoading)
        harness.releaseCache()
        await Task.yield()
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(harness.reads.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testDateAndAccountOwnersAreIndependentAndOldCompletionsCannotPublish() async {
        let old = Task { await model.load() }
        await until("old read entered") { harness.reads.count == 1 }
        let yesterday = date.addingTimeInterval(-86400)
        model.selectDate(yesterday)
        let selected = Task { await model.load() }
        await until("selected date entered") { harness.reads.count == 2 }
        let otherAccount = DashboardViewModel(repository: TodayReadRepository(harness: harness),
                                             userID: UUID(), dateProvider: { self.date })
        let other = Task { await otherAccount.load() }
        await until("other account entered independently") { harness.reads.count == 3 }
        XCTAssertNotEqual(harness.reads[0].userID, harness.reads[2].userID)
        harness.finish(2, marker: 2600)
        await other.value
        harness.finish(1, marker: 2300)
        await selected.value
        harness.finish(0, marker: 1000)
        await old.value
        await Task.yield()
        XCTAssertEqual(model.snapshot?.date, yesterday)
        XCTAssertEqual(model.snapshot?.goal?.calorieTargetKcal, 2300)
        XCTAssertEqual(otherAccount.snapshot?.goal?.calorieTargetKcal, 2600)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(otherAccount.isLoading)
    }

    func testInvalidationWhileCacheIsParkedSkipsStaleCacheAndLoadsOnce() async {
        harness.parkCache = true
        harness.cached = harness.value(date: date, marker: 1700)
        let old = Task { await model.load() }
        await until("cache entered") { harness.cacheCalls == 1 }
        var invalidated = false
        let mutation = Task { invalidated = true; await model.invalidateDay() }
        await until("write invalidated") { invalidated }
        harness.releaseCache()
        await until("post-write read entered") { harness.reads.count == 1 }
        XCTAssertNil(model.snapshot)
        harness.finish(0)
        await mutation.value
        await old.value
        XCTAssertEqual(harness.cacheCalls, 1)
        XCTAssertEqual(harness.reads.count, 1)
        XCTAssertFalse(model.isLoading)
    }

    func testFailedPostWriteRefreshKeepsExistingFailureContractAndClearsFlags() async {
        var saved: Bool?
        let write = Task { saved = await model.deleteMeal(UUID()) }
        await until("post-write read entered") { harness.reads.count == 1 }
        harness.finish(0, error: MorselError.configurationMissing)
        await write.value
        XCTAssertEqual(saved, false)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isSaving)
    }

    func testLateErrorAfterLeavingTodayCannotFinishOrFailANewActivation() async {
        let old = Task { await model.load() }
        await until("old activation read entered") { harness.reads.count == 1 }
        model.cancelRefresh() // shell: leaving Today or entering the background
        await old.value
        let fresh = Task { await model.load() }
        await until("new activation read entered") { harness.reads.count == 2 }
        harness.finish(0, error: MorselError.configurationMissing)
        await Task.yield()
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.errorMessage)
        harness.finish(1)
        await fresh.value
        XCTAssertEqual(model.snapshot?.goal?.calorieTargetKcal, 2000)
        XCTAssertFalse(model.isLoading)
    }

    func testCachedContentAndPresentationsRemainAvailableDuringRefreshAndError() async throws {
        harness.cached = harness.value(date: date, marker: 1700)
        let first = Task { await model.load() }
        await until("read entered") { harness.reads.count == 1 }
        let presentations = JournalPresentationModel()
        let canvas = try TodayRefreshCanvas(model: model, presentations: presentations, date: date)
        defer { canvas.close() }
        let refreshing = try await canvas.capture(in: self, name: "today-refresh-cached")
        let record = MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: date,
                                source: .manual, items: [])
        presentations.requestDelete(record)
        XCTAssertTrue(presentations.isPresenting, "refresh does not own the shell's interaction state")
        harness.finish(0, error: MorselError.configurationMissing)
        await first.value
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.snapshot?.goal?.calorieTargetKcal, 1700)
        let retry = Task { await model.load() }
        await until("retry entered") { harness.reads.count == 2 }
        harness.finish(1, error: CancellationError())
        await retry.value
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage, "cancellation is not a user-facing error")
        let idle = try await canvas.capture(in: self, name: "today-refresh-idle")
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(refreshing, idle, "cached Today paints unchanged, without a blocking skeleton/overlay")
        let control = DashboardViewModel(
            repository: MockDashboardRepository(snapshot: harness.value(date: date, marker: 2600)),
            userID: UUID(), dateProvider: { self.date })
        await control.load()
        XCTAssertEqual(control.snapshot?.goal?.calorieTargetKcal, 2600)
        let controlCanvas = try TodayRefreshCanvas(model: control, presentations: presentations, date: date)
        defer { controlCanvas.close() }
        let updated = try await controlCanvas.capture(in: self, name: "today-refresh-control")
        XCTAssertNotEqual(idle, updated, "control: the renderer must actually observe Today state")
        print("ISSUE182 F5 cached Today refreshing/idle PNG bytes equal: \(idle.count)")
    }
}

/// JournalPage's scroll content needs a mounted hosting view, not ImageRenderer.
@MainActor
private final class TodayRefreshCanvas {
    private let window: UIWindow
    private let previous: UIWindow?

    init(model: DashboardViewModel, presentations: JournalPresentationModel, date: Date) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first { $0.isKeyWindow }
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .light
        let fuel = TrainingFuelModel(now: { date })
        fuel.synchronize(model.snapshot, calendar: .autoupdatingCurrent)
        let page = TodayView(viewModel: model, presentations: presentations, showSettings: {}, addMeal: {})
            .environment(\.trainingFuelHosted, true).environmentObject(fuel)
            .frame(width: 390, height: 844).environment(\.colorScheme, .light)
        window.rootViewController = UIHostingController(rootView: page)
        window.makeKeyAndVisible()
    }

    func capture(in test: XCTestCase, name: String) async throws -> Data {
        // Yield for SwiftUI's paint transaction; repository order is controlled by continuations.
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
        return try XCTUnwrap(image.pngData())
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
    }
}

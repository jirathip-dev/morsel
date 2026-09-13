import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #227 — behavioural proofs for the row-noise declutter. This suite
// hosts the REAL Today page, the REAL food row and the REAL food sheet and
// compares RENDERED output instead of source strings: at the unfixed base the
// same page paints differently for a low-confidence item (row provenance/
// confidence/verify text, the accent tint and the duplicated Needs review
// card), and the food sheet paints identically with and without confidence or
// agent notes. Touch synthesis and in-process accessibility read-back are
// unavailable in this bundle (#174/#177: `window.hitTest` answers
// `_UIHostingView` everywhere and SwiftUI vends 0 accessibility elements), so
// the food-sheet entry is proven as (a) the measured full-row target, (b) the
// row's exact activation path — `onEdit(item)` →
// `JournalPresentationModel.requestEdit` — driven through the mounted shell,
// where the REAL sheet must present and the shipped binding must clear, and
// (c) the declared single-element accessibility composition pinned in
// `testRowKeepsTheSingleAccessibleElementComposition`.

/// The shell's presentation chain, observed the way the signed-in shell and
/// `JournalInteractionOwnershipTests` observe it: the owner must be read at a
/// host view that re-renders on its published requests, or `.sheet(item:)`
/// never presents. This host mounts the REAL `TodayView`, so the row's
/// `onEdit` closure is the shipped one (`presentations.requestEdit`).
private struct RowNoisePresentationHost: View {
    @ObservedObject var presentations: JournalPresentationModel
    let viewModel: DashboardViewModel

    var body: some View {
        TodayView(viewModel: viewModel, presentations: presentations, showSettings: {}, addMeal: {})
            .journalPresentations(presentations, viewModel: viewModel)
    }
}

@MainActor
final class RowNoiseRegressionTests: XCTestCase {
    private static let phone = CGSize(width: 390, height: 844)
    /// The sheet content runs past the phone; the window grows (bounded) so
    /// the secondary details area is really painted before it is compared.
    private static let sheetSize = CGSize(width: 390, height: 1_200)
    /// The retired pill reserved a ≥44pt line inside the row; the clean row
    /// fits the 64pt artwork slot plus its 9pt vertical padding with slack.
    private static let rowHeightCeiling: CGFloat = 90
    private static let fixtureDate = Date(timeIntervalSince1970: 1_786_500_000)

    // MARK: - The page paints no row/review noise for uncertain items

    func testTodayPagePaintsTheSameForNormalLowAndMissingConfidence() async throws {
        let clean = try await todayPage(item(confidence: 0.92, notes: nil, source: .manual))
        let low = try await todayPage(
            item(confidence: 0.42, notes: "agent estimate: about 1 cup", source: .photoVision)
        )
        let missing = try await todayPage(item(confidence: nil, notes: nil, source: .barcode))

        XCTAssertTrue(low == clean,
                      "a low-confidence item must paint no row provenance/confidence/verify text, no tint "
                      + "and no duplicate review card")
        XCTAssertTrue(missing == clean,
                      "a missing-confidence item must paint no row noise and no review section")
    }

    // MARK: - The food sheet carries the metadata the row retired

    func testFoodSheetPaintsSourceConfidenceAndAgentNotes() async throws {
        let reference = try await sheetImage(
            item(confidence: 0.42, notes: "agent estimate: about 1 cup", source: .photoVision)
        )
        let repeatRender = try await sheetImage(
            item(confidence: 0.42, notes: "agent estimate: about 1 cup", source: .photoVision)
        )
        XCTAssertTrue(reference == repeatRender, "the sheet render must be deterministic")

        let otherConfidence = try await sheetImage(
            item(confidence: 0.92, notes: "agent estimate: about 1 cup", source: .photoVision)
        )
        XCTAssertFalse(reference == otherConfidence, "the sheet must paint the confidence value")

        let noNotes = try await sheetImage(
            item(confidence: 0.42, notes: nil, source: .photoVision)
        )
        XCTAssertFalse(reference == noNotes, "the sheet must paint the agent estimation notes")

        let manualSource = try await sheetImage(
            item(confidence: 0.42, notes: "agent estimate: about 1 cup", source: .manual)
        )
        XCTAssertFalse(reference == manualSource, "the sheet must paint the source line")
    }

    // MARK: - The row IS the accessible food-sheet entry

    func testFoodRowIsTheFullRowSheetEntryAndPresentsTheFoodSheet() async throws {
        let rowItem = item(confidence: 0.42, notes: "agent estimate: about 1 cup", source: .photoVision)
        let row = fittedSize(of: MealItemRow(item: rowItem, onEdit: { _ in }))
        print("ISSUE227-MEASURE food row width=\(row.width) height=\(row.height)")
        XCTAssertEqual(row.width, Self.phone.width, accuracy: 0.5, "the sheet entry spans the full row")
        XCTAssertGreaterThanOrEqual(row.height, 44, "the row keeps a ≥44pt interactive row")
        XCTAssertLessThanOrEqual(row.height, Self.rowHeightCeiling,
                                 "the retired pill line must leave no reserved spacing")

        // The row's activation path, driven end to end through the mounted
        // shell: `MealItemRow`'s tap runs exactly this closure.
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(snapshot: snapshot(rowItem)), userID: UUID()
        )
        await viewModel.load()
        let presentations = JournalPresentationModel()
        let host = RowNoisePresentationHost(presentations: presentations, viewModel: viewModel)
            .environmentObject(viewModel)
        let window = try mount(AnyView(host), size: Self.phone)
        defer { window.isHidden = true }
        // Let the mounted shell take its first frame before the row's closure
        // runs, exactly like a user tap on a settled page.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        presentations.requestEdit(rowItem)
        XCTAssertEqual(presentations.editingItem?.itemID, rowItem.itemID)
        let presented = pump(until: { !presentedChain(window).isEmpty }, timeout: 20)
        if !presented {
            let onScreen = window.rootViewController?.view.window != nil
            print("ISSUE227-PRESENT none key=\(window.isKeyWindow) onScreen=\(onScreen)")
        }
        XCTAssertTrue(presented, "the row's sheet entry must really present the food sheet")
        // The sheet's Cancel (and a successful Save) clear the request through
        // this same binding. The UIKit chain's POST-DISMISSAL emptiness is not
        // asserted: in this in-bundle mount the dismissal completion is not
        // observable within a bounded wait (the shipped
        // `JournalInteractionOwnershipTests` pins that chain with its own
        // host), so the request state — the shipped binding both paths write —
        // is the deterministic signal; the lane report discloses the limit.
        presentations.editBinding.wrappedValue = nil
        XCTAssertNil(presentations.editingItem, "the binding write must clear the row's presentation request")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(presentations.editingItem, "the cleared request must stay cleared")
        XCTAssertLessThanOrEqual(presentedChain(window).count, 1,
                                 "clearing must never stack a second food sheet")
    }

    /// The bundle cannot read accessibility elements back (#177), so the
    /// single-element composition is pinned at the declared seam next to the
    /// measured full-row target; the rendered-page proof above carries the
    /// "no dead labels" half.
    func testRowKeepsTheSingleAccessibleElementComposition() throws {
        let row = try rowSource()
        XCTAssertTrue(row.contains(".accessibilityElement(children: .combine)"),
                      "the row must stay one combined element, not a pile of labels")
        XCTAssertTrue(row.contains(".accessibilityHint(\"Opens the correction sheet\")"))
        XCTAssertTrue(row.contains(".contentShape(Rectangle())"))
        // Issue #229 retarget: the row is the design's Button (its `.row`
        // is a <button> with an :active lift), so the tap path is the row's
        // Button action — still ONE combined accessible element whose
        // activation opens the same food sheet, pinned end-to-end below.
        XCTAssertTrue(row.contains("Button {"))
        XCTAssertTrue(row.contains("onEdit(item)"))
        XCTAssertFalse(row.contains("ConfidenceBox"), "row confidence text is retired")
        XCTAssertFalse(row.contains("ProvenanceLabel"), "row provenance text is retired")
        XCTAssertFalse(row.contains("VerifyActionLabel"), "the row verify action is retired")
    }

    func testRetiredReviewSectionAndRowAffordancesAreGoneFromShippedSources() throws {
        for (name, text) in try shippedSources() {
            for retired in ["VerifyActionLabel", "NeedsReviewSection", "Needs review"] {
                XCTAssertFalse(text.contains(retired), "\(name) must no longer carry \(retired)")
            }
        }
    }

    // MARK: - Phone-sized Paper/Night captures (simulator, not device)

    func testPhoneSizedPaperAndNightCaptures() async throws {
        let low = item(confidence: 0.42, notes: "agent estimate: about 1 cup", source: .photoVision)
        for (name, scheme) in [("paper", ColorScheme.light), ("night-ink", ColorScheme.dark)] {
            try write(try await todayPage(low, scheme: scheme), named: "issue-227-today-row-\(name)")
            try write(try await sheetImage(low, scheme: scheme), named: "issue-227-food-sheet-\(name)")
        }
    }

    // MARK: - Fixtures

    private func item(
        confidence: Double?,
        notes: String?,
        source: MealSource = .manual
    ) -> MealItem {
        MealItem(
            itemID: UUID(), name: "jasmine rice", quantity: 120, unit: .gram,
            caloriesKcal: 156, proteinG: 3.2, carbsG: 34.1, fatG: 0.4,
            fiberG: 0.8, sugarG: 0.1, confidence: confidence, notes: notes, source: source
        )
    }

    private func snapshot(_ item: MealItem) -> DashboardSnapshot {
        DashboardSnapshot(
            date: Self.fixtureDate,
            meals: [MealRecord(
                mealLogID: UUID(), mealType: .lunch, eatenAt: Self.fixtureDate,
                source: .manual, items: [item]
            )],
            goal: DashboardGoal(
                calorieTargetKcal: 2_100, proteinG: 150, carbsG: 240, fatG: 70, source: .manual
            )
        )
    }

    // MARK: - Real-view rendering

    private func todayPage(_ item: MealItem, scheme: ColorScheme = .light) async throws -> Data {
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(snapshot: snapshot(item)), userID: UUID()
        )
        await viewModel.load()
        let page = TodayView(viewModel: viewModel, showSettings: {}, addMeal: {})
            .preferredColorScheme(scheme)
        return try render(AnyView(page), size: Self.phone)
    }

    private func sheetImage(_ item: MealItem, scheme: ColorScheme = .light) async throws -> Data {
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(snapshot: snapshot(item)), userID: UUID()
        )
        await viewModel.load()
        let sheet = MealItemEditSheet(item: item, onSave: { _ in true })
            .environmentObject(viewModel)
            .preferredColorScheme(scheme)
        return try render(AnyView(sheet), size: Self.sheetSize)
    }

    /// Mounts `view` in the host app's scene at `size`, pumps the run loop so
    /// SwiftUI lays out and its tasks complete, then rasterizes the window.
    private func render(_ view: AnyView, size: CGSize) throws -> Data {
        let window = try mount(view, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        window.isHidden = true
        return try XCTUnwrap(image.pngData(), "the render must encode to PNG")
    }

    private func mount(_ view: AnyView, size: CGSize) throws -> UIWindow {
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first, "the host app scene must be connected")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func fittedSize(of view: some View) -> CGSize {
        let host = UIHostingController(rootView: AnyView(view))
        host.view.frame = CGRect(origin: .zero, size: Self.phone)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: Self.phone)
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func presentedChain(_ window: UIWindow) -> [UIViewController] {
        var chain: [UIViewController] = []
        var current = window.rootViewController
        while let presented = current?.presentedViewController {
            chain.append(presented)
            current = presented
        }
        return chain
    }

    private func write(_ png: Data, named name: String) throws {
        let url = URL(fileURLWithPath: "/tmp/morsel-227-evidence/\(name).png")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try png.write(to: url)
        print("ISSUE227-EVIDENCE \(url.path) bytes=\(png.count)")
    }

    // MARK: - Source seams (host-file reads, the repo's established pattern)

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func rowSource() throws -> String {
        let url = Self.repoRoot.appendingPathComponent("app/Sources/Morsel/TodayLogViews.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct MealItemRow: View"))
        let end = try XCTUnwrap(source.range(
            of: "// MARK: - Sync marker", range: start.upperBound..<source.endIndex
        ))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func shippedSources() throws -> [(String, String)] {
        let directory = Self.repoRoot.appendingPathComponent("app/Sources/Morsel")
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }
}

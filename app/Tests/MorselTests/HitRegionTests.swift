import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #177 — the audited compact actions in the journal shell (header
// Settings + Add Meal, the meal-delete strike, the review pill, the empty-log
// photo prompt) and every tab cell must expose measured ≥44×44 pt interactive
// bounds without moving the approved artwork or palette. These tests host the
// REAL label views and measure the laid-out geometry — never a source-string
// proxy: on the unfixed base the three ink labels measure 24×24 / 38×38 /
// 16×16, so this suite fails there.

@MainActor
final class JournalHitRegionTests: XCTestCase {
    /// The AC's absolute minimum (issue #177), deliberately not read from the
    /// views under test so a shrunken target cannot move the assertion bar.
    private static let minimumTarget: CGFloat = 44
    /// iPhone 16 logical width — the phone-sized shell the audit ran against.
    private static let phoneWidth: CGFloat = 390
    /// The shell's software keyboard height (the tab bar must not care).
    private static let keyboardHeight: CGFloat = 336

    /// Fits a hosted view at the phone width, optionally under a reduced-height
    /// proposal (the keyboard-inset case). Real layout, real fonts.
    private func fittedSize(of view: some View, width: CGFloat = phoneWidth, height: CGFloat = 844) -> CGSize {
        let host = UIHostingController(rootView: AnyView(view))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: height))
    }

    func testCompactActionLabelsMeasureAtLeastTheMinimumTarget() {
        let labels: [(String, AnyView)] = [
            ("settings cog", AnyView(ToothedCog())),
            ("add meal tab", AnyView(AddMealTab())),
            ("meal delete strike", AnyView(InkStrikeX())),
            ("review pill", AnyView(VerifyActionLabel())),
            ("photo prompt", AnyView(PhotoPromptActionLabel()))
        ]
        for (name, label) in labels {
            let size = fittedSize(of: label)
            print("ISSUE177-MEASURE \(name) width=\(size.width) height=\(size.height)")
            XCTAssertGreaterThanOrEqual(size.width, Self.minimumTarget, "\(name) interactive width")
            XCTAssertGreaterThanOrEqual(size.height, Self.minimumTarget, "\(name) interactive height")
        }
    }

    func testTabCellLabelFillsItsAllocatedCellAndOwnsEveryCorner() {
        let bar = fittedSize(of: JournalTabBar(pager: JournalPagerModel()))
        XCTAssertEqual(bar.width, Self.phoneWidth, accuracy: 0.5, "the bar spans the phone width")
        XCTAssertGreaterThanOrEqual(bar.height, Self.minimumTarget, "the bar keeps a ≥44pt row")
        let cellWidth = bar.width / CGFloat(JournalTab.allCases.count)
        var strips: [CGRect] = []
        for (index, tab) in JournalTab.allCases.enumerated() {
            let size = fittedSize(
                of: JournalTabCellLabel(tab: tab, isActive: tab == .today).frame(width: cellWidth)
            )
            XCTAssertEqual(size.width, cellWidth, accuracy: 0.5,
                           "\(tab.title) must stretch to its whole cell, not its word")
            print("ISSUE177-MEASURE \(tab.title) cell width=\(size.width) height=\(size.height)")
            XCTAssertGreaterThanOrEqual(size.width, Self.minimumTarget, "\(tab.title) target width")
            XCTAssertGreaterThanOrEqual(size.height, Self.minimumTarget, "\(tab.title) target height")
            strips.append(CGRect(x: CGFloat(index) * cellWidth, y: 0, width: size.width, height: size.height))
        }
        for (index, strip) in strips.enumerated() {
            for other in strips.dropFirst(index + 1) {
                XCTAssertFalse(strip.intersects(other), "tab targets must not overlap each other")
            }
        }
        // An activation at a cell's corners or blank space belongs to exactly
        // that tab; the 1pt rule above the cells stays inert chrome.
        for (index, tab) in JournalTab.allCases.enumerated() {
            let strip = strips[index]
            let points = [
                CGPoint(x: strip.minX + 1, y: strip.minY + 1),
                CGPoint(x: strip.maxX - 1, y: strip.minY + 1),
                CGPoint(x: strip.minX + 1, y: strip.maxY - 1),
                CGPoint(x: strip.maxX - 1, y: strip.maxY - 1),
                CGPoint(x: strip.minX + 2, y: strip.midY),
                CGPoint(x: strip.maxX - 2, y: strip.midY),
                CGPoint(x: strip.midX, y: strip.midY)
            ]
            for point in points {
                let owners = JournalTab.allCases.indices.filter { strips[$0].contains(point) }
                XCTAssertEqual(owners, [index], "the point \(point) belongs to \(tab.title) alone")
            }
        }
        XCTAssertFalse(strips.contains { $0.contains(CGPoint(x: 195, y: -0.5)) },
                       "the bar's rule line is not a tab target")
    }

    func testTabCellTargetsSurviveTheKeyboardInsetAndAccessibilityTextSizes() {
        let cellWidth = Self.phoneWidth / CGFloat(JournalTab.allCases.count)
        let label = JournalTabCellLabel(tab: .history, isActive: true)
        let withKeyboard = fittedSize(
            of: label.frame(width: cellWidth), height: 844 - Self.keyboardHeight
        )
        XCTAssertGreaterThanOrEqual(withKeyboard.height, Self.minimumTarget, "keyboard present")
        let withoutKeyboard = fittedSize(of: label.frame(width: cellWidth))
        XCTAssertGreaterThanOrEqual(withoutKeyboard.height, Self.minimumTarget, "keyboard absent")
        let large = fittedSize(
            of: label.frame(width: cellWidth)
                .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        )
        XCTAssertGreaterThanOrEqual(large.width, Self.minimumTarget, "accessibility text size width")
        XCTAssertGreaterThanOrEqual(large.height, Self.minimumTarget, "accessibility text size height")
    }

    func testOneCellActivationCannotAdvanceTheSelectionTwice() {
        let pager = JournalPagerModel()
        var transitions = 0
        let sink = pager.$selection.dropFirst().sink { _ in transitions += 1 }
        pager.select(.history) // the cell's action
        pager.select(.history) // the same activation delivered a second time
        XCTAssertEqual(pager.selection, .history)
        XCTAssertEqual(transitions, 1, "a double-delivered activation must not advance the pager twice")
        XCTAssertEqual(pager.lastTurnDirection, .forward)
        sink.cancel()
    }

    // MARK: - Phone-sized Paper/Night evidence captures (simulator, not device)

    /// The fixture the evidence captures render: one logged breakfast whose
    /// delete strike sits in the row header.
    private func evidenceSnapshot() -> DashboardSnapshot {
        let eatenAt = Date(timeIntervalSince1970: 1_786_500_000)
        return DashboardSnapshot(
            date: eatenAt,
            meals: [MealRecord(
                mealLogID: UUID(), mealType: .breakfast, eatenAt: eatenAt, source: .manual,
                items: [MealItem(
                    itemID: UUID(), name: "rolled oats", quantity: 60, unit: .gram,
                    caloriesKcal: 228, proteinG: 8, carbsG: 40, fatG: 4,
                    fiberG: 6, sugarG: 1, confidence: 0.92, notes: nil, source: .manual
                )]
            )],
            goal: DashboardGoal(
                calorieTargetKcal: 2_100, proteinG: 150, carbsG: 240, fatG: 70, source: .manual
            )
        )
    }

    /// Renders `view` into a phone-sized window and writes the PNG the lane
    /// copies into docs/evidence/issue-177-hit-regions/ (#174's mounted-capture
    /// pattern). `targets` maps the laid-out window to the rects to stroke —
    /// callers pass MEASURED geometry, never hand-written rectangles.
    private func capture(
        _ name: String, of view: AnyView, size: CGSize, targets: ((UIWindow) -> [CGRect])? = nil
    ) throws {
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first, "the host app scene must be connected")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rects = targets?(window) ?? []
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
            context.cgContext.setStrokeColor(UIColor.systemPink.withAlphaComponent(0.9).cgColor)
            context.cgContext.setLineWidth(1)
            for rect in rects { context.cgContext.stroke(rect) }
        }
        window.isHidden = true
        guard let data = image.pngData() else {
            return XCTFail("evidence capture \(name) must encode to PNG")
        }
        let url = URL(fileURLWithPath: "/tmp/morsel-177-evidence/\(name).png")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
        print("ISSUE177-EVIDENCE \(url.path) bytes=\(data.count)")
    }

    func testPhoneSizedPaperAndNightCapturesShowTheMeasuredTargets() async throws {
        let repository = MockDashboardRepository(snapshot: evidenceSnapshot())
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())
        await viewModel.load()
        let bar = fittedSize(of: JournalTabBar(pager: JournalPagerModel()))
        let cellWidth = bar.width / CGFloat(JournalTab.allCases.count)
        let cellHeight = fittedSize(
            of: JournalTabCellLabel(tab: .today, isActive: true).frame(width: cellWidth)
        ).height
        // The MEASURED cell strip, placed where the shell really lays the bar
        // out (the window's own safe-area bottom inset + the measured row).
        let targets: (UIWindow) -> [CGRect] = { window in
            let rowTop = window.bounds.height - window.safeAreaInsets.bottom - cellHeight
            return JournalTab.allCases.indices.map {
                CGRect(x: CGFloat($0) * cellWidth, y: rowTop, width: cellWidth, height: cellHeight)
            }
        }
        let shell = VStack(spacing: 0) {
            TodayView(viewModel: viewModel, showSettings: {}, addMeal: {})
            JournalTabBar(pager: JournalPagerModel())
        }
        for (name, scheme) in [("paper", ColorScheme.light), ("night-ink", ColorScheme.dark)] {
            let themed = AnyView(shell.preferredColorScheme(scheme))
            try capture("issue-177-shell-\(name)", of: themed,
                        size: CGSize(width: Self.phoneWidth, height: 844))
            try capture("issue-177-shell-targets-\(name)", of: themed,
                        size: CGSize(width: Self.phoneWidth, height: 844), targets: targets)
        }
    }
}

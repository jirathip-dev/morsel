import XCTest

// Issue #136 — paper-surface contracts verified at source level (native
// mirror of the same guarantees the hosted probes keep on ubuntu):
// 1. Today's delete confirmation is the THEMED paper dialog (cream surface,
//    ink copy, ghost Cancel + red-flagged destructive over-token action),
//    never the Apple system alert chrome.
// 2. Today/History loading surfaces render paper skeletons; no spinner or
//    indefinite loading text remains on Today/History/ledger surfaces.

final class PaperDeleteAndSkeletonTests: XCTestCase {
    private func readSource(_ name: String) throws -> String {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceRoot = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel")
        return try String(contentsOf: sourceRoot.appendingPathComponent(name), encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String? = nil) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start), "missing anchor \(start)")
        guard let end else { return String(source[startRange.lowerBound...]) }
        let endRange = try XCTUnwrap(source.range(of: end), "missing anchor \(end)")
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    // MARK: - Delete confirmation: themed paper dialog, not system alert chrome

    func testTodayDeletePresentsThePaperDialogInsteadOfConfirmationDialog() throws {
        let views = try readSource("Views.swift")

        XCTAssertFalse(
            views.contains(".confirmationDialog("),
            "the Apple system alert chrome must be gone from Today"
        )
        XCTAssertTrue(views.contains(".sheet(item: $mealToDelete) { meal in"))
        XCTAssertTrue(views.contains("DeleteMealPaperDialog(meal: meal)"))
        // Only the destructive action may delete: the confirm sheet routes to
        // the view model's delete, and Cancel stays a pure dismissal.
        XCTAssertTrue(views.contains("Task { _ = await viewModel.deleteMeal(meal.mealLogID) }"))
    }

    func testDeleteDialogCarriesCancelAndRedFlaggedDestructiveAction() throws {
        let views = try readSource("Views.swift")
        let dialog = try slice(views, from: "struct DeleteMealPaperDialog")
        let destructiveStyle = try slice(
            views, from: "private struct MorselDestructiveButtonStyle", to: "struct DeleteMealPaperDialog"
        )

        XCTAssertTrue(dialog.contains("Button(\"Cancel\") { dismiss() }"))
        XCTAssertTrue(dialog.contains("MorselGhostButtonStyle()"))
        XCTAssertTrue(dialog.contains("Button(\"Delete \\(meal.mealType.title)\")"))
        XCTAssertTrue(dialog.contains("MorselDestructiveButtonStyle()"))
        XCTAssertTrue(dialog.contains("onDelete()"))
        XCTAssertFalse(dialog.contains("role: .destructive"), "system destructive roles are gone")

        XCTAssertTrue(destructiveStyle.contains("Color.morselOver"))
        XCTAssertTrue(destructiveStyle.contains("Color.morselBackground"))
        XCTAssertFalse(destructiveStyle.contains(".white"), "no hard-coded white label")
    }

    func testDeleteDialogIsCreamSurfaceWithInkCopy() throws {
        let views = try readSource("Views.swift")
        let dialog = try slice(views, from: "struct DeleteMealPaperDialog")

        XCTAssertTrue(dialog.contains("Color.morselSurface"))
        XCTAssertTrue(dialog.contains("Color.morselInkLine"))
        XCTAssertTrue(dialog.contains("Color.morselInk"))
        XCTAssertTrue(dialog.contains("Color.morselInkTwo"))
        XCTAssertTrue(dialog.contains("\"Delete this meal?\""))
        XCTAssertTrue(
            dialog.contains("This removes \\(meal.items.count) items and recalculates today's totals.")
        )
        XCTAssertFalse(dialog.contains("Color.morselAccent"), "confirm-orange must not paint the destructive action")
    }

    // MARK: - Skeleton loading (no spinner on Today / History)

    func testNoSpinnerOrLoadingTextRemainsOnTodayAndHistorySurfaces() throws {
        let surfaces: [String] = [
            try readSource("Views.swift"),
            try readSource("TodayLogViews.swift"),
            try readSource("HistoryView.swift"),
            try readSource("HistoryLedgerViews.swift")
        ]
        for (index, source) in surfaces.enumerated() {
            let surface = ["Views", "TodayLogViews", "HistoryView", "HistoryLedgerViews"][index]
            XCTAssertFalse(source.contains("ProgressView"), "\(surface) must not render a spinner")
            XCTAssertFalse(source.contains("Reading the ledger"), "\(surface) keeps the freeze text")
            XCTAssertFalse(source.contains("Opening the day"), "\(surface) keeps the freeze text")
            XCTAssertFalse(source.contains("Reading today"), "\(surface) keeps the freeze text")
        }
    }

    func testLoadingBranchesRenderPaperSkeletons() throws {
        let views = try readSource("Views.swift")
        let history = try readSource("HistoryView.swift")
        let logViews = try readSource("TodayLogViews.swift")

        let todayBranch = try slice(views, from: "viewModel.isLoading && viewModel.snapshot == nil")
        XCTAssertTrue(todayBranch.contains("TodaySkeleton()"))
        let historyBranch = try slice(history, from: "viewModel.isLoading && viewModel.overview == nil")
        XCTAssertTrue(historyBranch.contains("HistoryLedgerSkeleton()"))

        XCTAssertTrue(views.contains("struct PaperSkeletonBlock"))
        XCTAssertTrue(views.contains("struct PaperSkeletonFill"))
        XCTAssertTrue(logViews.contains("struct TodayLogSkeletonRows"))
        XCTAssertTrue(history.contains("struct HistoryLedgerSkeleton"))
        XCTAssertTrue(history.contains("struct DayDrillDownSkeleton"))
        // Issue #152 — DayDrillDown (and its skeleton branch) moved to its
        // own file so HistoryLedgerViews stays inside the lint budget.
        let drillDown = try readSource("DayDrillDown.swift")
        XCTAssertTrue(drillDown.contains("struct DayDrillDown"))
        XCTAssertTrue(drillDown.contains("DayDrillDownSkeleton()"))
    }

    func testSkeletonBlocksUsePaperTokens() throws {
        let views = try readSource("Views.swift")
        let skeletonBlock = try slice(views, from: "struct PaperSkeletonBlock", to: "struct PaperSkeletonFill")

        XCTAssertTrue(skeletonBlock.contains("Color.morselInkLine"))
        XCTAssertFalse(skeletonBlock.contains("Color.gray"), "no system gray in paper skeletons")
        XCTAssertFalse(skeletonBlock.contains(".black"), "no hard-coded black in paper skeletons")
    }
}

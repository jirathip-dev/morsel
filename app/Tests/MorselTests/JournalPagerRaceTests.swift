import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #174 — page-turn cancellation and rollback re-entry race suite. The
// audited base let a short-drag rollback's cleanup clear or settle the NEXT
// same-direction gesture, left a preview behind when a drag turned vertical,
// and re-settled an already animating turn. Section 1 drives the extracted
// JournalTurnMachine seam with controllable completions; section 2 mounts the
// REAL turner in a phone-sized window. The gesture/scene source contract
// lives in JournalFollowUpTests.swift.

// ── 1: extracted state seam (controllable completions) ───────────────
@MainActor
final class JournalTurnMachineRaceTests: XCTestCase {
    private let width: CGFloat = 390

    private func makeMachine(_ base: JournalTab = .today) -> JournalTurnMachine {
        JournalTurnMachine(base: base)
    }

    func testVerticalIntentClearsTheLivePreviewAndOwnsTheGesture() {
        let machine = makeMachine(.history)
        machine.dragChanged(deltaX: -130, deltaY: 0, width: width)
        XCTAssertEqual(machine.phase, .dragging)
        XCTAssertEqual(machine.turn?.incoming, .goals)

        machine.dragChanged(deltaX: -130, deltaY: -160, width: width)
        XCTAssertNil(machine.turn, "an intent change must not leave an abandoned preview")
        XCTAssertTrue(machine.atRest)

        machine.dragChanged(deltaX: -300, deltaY: -20, width: width)
        XCTAssertNil(machine.turn, "the scroll-owned gesture cannot turn the page")
        XCTAssertNil(machine.dragEnded(deltaX: -340, predictedX: -340, width: width))
        XCTAssertTrue(machine.atRest)
        XCTAssertEqual(machine.baseTab, .history)
    }

    func testAxisOwnershipLocksOnTheFirstDominantDirection() {
        let verticalFirst = makeMachine()
        verticalFirst.dragChanged(deltaX: -20, deltaY: -80, width: width)
        verticalFirst.dragChanged(deltaX: -300, deltaY: -40, width: width)
        XCTAssertNil(verticalFirst.turn, "a gesture that began vertically is never stolen")
        XCTAssertTrue(verticalFirst.atRest)

        let horizontalFirst = makeMachine(.history)
        horizontalFirst.dragChanged(deltaX: -80, deltaY: 0, width: width)
        horizontalFirst.dragChanged(deltaX: -120, deltaY: -100, width: width)
        XCTAssertEqual(horizontalFirst.phase, .dragging, "|dx| still dominates: stays horizontal")
        XCTAssertEqual(horizontalFirst.turn?.incoming, .goals)
        XCTAssertEqual(horizontalFirst.turn?.progress ?? 0, 120.0 / 390.0, accuracy: 0.0001)
    }

    /// The audited rollback re-entry: a short drag rolls back, an immediate
    /// same-direction drag starts a FRESH turn, and the first completion can
    /// neither clear nor settle it (fresh UUID, fresh operation token).
    func testRollbackReentryKeepsAFreshTurnAndTheStaleCompletionCannotTouchIt() {
        let machine = makeMachine()
        machine.dragChanged(deltaX: -30, deltaY: 0, width: width)
        let firstTurnID = machine.turn?.id
        guard let rollback = machine.dragEnded(deltaX: -30, predictedX: -30, width: width) else {
            return XCTFail("a short drag must schedule a rollback")
        }
        XCTAssertEqual(rollback.completion, .drop)
        XCTAssertEqual(machine.phase, .rollingBack)

        machine.dragChanged(deltaX: -100, deltaY: 0, width: width)
        XCTAssertEqual(machine.phase, .dragging)
        XCTAssertNotEqual(machine.turn?.id, firstTurnID, "the rollback turn UUID must never be reused")
        let secondTurnID = machine.turn?.id

        XCTAssertFalse(machine.complete(operation: rollback.operation))
        XCTAssertEqual(machine.phase, .dragging)
        XCTAssertEqual(machine.turn?.id, secondTurnID)
        XCTAssertEqual(machine.turn?.progress ?? 0, 100.0 / 390.0, accuracy: 0.0001)

        guard let commit = machine.dragEnded(deltaX: -320, predictedX: -320, width: width) else {
            return XCTFail("a half-page drag must commit")
        }
        XCTAssertEqual(commit.completion, .promote)
        XCTAssertFalse(machine.complete(operation: rollback.operation))
        XCTAssertEqual(machine.phase, .committing, "the stale completion must not settle the commit")
        XCTAssertTrue(machine.complete(operation: commit.operation))
        XCTAssertEqual(machine.baseTab, .history)
        XCTAssertTrue(machine.atRest)
    }

    func testStaleSwingCompletionCannotSettleARetargetedSwing() {
        let machine = makeMachine()
        machine.selectionChanged(to: .history)
        let historyOperation = machine.operation
        XCTAssertEqual(machine.phase, .committing)
        XCTAssertEqual(machine.turn?.incoming, .history)

        machine.selectionChanged(to: .goals) // retarget mid-swing
        XCTAssertEqual(machine.baseTab, .history, "the retargeted swing settles where it was headed")
        XCTAssertEqual(machine.turn?.incoming, .goals)

        XCTAssertFalse(machine.complete(operation: historyOperation),
                       "a stale completion cannot mutate newer state")
        XCTAssertEqual(machine.baseTab, .history)
        XCTAssertEqual(machine.turn?.incoming, .goals)
        XCTAssertTrue(machine.complete(operation: machine.operation))
        XCTAssertEqual(machine.baseTab, .goals)
        XCTAssertTrue(machine.atRest)
    }

    func testCommitEchoAndDragsDuringTheCommitLeaveTheSwingAlone() {
        let machine = makeMachine()
        machine.dragChanged(deltaX: -320, deltaY: 0, width: width)
        guard let commit = machine.dragEnded(deltaX: -320, predictedX: -320, width: width) else {
            return XCTFail("a half-page drag must commit")
        }
        XCTAssertEqual(commit.completion, .promote)
        XCTAssertTrue(commit.swipesModel)
        let operation = machine.operation

        machine.dragChanged(deltaX: -200, deltaY: 0, width: width) // ignored mid-commit
        XCTAssertEqual(machine.turn?.progress ?? 0, 320.0 / 390.0, accuracy: 0.0001)
        machine.selectionChanged(to: .history) // pager.swipe's echo of the commit
        XCTAssertEqual(machine.operation, operation)
        XCTAssertEqual(machine.phase, .committing)
        XCTAssertTrue(machine.complete(operation: operation))
        XCTAssertEqual(machine.baseTab, .history)
    }

    func testStaleDragEndCannotReSettleAnAnimatingTurn() {
        let machine = makeMachine()
        machine.dragChanged(deltaX: -30, deltaY: 0, width: width)
        guard let rollback = machine.dragEnded(deltaX: -30, predictedX: -30, width: width) else {
            return XCTFail("a short drag must schedule a rollback")
        }
        XCTAssertNil(machine.dragEnded(deltaX: -320, predictedX: -320, width: width),
                     "a stale end must not re-settle the same turn")
        XCTAssertEqual(machine.phase, .rollingBack)
        XCTAssertTrue(machine.complete(operation: rollback.operation))
        XCTAssertEqual(machine.baseTab, .today)

        // A zero-distance end drops the preview without an effect.
        let zero = makeMachine(.history)
        zero.dragChanged(deltaX: -40, deltaY: 0, width: width)
        XCTAssertNil(zero.dragEnded(deltaX: 0, predictedX: 0, width: width))
        XCTAssertTrue(zero.atRest)
        XCTAssertEqual(zero.baseTab, .history)
    }

    func testDirectionReversalSettlesToTheLastCommittedSelection() {
        let machine = makeMachine(.history)
        machine.dragChanged(deltaX: -120, deltaY: 0, width: width) // forward → Goals preview
        XCTAssertEqual(machine.turn?.incoming, .goals)
        machine.dragChanged(deltaX: 40, deltaY: 0, width: width) // reversal → Today preview
        XCTAssertEqual(machine.turn?.incoming, .today)

        guard let rollback = machine.dragEnded(deltaX: 40, predictedX: 40, width: width) else {
            return XCTFail("a short reversal must roll back")
        }
        XCTAssertTrue(machine.complete(operation: rollback.operation))
        XCTAssertEqual(machine.baseTab, .history, "a rolled-back reversal commits nothing")

        machine.dragChanged(deltaX: 240, deltaY: 0, width: width)
        guard let commit = machine.dragEnded(deltaX: 240, predictedX: 300, width: width) else {
            return XCTFail("a half-page drag must commit")
        }
        XCTAssertTrue(machine.complete(operation: commit.operation))
        XCTAssertEqual(machine.baseTab, .today, "the last committed selection wins")
        XCTAssertTrue(machine.atRest)
    }

    func testBoundaryDragsNeverWrapOrCommit() {
        let atGoals = makeMachine(.goals)
        atGoals.dragChanged(deltaX: -320, deltaY: 0, width: width) // forward from the last tab
        XCTAssertNil(atGoals.turn)
        XCTAssertNil(atGoals.dragEnded(deltaX: -320, predictedX: -320, width: width))
        XCTAssertTrue(atGoals.atRest)

        let atToday = makeMachine(.today)
        atToday.dragChanged(deltaX: 320, deltaY: 0, width: width) // backward from the first tab
        XCTAssertNil(atToday.turn)
        XCTAssertNil(atToday.dragEnded(deltaX: 320, predictedX: 320, width: width))
        XCTAssertTrue(atToday.atRest)
        XCTAssertEqual(atToday.baseTab, .today)
    }

    func testRapidTabRetargetingSettlesOnTheLastRequestedTab() {
        let machine = makeMachine()
        machine.selectionChanged(to: .goals)
        let firstSwing = machine.operation
        machine.selectionChanged(to: .today)
        machine.selectionChanged(to: .history)
        XCTAssertFalse(machine.complete(operation: firstSwing))
        XCTAssertTrue(machine.complete(operation: machine.operation))
        XCTAssertEqual(machine.baseTab, .history)
        XCTAssertTrue(machine.atRest)
    }

    func testInterruptSettlesExactlyOnePageInEveryPhase() {
        let dragging = makeMachine()
        dragging.dragChanged(deltaX: -100, deltaY: 0, width: width)
        dragging.interrupt()
        XCTAssertTrue(dragging.atRest)
        XCTAssertEqual(dragging.baseTab, .today)

        let committing = makeMachine()
        committing.selectionChanged(to: .history)
        committing.interrupt()
        XCTAssertTrue(committing.atRest)
        XCTAssertEqual(committing.baseTab, .history, "a committed swing lands on its destination")

        let rollingBack = makeMachine(.history)
        rollingBack.dragChanged(deltaX: -30, deltaY: 0, width: width)
        guard let rollback = rollingBack.dragEnded(deltaX: -30, predictedX: -30, width: width) else {
            return XCTFail("a short drag must schedule a rollback")
        }
        XCTAssertEqual(rollingBack.phase, .rollingBack)
        rollingBack.interrupt()
        XCTAssertTrue(rollingBack.atRest)
        XCTAssertEqual(rollingBack.baseTab, .history)
        XCTAssertFalse(rollingBack.complete(operation: rollback.operation),
                       "the interrupted rollback's completion is stale")
        XCTAssertTrue(rollingBack.atRest)
    }
}

// ── 2: mounted shell interaction (real view, phone-sized window) ─────
@MainActor
final class JournalPagerMountedRaceTests: XCTestCase {
    private struct Mounted {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        let ledger: PageLedger
        let pager: JournalPagerModel
        let machine: JournalTurnMachine
        let driver: JournalTurnDriver
    }

    private var mounted: Mounted?

    override func tearDown() {
        mounted?.window.isHidden = true
        mounted = nil
        super.tearDown()
    }

    func testMountedPreviewClearsOnVerticalIntentToOneSettledPage() throws {
        let mounted = try mountTurner()
        mounted.machine.dragChanged(deltaX: -130, deltaY: 0, width: 390)
        XCTAssertTrue(pump { mounted.ledger.mounted == [.today, .history] },
                      "the hinge preview must mount over the settled page")
        capture("174-01-preview-history", mounted: mounted)

        mounted.machine.dragChanged(deltaX: -130, deltaY: -160, width: 390)
        XCTAssertTrue(pump { mounted.ledger.mounted == [.today] }, "a vertical intent change clears it")
        capture("174-02-cleared-one-settled-page", mounted: mounted)
        XCTAssertTrue(mounted.machine.atRest)
        XCTAssertEqual(mounted.pager.selection, .today)
        XCTAssertNil(mounted.machine.turn)
    }

    func testMountedRollbackReentryThenCommitEndsOnTheNewSelection() throws {
        let mounted = try mountTurner()
        mounted.machine.dragChanged(deltaX: -30, deltaY: 0, width: 390)
        XCTAssertTrue(pump { mounted.ledger.mounted == [.today, .history] })
        let firstTurnID = mounted.machine.turn?.id

        guard let rollback = mounted.machine.dragEnded(deltaX: -30, predictedX: -30, width: 390) else {
            return XCTFail("a short drag must schedule a rollback")
        }
        mounted.driver.run(rollback) // the real effect path: animate + schedule completion
        XCTAssertEqual(mounted.machine.phase, .rollingBack)

        mounted.machine.dragChanged(deltaX: -100, deltaY: 0, width: 390)
        XCTAssertNotEqual(mounted.machine.turn?.id, firstTurnID)
        XCTAssertFalse(mounted.machine.complete(operation: rollback.operation))
        XCTAssertEqual(mounted.machine.phase, .dragging)
        XCTAssertTrue(pump { mounted.ledger.mounted == [.today, .history] }, "the rollback must not unmount it")

        guard let commit = mounted.machine.dragEnded(deltaX: -320, predictedX: -320, width: 390) else {
            return XCTFail("a half-page drag must commit")
        }
        mounted.driver.run(commit)
        XCTAssertTrue(pump { mounted.pager.selection == .history }, "a commit pivots the model")
        XCTAssertTrue(pump { mounted.machine.atRest })
        XCTAssertTrue(pump { mounted.ledger.mounted == [.history] },
                      "exactly one settled page on the newly committed selection")
        capture("174-03-commit-settled-history", mounted: mounted)
    }

    func testMountedRapidRetargetingSettlesOnTheLastRequestedTab() throws {
        let mounted = try mountTurner()
        mounted.pager.select(.goals)
        mounted.pager.select(.today)
        mounted.pager.select(.history)
        XCTAssertTrue(pump { mounted.machine.atRest && mounted.machine.baseTab == .history })
        XCTAssertTrue(pump { mounted.ledger.mounted == [.history] })
        XCTAssertEqual(mounted.pager.selection, .history)
    }

    func testMountedDisappearanceInterruptsAnInFlightPreview() throws {
        let mounted = try mountTurner()
        mounted.machine.dragChanged(deltaX: -150, deltaY: 0, width: 390)
        XCTAssertTrue(pump { mounted.ledger.mounted == [.today, .history] })

        // Presentation interruption: the shell removes the pager (the real
        // .onDisappear seam) while the preview is live.
        mounted.host.rootView = AnyView(EmptyView())
        XCTAssertTrue(pump { mounted.machine.atRest }, "removal must interrupt the turn")
        XCTAssertEqual(mounted.machine.baseTab, .today)
        XCTAssertNil(mounted.machine.turn)
        XCTAssertEqual(mounted.pager.selection, .today, "nothing settles away from the base")
    }

    // MARK: Mount + capture helpers
    private func mountTurner() throws -> Mounted {
        let ledger = PageLedger()
        let pager = JournalPagerModel()
        let machine = JournalTurnMachine(base: .today)
        let turner = JournalPageTurner(pager: pager, machine: machine) { tab in
            AnyView(LedgerPage(tab: tab, ledger: ledger).id(tab))
        }
        let host = UIHostingController(rootView: AnyView(turner.frame(width: 390, height: 844)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first, "the host app scene must be connected")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let mounted = Mounted(window: window, host: host, ledger: ledger, pager: pager,
                              machine: machine, driver: JournalTurnDriver(pager: pager, machine: machine))
        self.mounted = mounted
        XCTAssertTrue(pump { ledger.mounted == [.today] }, "the settled page must mount")
        return mounted
    }

    /// Drains the run loop (bounded) until `condition` holds.
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func capture(_ name: String, mounted: Mounted) {
        mounted.window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // let the frame draw
        let renderer = UIGraphicsImageRenderer(bounds: mounted.window.bounds)
        let image = renderer.image { context in
            // drawHierarchy renders the real hinge pose; a layer snapshot is
            // the fallback when the host window is not on screen.
            if !mounted.window.drawHierarchy(in: mounted.window.bounds, afterScreenUpdates: true) {
                mounted.window.layer.render(in: context.cgContext)
            }
        }
        guard let data = image.pngData() else {
            return XCTFail("capture \(name) must encode to PNG")
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        for directory in [URL(fileURLWithPath: "/tmp/morsel-174-evidence", isDirectory: true),
                          FileManager.default.temporaryDirectory] {
            let url = directory.appendingPathComponent("\(name).png")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
                print("ISSUE174-EVIDENCE \(url.path) bytes=\(data.count)")
            } catch {
                print("ISSUE174-EVIDENCE-FAILED \(url.path) error=\(error)")
            }
        }
    }
}

/// Records how many page instances are mounted per tab (order-independent).
@MainActor
private final class PageLedger {
    private var counts: [JournalTab: Int] = [:]

    func enter(_ tab: JournalTab) { counts[tab, default: 0] += 1 }
    func exit(_ tab: JournalTab) { counts[tab, default: 0] -= 1 }

    var mounted: Set<JournalTab> { Set(counts.filter { $0.value > 0 }.keys) }
}

private struct LedgerPage: View {
    let tab: JournalTab
    let ledger: PageLedger

    var body: some View {
        ZStack {
            Color.morselBackground
            Text(tab.title).font(.largeTitle)
        }
        .onAppear { ledger.enter(tab) }
        .onDisappear { ledger.exit(tab) }
    }
}

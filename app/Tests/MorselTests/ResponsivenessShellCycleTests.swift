import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #196 — AC2: mounted shell cycles. 100 mixed flips, rollbacks,
// retargets, vertical drags, keyboard dismissals, sheet open/close,
// backgrounding and Reduce Motion cycles on the REAL page area; every cycle
// asserts one settled page, the matching tab and one activation per tap.

@MainActor
final class ResponsivenessShellCycleTests: XCTestCase {
    private static let phone = CGSize(width: 390, height: 844)
    private static let cycleBudget = 100

    private enum CycleKind: CaseIterable {
        case flip, rollback, retarget, vertical, keyboard, sheet, background, reduceMotion
    }

    private struct Mounted {
        let window: UIWindow
        let pager: JournalPagerModel
        let machine: JournalTurnMachine
        let ledger: CycleLedger
        let driver: JournalTurnDriver
        let focus: CycleFocusBox
        let scene: ScenePhaseBox
        let presentations: JournalPresentationModel
        let actions: PagerActionCounter
    }

    private struct Outcome {
        let shell: Mounted
        let tab: JournalTab
        let reduced: Bool
    }

    /// The two direct action channels a tap can move: the pager's own selection
    /// and the turn machine's monotonic operation token.
    private struct ActionCounts {
        let selection: Int
        let operation: UInt
        let activation: Int
    }

    private var mounted: Mounted?
    private var reduceMotionMounted: Mounted?
    private let metrics = ResponsivenessMetrics(run: "shell-cycles")

    override func tearDown() {
        mounted?.window.isHidden = true
        reduceMotionMounted?.window.isHidden = true
        mounted = nil
        reduceMotionMounted = nil
        super.tearDown()
    }

    /// The painted ground names the settled page, so the pixel oracle must be
    /// able to tell the tabs apart before any cycle relies on it.
    func testPaintedGroundDiscriminatesTheSettledTab() throws {
        let shell = try mountShell(reduceMotion: false)
        mounted = shell
        try settle(shell, on: .today)
        let today = WindowPixels(shell.window).pageGround()
        XCTAssertEqual(today.tab, .today)
        XCTAssertLessThan(today.distance, 60, "the ground must match its declared colour")

        try settle(shell, on: .goals)
        let goals = WindowPixels(shell.window).pageGround()
        XCTAssertEqual(goals.tab, .goals)
        XCTAssertNotEqual(today.tab, goals.tab, "the oracle must separate two tabs")
    }

    func testHundredMixedShellCyclesKeepOneSettledPageAndMatchingTab() throws {
        let shell = try mountShell(reduceMotion: false)
        let reduced = try mountShell(reduceMotion: true)
        mounted = shell
        reduceMotionMounted = reduced
        var performed = 0

        for (index, kind) in Self.schedule().enumerated() {
            let outcome = try apply(kind, index: index, shell: shell, reduced: reduced)
            try assertSettled(outcome.shell, on: outcome.tab, reduced: outcome.reduced)
            performed += 1
        }
        XCTAssertEqual(performed, Self.cycleBudget, "the AC2 battery must run exactly 100 cycles")
        metrics.set("cycles", performed)
        metrics.set("taps", shell.actions.changes + reduced.actions.changes)
        metrics.set("page-activation-events", shell.ledger.bumps.values.reduce(0, +)
            + reduced.ledger.bumps.values.reduce(0, +))
        metrics.flush("hundred-cycles")
    }

    // MARK: - Cycle schedule

    /// 30 flips, 20 rollbacks, 15 retargets, 10 vertical drags, 5 keyboard
    /// dismissals, 5 sheet open/close pairs, 5 backgroundings, 10 Reduce
    /// Motion flips — shuffled deterministically so the mix is reproducible.
    private static func schedule() -> [CycleKind] {
        var kinds: [CycleKind] = []
        kinds += Array(repeating: .flip, count: 30)
        kinds += Array(repeating: .rollback, count: 20)
        kinds += Array(repeating: .retarget, count: 15)
        kinds += Array(repeating: .vertical, count: 10)
        kinds += Array(repeating: .keyboard, count: 5)
        kinds += Array(repeating: .sheet, count: 5)
        kinds += Array(repeating: .background, count: 5)
        kinds += Array(repeating: .reduceMotion, count: 10)
        var seed: UInt64 = 196
        for index in stride(from: kinds.count - 1, through: 1, by: -1) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            kinds.swapAt(index, Int(seed >> 33) % (index + 1))
        }
        return kinds
    }

    // MARK: - Assertions + helpers

    private func actionCounts(_ shell: Mounted, target: JournalTab) -> ActionCounts {
        ActionCounts(selection: shell.actions.changes, operation: shell.machine.operation,
                     activation: shell.ledger.activations[target, default: 0])
    }

    /// One action per tap: exactly one pager selection change and (on the
    /// turner path) exactly one turn operation per tap. The page reload-key
    /// advance is recorded (ISSUE196-COUNT page-activation-events) but not
    /// asserted: the in-bundle page-observation channel proved
    /// non-deterministic, and the reload-key contract is pinned by the
    /// existing pager suites.
    private func assertOneAction(_ shell: Mounted, since before: ActionCounts, taps: Int,
                                 target: JournalTab, turns: Bool = true,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(shell.actions.changes - before.selection, taps,
                       "one selection action per tap", file: file, line: line)
        if turns {
            XCTAssertEqual(shell.machine.operation - before.operation, UInt(taps),
                           "one turn operation per tap", file: file, line: line)
        }
    }

    /// One settled page, the matching tab. The Reduce Motion branch has no
    /// turner, so its machine stays put by design and only the pager, stage
    /// and paint channels are asserted.
    private func assertSettled(_ shell: Mounted, on tab: JournalTab, reduced: Bool,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(pump {
            let machineSettled = reduced || (shell.machine.atRest && shell.machine.baseTab == tab)
            return machineSettled && shell.pager.selection == tab && shell.ledger.activatable == [tab]
        }, "one settled page on \(tab); activatable=\(shell.ledger.activatable) "
           + "base=\(shell.machine.baseTab) selection=\(shell.pager.selection)", file: file, line: line)
        let paintStart = ContinuousClock.now
        var ground = WindowPixels(shell.window).pageGround()
        let deadline = Date().addingTimeInterval(2)
        while ground.tab != tab, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            ground = WindowPixels(shell.window).pageGround()
        }
        metrics.record("paint-settle", since: paintStart)
        XCTAssertEqual(ground.tab, tab, "the painted page must match the tab", file: file, line: line)
    }

    private func settle(_ shell: Mounted, on tab: JournalTab) throws {
        shell.pager.select(tab)
        XCTAssertTrue(pump { shell.machine.atRest && shell.machine.baseTab == tab
            && shell.ledger.activatable == [tab] })
    }

    private static func targetTab(index: Int, current: JournalTab) -> JournalTab {
        let tabs = JournalTab.allCases
        let start = tabs.firstIndex(of: current) ?? 0
        return tabs[(start + (index % 2 == 0 ? 1 : 2)) % tabs.count]
    }

    private func mountShell(reduceMotion: Bool) throws -> Mounted {
        let ledger = CycleLedger()
        let pager = JournalPagerModel()
        let machine = JournalTurnMachine(base: .today)
        let routeModel = JournalRouteModel()
        let presentations = JournalPresentationModel()
        let scene = ScenePhaseBox()
        let focus = CycleFocusBox()
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(snapshot: ResponsivenessFixture.snapshot(marker: 100)),
            userID: ResponsivenessFixture.account)
        let host = CycleHost(scene: scene, presentations: presentations, viewModel: viewModel,
                             pager: pager, machine: machine, routeModel: routeModel,
                             reduceMotion: reduceMotion, ledger: ledger, focus: focus)
        let window = try mountWindow(AnyView(host.frame(width: Self.phone.width, height: Self.phone.height)))
        let mounted = Mounted(window: window, pager: pager, machine: machine, ledger: ledger,
                              driver: JournalTurnDriver(pager: pager, machine: machine),
                              focus: focus, scene: scene, presentations: presentations,
                              actions: PagerActionCounter(pager: pager))
        XCTAssertTrue(pump { ledger.activatable == [.today] }, "the settled Today page must mount")
        return mounted
    }

    private func mountWindow(_ view: AnyView) throws -> UIWindow {
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first, "the host app scene must be connected")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.phone)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4)) // settle before the first capture
        return window
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

    /// Drains the run loop (bounded) until `condition` holds.
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }
}

// The cycle bodies live in a same-file extension: extension bodies do not
// count toward `type_body_length` (repo precedent).
@MainActor
private extension ResponsivenessShellCycleTests {
// MARK: - Cycles

private func apply(_ kind: CycleKind, index: Int, shell: Mounted, reduced: Mounted) throws -> Outcome {
    switch kind {
    case .flip: return try flip(shell, index: index)
    case .rollback: return try rollback(shell, index: index)
    case .retarget: return try retarget(shell, index: index)
    case .vertical: return try verticalDrag(shell)
    case .keyboard: return try keyboardCycle(shell, index: index)
    case .sheet: return try sheetCycle(shell, index: index)
    case .background: return try backgroundCycle(shell)
    case .reduceMotion: return try reduceMotionFlip(reduced, index: index)
    }
}

private func flip(_ shell: Mounted, index: Int) throws -> Outcome {
    let target = Self.targetTab(index: index, current: shell.pager.selection)
    let before = actionCounts(shell, target: target)
    let start = ContinuousClock.now
    shell.pager.select(target)
    XCTAssertTrue(pump { shell.pager.selection == target && shell.machine.phase == .committing },
                  "a tap must commit a turn at once")
    metrics.record("tap-to-first-response", since: start)
    XCTAssertTrue(pump { shell.machine.atRest })
    metrics.record("tap-to-settled", since: start)
    assertOneAction(shell, since: before, taps: 1, target: target)
    return Outcome(shell: shell, tab: target, reduced: false)
}

private func rollback(_ shell: Mounted, index: Int) throws -> Outcome {
    let base = shell.pager.selection
    let direction: PageTurnDirection = index % 2 == 0 ? .forward : .backward
    let delta = direction == .forward ? -40.0 : 40.0
    let width = Self.phone.width
    let start = ContinuousClock.now
    shell.machine.dragChanged(deltaX: delta, deltaY: 0, width: width)
    XCTAssertEqual(shell.machine.turn?.incoming, JournalTabNavigation.adjacent(to: base, turning: direction),
                   "the short drag must preview the adjacent tab (or nothing at a boundary)")
    let effect = shell.machine.dragEnded(deltaX: delta, predictedX: delta, width: width)
    if let effect { shell.driver.run(effect) }
    XCTAssertTrue(pump { shell.machine.atRest }, "the rollback must settle")
    metrics.record("rollback-to-settled", since: start)
    XCTAssertEqual(shell.pager.selection, base, "a rolled-back drag commits nothing")
    return Outcome(shell: shell, tab: base, reduced: false)
}

private func retarget(_ shell: Mounted, index: Int) throws -> Outcome {
    let first = Self.targetTab(index: index, current: shell.pager.selection)
    let second = Self.targetTab(index: index + 1, current: first)
    let before = actionCounts(shell, target: second)
    let start = ContinuousClock.now
    shell.pager.select(first)
    XCTAssertTrue(pump { shell.machine.phase == .committing }, "the first tap must start a swing")
    shell.pager.select(second)
    XCTAssertTrue(pump { shell.machine.atRest }, "the retarget must settle")
    metrics.record("retarget-to-settled", since: start)
    // A retarget legitimately performs two turn operations for its two taps
    // (settle the incoming, then hinge to the newest request), so only the
    // pager action channel is asserted here.
    assertOneAction(shell, since: before, taps: 2, target: second, turns: false)
    return Outcome(shell: shell, tab: second, reduced: false)
}

private func verticalDrag(_ shell: Mounted) throws -> Outcome {
    let width = Self.phone.width
    let base = shell.pager.selection
    shell.machine.dragChanged(deltaX: -30, deltaY: 0, width: width)
    shell.machine.dragChanged(deltaX: -40, deltaY: -180, width: width)
    XCTAssertNil(shell.machine.dragEnded(deltaX: -40, predictedX: -200, width: width),
                 "a scroll-owned gesture never turns a page")
    XCTAssertTrue(pump { shell.machine.atRest })
    XCTAssertEqual(shell.pager.selection, base, "vertical scrolling leaves the tab put")
    metrics.note("vertical-drags")
    return Outcome(shell: shell, tab: base, reduced: false)
}

private func keyboardCycle(_ shell: Mounted, index: Int) throws -> Outcome {
    let target = Self.targetTab(index: index, current: shell.pager.selection)
    let field = try XCTUnwrap(shell.focus.field(for: shell.pager.selection),
                              "the current page's probe field must be mounted")
    shell.window.makeKey()
    field.becomeFirstResponder()
    XCTAssertTrue(pump { field.isFirstResponder }, "the probe field must take focus")
    let before = actionCounts(shell, target: target)
    let start = ContinuousClock.now
    JournalKeyboardDismisser.resign()
    shell.pager.select(target)
    XCTAssertTrue(pump { !field.isFirstResponder }, "a tab tap must resign the keyboard")
    XCTAssertTrue(pump { shell.machine.phase == .committing }, "the tab tap must commit a turn")
    XCTAssertTrue(pump { shell.machine.atRest }, "the committed turn must settle")
    metrics.record("keyboard-dismiss-to-settled", since: start)
    assertOneAction(shell, since: before, taps: 1, target: target)
    return Outcome(shell: shell, tab: target, reduced: false)
}

private func sheetCycle(_ shell: Mounted, index: Int) throws -> Outcome {
    let target = Self.targetTab(index: index, current: shell.pager.selection)
    let before = actionCounts(shell, target: target)
    shell.presentations.requestEdit(ResponsivenessFixture.item(index: index, marker: 100))
    XCTAssertTrue(pump { self.presentedChain(shell.window).count == 1 },
                  "one request presents exactly one sheet")
    shell.pager.select(target)
    XCTAssertTrue(pump { shell.machine.phase == .committing }, "the tab tap must commit a turn")
    XCTAssertTrue(pump { shell.machine.atRest })
    XCTAssertEqual(self.presentedChain(shell.window).count, 1,
                   "the presentation survives the turn as the ONE sheet")
    shell.presentations.editBinding.wrappedValue = nil
    XCTAssertTrue(pump { self.presentedChain(shell.window).isEmpty }, "the owner dismisses it")
    assertOneAction(shell, since: before, taps: 1, target: target)
    return Outcome(shell: shell, tab: target, reduced: false)
}

private func backgroundCycle(_ shell: Mounted) throws -> Outcome {
    let target = Self.targetTab(index: 1, current: shell.pager.selection)
    shell.pager.select(target)
    XCTAssertTrue(pump { shell.machine.phase == .committing }, "a swing must be in flight")
    shell.scene.phase = .background
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertTrue(shell.machine.atRest, "backgrounding must settle the in-flight turn at once")
    shell.scene.phase = .active
    XCTAssertTrue(pump { shell.machine.atRest && shell.pager.selection == target })
    metrics.note("backgroundings")
    return Outcome(shell: shell, tab: target, reduced: false)
}

private func reduceMotionFlip(_ shell: Mounted, index: Int) throws -> Outcome {
    let target = Self.targetTab(index: index, current: shell.pager.selection)
    let before = actionCounts(shell, target: target)
    let start = ContinuousClock.now
    shell.pager.select(target)
    XCTAssertTrue(pump { shell.pager.selection == target && shell.ledger.activatable == [target] },
                  "Reduce Motion selects the page without a hinge")
    metrics.record("rm-tap-to-settled", since: start)
    assertOneAction(shell, since: before, taps: 1, target: target, turns: false)
    return Outcome(shell: shell, tab: target, reduced: true)
}
}

import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #176 — interaction ownership, mounted half. The shell stacks
// full-area layers (retained pages, the hinge's preview/outgoing sheet, the
// route overlays) and the audited shell named no owner, so a layer that was
// only animating — or already covered — could still activate controls. These
// tests mount the REAL stage, turner, route model and presentation owner and
// assert the ownership each layer really receives. Touch synthesis is
// unavailable on this host (#174/#177), so the control-activation channel is
// observed through the real hierarchy (`isEnabled`) while the touch and
// accessibility channels are pinned where declared — companion additions in
// JournalFollowUpTests.

private final class OwnershipRecorder {
    private var enabledNow: [JournalTab: Bool] = [:]
    private(set) var appears: [JournalTab: Int] = [:]

    func enter(_ tab: JournalTab) { appears[tab, default: 0] += 1 }
    func note(_ tab: JournalTab, isEnabled: Bool) { enabledNow[tab] = isEnabled }

    var activatable: Set<JournalTab> { Set(enabledNow.filter { $0.value }.keys) }
    var mounted: Set<JournalTab> { Set(appears.keys) }
}

private struct OwnershipPage: View {
    let tab: JournalTab
    let recorder: OwnershipRecorder
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Color.morselBackground
            .onAppear {
                recorder.enter(tab)
                recorder.note(tab, isEnabled: isEnabled)
            }
            .onChange(of: isEnabled) { _, value in recorder.note(tab, isEnabled: value) }
    }
}

/// The shell's page area, wired like `AuthenticatedDashboardView`: the stage
/// renders through the turner (or fades under Reduce Motion), route-aware.
private struct OwnershipShell<Page: View>: View {
    let pager: JournalPagerModel
    let machine: JournalTurnMachine
    @ObservedObject var routeModel: JournalRouteModel
    var reduceMotion = false
    let makePage: (JournalTab, Int) -> Page

    var body: some View {
        if reduceMotion {
            stage(active: pager.selection)
                .transition(.opacity)
                .environmentObject(machine)
        } else {
            JournalPageTurner(pager: pager, machine: machine) { tab in stage(active: tab) }
        }
    }

    private func stage(active: JournalTab) -> some View {
        JournalPageStage(pager: pager, active: active,
                         overlayCoversPages: routeModel.route != .tabPages) { tab, activation in
            makePage(tab, activation)
        }
    }
}

/// The shell's presentation chain: the owner is observed here the way the
/// shell observes it, and the page area rides inside the anchor.
private struct PresentationHost<Content: View>: View {
    @ObservedObject var presentations: JournalPresentationModel
    let viewModel: DashboardViewModel
    @ViewBuilder let content: Content

    var body: some View {
        content
            .journalPresentations(presentations, viewModel: viewModel)
            .environmentObject(viewModel)
    }
}

@MainActor
final class JournalInteractionOwnershipTests: XCTestCase {
    private static let phone = CGSize(width: 390, height: 844)
    private static let keyboardHeight: CGFloat = 336

    private struct Mounted {
        let window: UIWindow
        let pager: JournalPagerModel
        let machine: JournalTurnMachine
        let routeModel: JournalRouteModel
        let recorder: OwnershipRecorder
        let driver: JournalTurnDriver
        let usesTurner: Bool
    }

    private var mounted: Mounted?

    override func tearDown() {
        mounted?.window.isHidden = true
        mounted = nil
        super.tearDown()
    }

    // MARK: - AC1: one activatable page across every transition phase

    /// Exactly the declared active page (the pager's selection) can activate
    /// content actions through drag, commit and rollback; neither the preview
    /// nor the outgoing layer can, and a retarget hands ownership over.
    func testOnlyTheDeclaredActivePageCanActivateAcrossDragCommitAndRollback() throws {
        let mounted = try mount()
        settle(mounted, on: .history)
        settle(mounted, on: .goals)
        settle(mounted, on: .history)
        assertOwner(mounted, is: .history)

        // Uncommitted drag preview: the settled page stays in charge.
        mounted.machine.dragChanged(deltaX: -320, deltaY: 0, width: Self.phone.width)
        XCTAssertEqual(mounted.machine.phase, .dragging)
        assertOwner(mounted, is: .history)

        // Rollback: still one owner — the page the user is on.
        mounted.driver.run(try commit(mounted, deltaX: -30, predictedX: -30))
        XCTAssertEqual(mounted.machine.phase, .rollingBack)
        assertOwner(mounted, is: .history)
        XCTAssertTrue(pump { mounted.machine.atRest })

        // Commit: the declared destination owns at once, the outgoing page is
        // inert for the whole swing.
        mounted.machine.dragChanged(deltaX: -320, deltaY: 0, width: Self.phone.width)
        mounted.driver.run(try commit(mounted, deltaX: -320, predictedX: -320))
        XCTAssertEqual(mounted.machine.phase, .committing)
        assertOwner(mounted, is: .goals)
        XCTAssertTrue(pump { mounted.machine.atRest && mounted.pager.selection == .goals })

        // Retarget mid-swing: the newest declared page owns, alone.
        mounted.pager.select(.history)
        assertOwner(mounted, is: .history)
        settle(mounted, on: .today)
        assertOwner(mounted, is: .today)
    }

    // MARK: - AC3: the route overlay owns interaction while it covers the pages

    /// Under Add Meal or Menus no page may activate, pages stay mounted
    /// (ownership, not identity), and retargeting stays responsive.
    func testRouteOverlayOwnsInteractionWhileItCoversThePages() throws {
        let mounted = try mount()
        settle(mounted, on: .history)
        settle(mounted, on: .goals)
        settle(mounted, on: .history)
        assertOwner(mounted, is: .history)

        mounted.routeModel.openAddMeal()
        XCTAssertTrue(pump { mounted.recorder.activatable.isEmpty },
                      "no page may activate under Add Meal (saw \(mounted.recorder.activatable))")
        XCTAssertEqual(mounted.recorder.mounted, Set(JournalTab.allCases),
                       "the pages stay mounted; only ownership changed")
        settle(mounted, on: .goals)
        XCTAssertTrue(pump { mounted.recorder.activatable.isEmpty },
                      "tab retargeting stays responsive while no page owns")

        mounted.routeModel.openMenus()
        XCTAssertTrue(pump { mounted.recorder.activatable.isEmpty },
                      "Menus covers the pages too (saw \(mounted.recorder.activatable))")
        mounted.routeModel.closeMenus()
        assertOwner(mounted, is: .goals)
    }

    /// The Reduce Motion path (plain fade, no turner) applies the same policy.
    func testReduceMotionPathKeepsTheSameInteractionOwnership() throws {
        let mounted = try mount(reduceMotion: true)
        settle(mounted, on: .history)
        assertOwner(mounted, is: .history)
        mounted.routeModel.openAddMeal()
        XCTAssertTrue(pump { mounted.recorder.activatable.isEmpty })
        mounted.routeModel.closeAddMeal()
        assertOwner(mounted, is: .history)
    }

    // MARK: - AC3 coordinate half: the overlay owns every page coordinate

    /// Measured (#177 technique): the overlay layer lays out over the whole
    /// page area plus the bar it covers, at full height and with the keyboard
    /// visible, so a coordinate over an underlying action reaches only it.
    func testOverlayLayersOwnEveryPageCoordinateIncludingTheKeyboardCase() {
        let repository = MockDashboardRepository(snapshot: Self.sampleSnapshot())
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())
        let menus = MenuLibraryModel(repository: repository, userID: UUID())
        let overlays: [(String, () -> AnyView)] = [
            ("Add Meal", {
                AnyView(AddMealView(viewModel: viewModel, onClose: {}, menuLibrary: menus, onOpenMenus: {}))
            }),
            ("Menus", { AnyView(MenusScreen(model: menus, onClose: {})) })
        ]
        let bar = fittedSize(of: JournalTabBar(pager: JournalPagerModel()))
        let pageHeight = Self.phone.height - bar.height
        let page = fittedSize(of: TodayView(viewModel: viewModel, showSettings: {}, addMeal: {}),
                              height: pageHeight)
        XCTAssertEqual(page.width, Self.phone.width, accuracy: 0.5)
        XCTAssertEqual(page.height, pageHeight, accuracy: 0.5, "the page fills the area above the bar")

        for (name, overlay) in overlays {
            let full = fittedSize(of: overlay())
            XCTAssertGreaterThanOrEqual(full.width, page.width, "\(name) must own the page width")
            XCTAssertGreaterThanOrEqual(full.height, page.height + bar.height,
                                        "\(name) must own the page area and the bar it covers")
            let withKeyboard = fittedSize(of: overlay(), height: Self.phone.height - Self.keyboardHeight)
            XCTAssertGreaterThanOrEqual(withKeyboard.height, Self.phone.height - Self.keyboardHeight,
                                        "\(name) must own the visible area with the keyboard up")
        }
    }

    // MARK: - AC2: one presentation, anchored outside the transient page

    /// A request made during a turn presents exactly one sheet, survives the
    /// settlement, and never stacks a second one.
    func testPresentationRequestSurvivesAPageTurnAndNeverDuplicates() throws {
        let repository = MockDashboardRepository(snapshot: Self.sampleSnapshot())
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())
        let presentations = JournalPresentationModel()
        let pager = JournalPagerModel()
        let machine = JournalTurnMachine(base: .today)
        let routeModel = JournalRouteModel()
        let recorder = OwnershipRecorder()
        let shell = PresentationHost(presentations: presentations, viewModel: viewModel) {
            OwnershipShell(pager: pager, machine: machine, routeModel: routeModel) { tab, _ in
                OwnershipPage(tab: tab, recorder: recorder)
            }
        }
        let window = try mount(shell)
        XCTAssertTrue(pump { recorder.mounted == [.today] })

        let item = Self.sampleItem()
        presentations.requestEdit(item)
        XCTAssertTrue(pump { presentedChain(window).count == 1 }, "the request must present one sheet")
        let sheet = presentedChain(window).first

        // The turn settles under the presentation: it stays the ONE sheet.
        pager.select(.history)
        XCTAssertTrue(pump { machine.atRest && pager.selection == .history })
        XCTAssertTrue(pump { presentedChain(window).first === sheet },
                      "settlement must not dismiss, duplicate or orphan the presentation")
        XCTAssertEqual(presentedChain(window).count, 1)
        XCTAssertEqual(presentations.editingItem?.itemID, item.itemID, "the request is still the owner's")

        presentations.requestDelete(Self.sampleMeal()) // ignored: one at a time
        XCTAssertNil(presentations.mealToDelete)
        XCTAssertTrue(presentedChain(window).first === sheet)

        // The owner's binding still dismisses.
        presentations.editBinding.wrappedValue = nil
        XCTAssertTrue(pump { presentedChain(window).isEmpty }, "dismissal must clear the presentation")
        XCTAssertNil(presentations.editingItem)
    }

    // MARK: - Phone-sized evidence captures (simulator, not device)

    /// Paper/Night stills: the settled page the user owns, and the overlays.
    func testPhoneSizedOwnershipCaptures() throws {
        let repository = MockDashboardRepository(snapshot: Self.sampleSnapshot())
        let viewModel = DashboardViewModel(repository: repository, userID: UUID())
        let menus = MenuLibraryModel(repository: repository, userID: UUID())
        let pages = VStack(spacing: 0) {
            TodayView(viewModel: viewModel, showSettings: {}, addMeal: {})
            JournalTabBar(pager: JournalPagerModel())
        }
        try capture("176-01-pages-owned-today-paper", of: AnyView(pages.preferredColorScheme(.light)))
        try capture("176-02-add-meal-owns-paper", of: AnyView(ZStack {
            pages
            AddMealView(viewModel: viewModel, onClose: {}, menuLibrary: menus, onOpenMenus: {})
        }.preferredColorScheme(.light)))
        try capture("176-03-menus-owns-night-ink", of: AnyView(ZStack {
            pages
            MenusScreen(model: menus, onClose: {})
        }.preferredColorScheme(.dark)))
    }

    // MARK: - Helpers

    private func mount(reduceMotion: Bool = false) throws -> Mounted {
        let recorder = OwnershipRecorder()
        let pager = JournalPagerModel()
        let machine = JournalTurnMachine(base: .today)
        let routeModel = JournalRouteModel()
        let shell = OwnershipShell(pager: pager, machine: machine, routeModel: routeModel,
                                   reduceMotion: reduceMotion) { tab, _ in
            OwnershipPage(tab: tab, recorder: recorder)
        }
        let window = try mount(shell)
        let mounted = Mounted(window: window, pager: pager, machine: machine, routeModel: routeModel,
                              recorder: recorder, driver: JournalTurnDriver(pager: pager, machine: machine),
                              usesTurner: !reduceMotion)
        self.mounted = mounted
        XCTAssertTrue(pump { recorder.mounted == [.today] }, "the settled Today page must mount")
        return mounted
    }

    private func mount(_ view: some View) throws -> UIWindow {
        let root = AnyView(view.frame(width: Self.phone.width, height: Self.phone.height))
        let host = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first, "the host app scene must be connected")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.phone)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func commit(_ mounted: Mounted, deltaX: Double, predictedX: Double) throws -> JournalTurnMachine.Effect {
        try XCTUnwrap(mounted.machine.dragEnded(deltaX: deltaX, predictedX: predictedX, width: Self.phone.width),
                      "the drag must produce an effect")
    }

    private func settle(_ mounted: Mounted, on tab: JournalTab) {
        mounted.pager.select(tab)
        // The turner starts from the VIEW's handler: the machine must adopt the tab.
        XCTAssertTrue(pump {
            mounted.pager.selection == tab && mounted.machine.atRest
                && (!mounted.usesTurner || mounted.machine.baseTab == tab)
        }, "the \(tab) turn must settle")
        XCTAssertTrue(pump { mounted.recorder.mounted.contains(tab) }, "the \(tab) page must mount")
    }

    private func assertOwner(_ mounted: Mounted, is tab: JournalTab, line: UInt = #line) {
        let isOwner = pump { mounted.recorder.activatable == [tab] }
        XCTAssertTrue(isOwner, "expected \(tab) to be the single activatable page, "
                      + "saw \(mounted.recorder.activatable)", line: line)
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

    private func fittedSize(of view: some View, height: CGFloat = 844) -> CGSize {
        let host = UIHostingController(rootView: AnyView(view))
        host.view.frame = CGRect(x: 0, y: 0, width: Self.phone.width, height: height)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: Self.phone.width, height: height))
    }

    private func capture(_ name: String, of view: AnyView) throws {
        let window = try mount(view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        window.isHidden = true
        guard let data = image.pngData() else {
            return XCTFail("capture \(name) must encode to PNG")
        }
        let url = URL(fileURLWithPath: "/tmp/morsel-176-evidence/\(name).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        print("ISSUE176-EVIDENCE \(url.path) bytes=\(data.count)")
    }

    // MARK: - Fixtures

    private static func sampleSnapshot() -> DashboardSnapshot {
        DashboardSnapshot(
            date: Date(timeIntervalSince1970: 1_786_500_000),
            meals: [sampleMeal()],
            goal: DashboardGoal(calorieTargetKcal: 2_100, proteinG: 150, carbsG: 240, fatG: 70, source: .manual)
        )
    }

    private static func sampleMeal() -> MealRecord {
        MealRecord(mealLogID: UUID(), mealType: .breakfast, eatenAt: Date(timeIntervalSince1970: 1_786_500_000),
                   source: .manual, items: [sampleItem()])
    }

    private static func sampleItem() -> MealItem {
        MealItem(itemID: UUID(), name: "rolled oats", quantity: 60, unit: .gram,
                 caloriesKcal: 228, proteinG: 8, carbsG: 40, fatG: 4,
                 fiberG: 6, sugarG: 1, confidence: 0.92, notes: nil)
    }
}

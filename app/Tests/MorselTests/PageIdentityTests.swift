import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #175 — page identity and activation suite. The audited mechanism made
// every turn a second live page (per-turn UUID identity) whose model and read
// were thrown away at settlement: a committed Today→History turn read the
// ledger twice, an abandoned preview read it once, a revisit rebuilt the page.

// MARK: - Doubles

/// Counts each page's authoritative read (the work an activation does).
private final class CountingRepository: DashboardRepository, @unchecked Sendable {
    private(set) var historyReads = 0
    var history = HistoryOverview(days: [], goal: nil, weightTrend: [])

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        historyReads += 1
        return history
    }
    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        DashboardSnapshot(date: date, meals: [], goal: nil)
    }
    func loadGoalsContext(userID: UUID) async throws -> GoalsPageContext {
        GoalsPageContext(stored: nil, profile: nil, latestWeight: nil, profileRowRead: false)
    }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID { UUID() }
    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        DashboardGoal(calorieTargetKcal: 2_000, proteinG: 100, carbsG: 200, fatG: 70, source: .computed)
    }
}

private final class Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

private final class LifecycleRecorder {
    private(set) var created: [JournalTab: Int] = [:]
    private(set) var released: [JournalTab: Int] = [:]
    private(set) var activated: [JournalTab: Int] = [:]
    private var historyModels: [Weak<HistoryViewModel>] = []

    var observer: JournalPageObserver {
        { [weak self] event, tab, object in
            switch event {
            case .created:
                self?.created[tab, default: 0] += 1
                if let model = object as? HistoryViewModel { self?.historyModels.append(Weak(model)) }
            case .released: self?.released[tab, default: 0] += 1
            case .activated: self?.activated[tab, default: 0] += 1
            }
        }
    }

    /// The History model the stage still owns (nil once it was released).
    var retainedHistoryModel: HistoryViewModel? { historyModels.last?.value }
}
/// Counts real page mounts per tab (appear/disappear, order-independent).
private final class MountLedger {
    private(set) var appears: [JournalTab: Int] = [:]
    private(set) var disappears: [JournalTab: Int] = [:]

    func enter(_ tab: JournalTab) { appears[tab, default: 0] += 1 }
    func exit(_ tab: JournalTab) { disappears[tab, default: 0] += 1 }

    var mounted: Set<JournalTab> { Set(appears.filter { $0.value > (disappears[$0.key] ?? 0) }.keys) }
}

/// Today is a stand-in: this suite measures the page settle/revisit seams.
private struct TodayStub: View {
    var body: some View { Color.morselBackground.overlay(Text("Today").font(.largeTitle)) }
}

private struct IdentityPage: View {
    let tab: JournalTab
    let activation: Int
    let repo: CountingRepository
    let ledger: MountLedger
    let userID: UUID

    var body: some View {
        content
            .onAppear { ledger.enter(tab) }
            .onDisappear { ledger.exit(tab) }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .today:
            MorselActionTint { TodayStub() }
        case .history:
            MorselActionTint {
                HistoryView(repository: repo, userID: userID, reloadKey: activation)
            }
        case .goals:
            MorselActionTint {
                GoalsView(repository: repo, userID: userID, reloadKey: activation)
            }
        }
    }
}

/// The shell's page area: a plain fade under Reduce Motion, the hinged
/// turner otherwise (#111), both over the SAME retained page stage.
@MainActor
private struct IdentityShell<Page: View>: View {
    let pager: JournalPagerModel
    let machine: JournalTurnMachine
    var reduceMotion = false
    let makePage: (JournalTab, Int) -> Page
    var body: some View {
        if reduceMotion {
            stage(active: pager.selection).environmentObject(machine)
        } else {
            JournalPageTurner(pager: pager, machine: machine) { tab in stage(active: tab) }
        }
    }

    private func stage(active: JournalTab) -> some View {
        JournalPageStage(pager: pager, active: active, makePage: makePage)
    }
}

// MARK: - Suite

@MainActor
final class PageIdentityTests: XCTestCase {
    private struct Mounted {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        let pager: JournalPagerModel
        let machine: JournalTurnMachine
        let driver: JournalTurnDriver
        let repo: CountingRepository
        let ledger: MountLedger
    }

    private let userID = UUID()
    private var recorder = LifecycleRecorder()
    private var mounted: Mounted?

    override func tearDown() {
        HistoryViewModel.observer = nil
        mounted?.window.isHidden = true
        mounted = nil
        recorder = LifecycleRecorder()
        super.tearDown()
    }

    /// AC1 + the accepted half of AC2: one History page, one activation, one
    /// read for a committed Today→History turn — and no replacement load when
    /// the swing settles.
    func testCommittedTurnKeepsTheHistoryPageAndNeverReReadsAtSettlement() throws {
        let mounted = try mount()
        mounted.machine.dragChanged(deltaX: -320, deltaY: 0, width: 390)
        XCTAssertEqual(mounted.machine.turn?.incoming, .history)
        XCTAssertNil(recorder.created[.history], "a preview must not create the page yet")
        XCTAssertEqual(mounted.repo.historyReads, 0, "…nor read it")

        mounted.driver.run(try commit(from: mounted.machine, deltaX: -320))
        XCTAssertTrue(pump { mounted.machine.atRest && mounted.pager.selection == .history })
        XCTAssertTrue(pump { recorder.created[.history] == 1 })

        XCTAssertEqual(recorder.created[.history], 1, "the accepted navigation creates the page once")
        XCTAssertEqual(recorder.released[.history] ?? 0, 0, "settlement must reuse the previewed page")
        XCTAssertEqual(recorder.activated[.history], 1, "one activation event per accepted navigation")
        XCTAssertEqual(mounted.repo.historyReads, 1, "…and exactly one authoritative read")
        XCTAssertEqual(mounted.ledger.mounted, [.today, .history])
    }

    /// AC2 + AC5: abandoned previews and rollbacks create and read nothing;
    /// the re-entry after a rollback still commits exactly one page.
    func testAbandonedPreviewsNeverCreateOrReadAndTheReentryCommitsOnce() throws {
        let mounted = try mount()
        mounted.machine.dragChanged(deltaX: -120, deltaY: 0, width: 390)
        XCTAssertEqual(mounted.machine.turn?.incoming, .history)
        mounted.driver.run(try XCTUnwrap(mounted.machine.dragEnded(deltaX: -30, predictedX: -30, width: 390)))
        XCTAssertTrue(pump { mounted.machine.atRest })
        XCTAssertNil(recorder.created[.history], "an abandoned preview must not create a page")
        XCTAssertEqual(mounted.repo.historyReads, 0, "…nor read the ledger")

        mounted.machine.dragChanged(deltaX: -300, deltaY: 0, width: 390)
        mounted.driver.run(try commit(from: mounted.machine, deltaX: -320))
        XCTAssertTrue(pump { mounted.machine.atRest && mounted.pager.selection == .history })
        XCTAssertEqual(recorder.created[.history], 1, "the re-entry creates one page, not one per drag")
        XCTAssertEqual(recorder.activated[.history], 1)
        XCTAssertEqual(mounted.repo.historyReads, 1)
    }

    /// AC5 retarget: a second request mid-swing settles the page it headed for
    /// and hinges on — one page and one activation per tab, none released.
    func testRetargetMidSwingKeepsOnePagePerTab() throws {
        let mounted = try mount()
        mounted.pager.select(.history)
        XCTAssertTrue(pump { mounted.machine.turn?.incoming == .history })
        mounted.pager.select(.goals)
        XCTAssertTrue(pump { mounted.machine.atRest })

        XCTAssertEqual(mounted.pager.selection, .goals)
        XCTAssertEqual(recorder.created[.history], 1, "one page per accepted tab")
        XCTAssertEqual(recorder.released, [:], "the retarget releases nothing")
        XCTAssertEqual(recorder.activated[.history], 1)
        XCTAssertEqual(mounted.ledger.appears[.goals], 1, "the retargeted Goals page is created once")
        XCTAssertEqual(mounted.ledger.mounted, [.today, .history, .goals])
    }

    /// AC3: a revisit keeps the same History model, its range, its expanded
    /// day and its scroll — and activates exactly once more.
    func testRevisitKeepsHistoryRangeExpandedDayAndScroll() throws {
        let mounted = try mount(seededDays: 12)
        settle(mounted, on: .history)
        let model = try XCTUnwrap(recorder.retainedHistoryModel, "the visit must own a model")
        XCTAssertTrue(pump { model.overview != nil }, "the activation read must land")
        model.range = .thirty
        let day = try XCTUnwrap(model.listDays.dropFirst(3).first, "the seed exposes a drill-down day")
        var expanded = false
        Task { @MainActor in
            await model.select(day)
            expanded = true
        }
        XCTAssertTrue(pump { expanded }, "the day drill-down must land")
        XCTAssertEqual(model.expandedDay, day.date)

        let scroll = try XCTUnwrap(historyScrollView(mounted), "the page must own a scroll view")
        scroll.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let offset = scroll.contentOffset.y
        XCTAssertGreaterThan(offset, 0, "the seeded ledger must actually scroll")

        settle(mounted, on: .today)
        settle(mounted, on: .history)

        XCTAssertEqual(recorder.created[.history], 1, "a revisit must not rebuild the page")
        XCTAssertTrue(recorder.retainedHistoryModel === model, "…and must keep the SAME model")
        XCTAssertEqual(model.range, .thirty, "the retained range survives the round trip")
        XCTAssertEqual(model.expandedDay, day.date, "the expanded day survives the round trip")
        let after = try XCTUnwrap(historyScrollView(mounted), "the page keeps its scroll view").contentOffset.y
        XCTAssertGreaterThan(after, 0, "the retained page stays scrolled")
        XCTAssertEqual(after, offset, accuracy: 40,
                       "…within layout drift (before \(offset)pt, after \(after)pt)")
        XCTAssertTrue(pump { recorder.activated[.history] == 2 },
                      "the revisit is one more activation (saw \(recorder.activated[.history] ?? 0))")
        XCTAssertTrue(pump { mounted.repo.historyReads == 2 }, "…with one read per activation")
    }

    /// AC4: Reduce Motion renders the same retained pages (one activation per
    /// accepted navigation, no second page tree).
    func testReduceMotionSharesTheSamePageOwnership() throws {
        let mounted = try mount(reduceMotion: true)
        settle(mounted, on: .history)
        settle(mounted, on: .goals)
        settle(mounted, on: .history)

        XCTAssertEqual(recorder.created[.history], 1, "the Reduce Motion path retains the page too")
        XCTAssertEqual(recorder.released[.history] ?? 0, 0)
        XCTAssertEqual(mounted.ledger.appears[.goals], 1, "…and never builds a second page tree")
        XCTAssertEqual(mounted.ledger.appears[.history], 1)
        XCTAssertTrue(pump { recorder.activated[.history] == 2 },
                      "the revisit activates once per navigation (saw \(recorder.activated[.history] ?? 0))")
        XCTAssertTrue(pump { mounted.repo.historyReads == 2 }, "…with one read per activation")
    }

    /// AC3/AC6 + logout: pages are bounded to the primary tabs and never
    /// started eagerly, the Goals draft page is never rebuilt, and removing
    /// the signed-in shell releases them all.
    func testPagesAreBoundedToThePrimaryTabsAndReleasedWithTheShell() throws {
        let mounted = try mount()
        XCTAssertEqual(mounted.ledger.appears, [.today: 1], "pages are never started eagerly")
        for tab in JournalTab.allCases where tab != .today { settle(mounted, on: tab) }
        settle(mounted, on: .today)
        settle(mounted, on: .goals)

        for tab in JournalTab.allCases {
            XCTAssertEqual(mounted.ledger.appears[tab] ?? 0, 1, "\(tab) has exactly one page")
            XCTAssertEqual(mounted.ledger.disappears[tab] ?? 0, 0, "\(tab) is never released mid-session")
        }
        XCTAssertEqual(recorder.created[.history], 1)
        XCTAssertEqual(mounted.ledger.mounted, Set(JournalTab.allCases))

        // Signing out swaps the signed-in shell for the sign-in surface.
        mounted.host.rootView = AnyView(EmptyView())
        XCTAssertTrue(pump { recorder.released[.history] == 1 }, "logout must release the History page")
        XCTAssertTrue(pump { (mounted.ledger.disappears[.goals] ?? 0) == 1 }, "…and the Goals page")
        XCTAssertNil(recorder.retainedHistoryModel, "no account-owned model may outlive the shell")
    }

    /// Evidence: phone-sized Paper/Night captures of the settled History page
    /// and of the revisit (390×844 pt → 1170×2532 px at @3x).
    func testPhoneSizedSettledAndRevisitCaptures() throws {
        let mounted = try mount(seededDays: 12)
        settle(mounted, on: .history)
        capture("175-01-history-settled-paper", mounted: mounted)
        settle(mounted, on: .today)
        settle(mounted, on: .history)
        capture("175-02-history-revisit-paper", mounted: mounted)

        mounted.window.overrideUserInterfaceStyle = .dark
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        capture("175-03-history-revisit-night", mounted: mounted)
        XCTAssertEqual(recorder.created[.history], 1, "even the capture round trip keeps one page")
    }

    // MARK: Helpers

    private func commit(from machine: JournalTurnMachine, deltaX: Double) throws -> JournalTurnMachine.Effect {
        try XCTUnwrap(machine.dragEnded(deltaX: deltaX, predictedX: deltaX, width: 390), "must commit")
    }

    private func mount(reduceMotion: Bool = false, seededDays: Int = 0) throws -> Mounted {
        let repo = CountingRepository()
        if seededDays > 0 { repo.history = seededHistory(days: seededDays) }
        let ledger = MountLedger()
        let pager = JournalPagerModel()
        let machine = JournalTurnMachine(base: .today)
        let shell = IdentityShell(pager: pager, machine: machine, reduceMotion: reduceMotion) { tab, activation in
            IdentityPage(tab: tab, activation: activation, repo: repo, ledger: ledger, userID: self.userID)
        }
        let host = UIHostingController(rootView: AnyView(shell.frame(width: 390, height: 844)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first, "the host app scene must be connected")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        HistoryViewModel.observer = recorder.observer
        let mounted = Mounted(window: window, host: host, pager: pager, machine: machine,
                              driver: JournalTurnDriver(pager: pager, machine: machine),
                              repo: repo, ledger: ledger)
        self.mounted = mounted
        XCTAssertTrue(pump { ledger.mounted == [.today] }, "the settled page must mount")
        return mounted
    }

    private func seededHistory(days: Int) -> HistoryOverview {
        let day = DashboardMath.startOfLocalDay(Date())
        let rows = (0..<days).map { offset in
            HistoryDay(date: day.addingTimeInterval(-86_400 * Double(offset)),
                       eatenKcal: 1_800 + Double(offset * 10), logged: offset % 3 != 0)
        }
        let goal = DashboardGoal(calorieTargetKcal: 2_100, proteinG: 120, carbsG: 210, fatG: 70, source: .manual)
        let trend = [WeightTrendPoint(date: day.addingTimeInterval(-86_400 * 9), kilograms: 80.4)]
        return HistoryOverview(days: rows, goal: goal, weightTrend: trend)
    }

    private func settle(_ mounted: Mounted, on tab: JournalTab) {
        mounted.pager.select(tab)
        XCTAssertTrue(pump { mounted.machine.atRest && mounted.pager.selection == tab },
                      "the \(tab) turn must settle")
        XCTAssertTrue(pump { mounted.ledger.mounted.contains(tab) }, "the \(tab) page must be mounted")
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func historyScrollView(_ mounted: Mounted) -> UIScrollView? {
        var pending: [UIView] = [mounted.window]
        while let view = pending.popLast() {
            if let scroll = view as? UIScrollView { return scroll }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func capture(_ name: String, mounted: Mounted) {
        mounted.window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let image = UIGraphicsImageRenderer(bounds: mounted.window.bounds).image { context in
            if !mounted.window.drawHierarchy(in: mounted.window.bounds, afterScreenUpdates: true) {
                mounted.window.layer.render(in: context.cgContext)
            }
        }
        guard let data = image.pngData() else {
            return XCTFail("capture \(name) must encode to PNG")
        }
        let directory = URL(fileURLWithPath: "/tmp/morsel-175-evidence", isDirectory: true)
        let url = directory.appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if (try? data.write(to: url)) == nil {
            print("ISSUE175-EVIDENCE-FAILED \(name)")
        } else {
            print("ISSUE175-EVIDENCE \(url.path) n=\(data.count)")
        }
    }
}

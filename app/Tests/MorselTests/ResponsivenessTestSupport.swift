import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #196 — shared pieces for the responsiveness / request-budget harness.
//
// Privacy contract: this harness records fixture IDs, call counts, in-flight
// peaks and durations only. Meal names, tokens, signed URLs and real content
// never enter a measurement line; the fixture itself is synthetic.

/// Deterministic synthetic day used by every measurement: fixed instants,
/// generated IDs, no real user content.
enum ResponsivenessFixture {
    static let account = UUID(uuidString: "19619619-6196-4196-8196-196196196196") ?? UUID()
    static let day = Date(timeIntervalSince1970: 1_789_300_800)
    static let mealCount = 12
    static let itemsPerMeal = 3
    static var itemCount: Int { mealCount * itemsPerMeal }

    static func snapshot(marker: Double, date: Date = day,
                         mealCount: Int = ResponsivenessFixture.mealCount) -> DashboardSnapshot {
        DashboardSnapshot(date: date, meals: meals(marker: marker, date: date, count: mealCount),
                          goal: goal(marker: marker))
    }

    static func meals(marker: Double, date: Date = day,
                      count: Int = ResponsivenessFixture.mealCount) -> [MealRecord] {
        (0..<count).map { meal(index: $0, marker: marker, date: date) }
    }

    static func meal(index: Int, marker: Double, date: Date = day) -> MealRecord {
        MealRecord(mealLogID: uuid(index),
                   mealType: MealType.allCases[index % MealType.allCases.count],
                   eatenAt: date.addingTimeInterval(Double(index) * 1_800),
                   source: .manual,
                   items: (0..<itemsPerMeal).map { item(index: index * itemsPerMeal + $0, marker: marker) })
    }

    static func item(index: Int, marker: Double) -> MealItem {
        MealItem(itemID: uuid(1_000 + index), name: "fixture item \(index)",
                 quantity: Double(index + 1), unit: .gram,
                 caloriesKcal: marker + Double(index), proteinG: 5, carbsG: 20, fatG: 3,
                 fiberG: 1, sugarG: 2, confidence: 0.9, notes: nil)
    }

    /// 8-4-4-4-12 shaped UUIDs for every generated index (#194 lesson).
    static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "%08x-1960-4196-8196-196196196196", index)) ?? UUID()
    }

    static func goal(marker: Double) -> DashboardGoal {
        DashboardGoal(calorieTargetKcal: marker, proteinG: 90, carbsG: 200, fatG: 70, source: .computed)
    }

    static func history(end: Date, days: Int, marker: Double) -> HistoryOverview {
        HistoryOverview(days: [], goal: goal(marker: marker), weightTrend: [])
    }

    /// Recorded so before/after legs can be compared at equal fixture size.
    static var sizeLine: String { "meals=\(mealCount) itemsPerMeal=\(itemsPerMeal) items=\(itemCount)" }
}

/// Records measurement samples (ms) and counters. Percentiles are computed
/// from the recorded samples — they are reported, never pre-declared.
@MainActor
final class ResponsivenessMetrics {
    private(set) var samples: [String: [Double]] = [:]
    private(set) var counters: [String: Int] = [:]
    private let run: String
    private let directory: URL
    /// Process-wide serial: XCTest builds a fresh instance per test method, so
    /// an instance counter would let one method overwrite another's file.
    private static var flushSerial = 0
    private static var usedLabels: Set<String> = []

    init(run: String, directory: URL = URL(fileURLWithPath: "/tmp/morsel-196-evidence")) {
        self.run = run
        self.directory = directory
    }

    @discardableResult
    func measure<T>(_ id: String, _ body: () -> T) -> T {
        let start = ContinuousClock.now
        let value = body()
        record(id, since: start)
        return value
    }

    func record(_ id: String, since start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15
        samples[id, default: []].append(milliseconds)
        print(String(format: "ISSUE196-MEASURE %@ ms=%.3f", id, milliseconds))
    }

    func note(_ id: String, _ amount: Int = 1) { counters[id, default: 0] += amount }
    func set(_ id: String, _ value: Int) { counters[id] = value }

    func percentile(_ id: String, _ fraction: Double) -> Double {
        guard let values = samples[id], !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = max(0, min(sorted.count - 1, Int((fraction * Double(sorted.count - 1)).rounded(.up))))
        return sorted[rank]
    }

    func summaryLines() -> [String] {
        samples.keys.sorted().map { id in
            String(format: "ISSUE196-SUMMARY id=%@ n=%d p50=%.3f p95=%.3f max=%.3f",
                   id, samples[id]?.count ?? 0, percentile(id, 0.5), percentile(id, 0.95),
                   samples[id]?.max() ?? 0)
        } + counters.keys.sorted().map { "ISSUE196-COUNT id=\($0) value=\(counters[$0] ?? 0)" }
    }

    /// Writes the machine-readable record; the raw xcodebuild log keeps the
    /// printed lines for the evidence excerpt. Each flush gets its own file so
    /// one test method can never overwrite another's measurements.
    @discardableResult
    func flush(_ label: String = "run") -> URL? {
        for line in summaryLines() { print(line) }
        let payload: [String: Any] = [
            "run": run,
            "fixture": ResponsivenessFixture.sizeLine,
            "samples_ms": samples,
            "counters": counters
        ]
        Self.flushSerial += 1
        let name = Self.usedLabels.contains(label) ? "\(label)-\(Self.flushSerial)" : label
        Self.usedLabels.insert(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(run)-\(name).json")
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: url)
            print("ISSUE196-METRICS \(url.path) bytes=\(data.count)")
            return url
        } catch {
            print("ISSUE196-METRICS-FAILED error=\(type(of: error))")
            return nil
        }
    }
}

/// Counts, delays and fails every remote call the shell makes. One gate per
/// resource kind, so network / Storage / Health delays stay independent.
actor ResponsivenessRemote: DashboardRepository {
    struct Counts: Equatable {
        var calls = 0
        var peakInFlight = 0
    }

    static let network = "network"
    static let storage = "storage"
    static let history = "history"
    static let goals = "goals"

    private var counts: [String: Counts] = [:]
    private var inFlight: [String: Int] = [:]
    private var held: Set<String> = []
    private var failures: Set<String> = []
    private var gates: [String: [CheckedContinuation<Void, Error>]] = [:]
    private var marker: Double = 100
    private var mealCount = 1

    func setMarker(_ value: Double) { marker = value }
    func setMealCount(_ value: Int) { mealCount = value }
    func counts(for kind: String) -> Counts { counts[kind] ?? Counts() }
    func hold(_ kind: String) { held.insert(kind) }
    func fail(_ kind: String) { failures.insert(kind) }
    func heal(_ kind: String) { failures.remove(kind) }

    func release(_ kind: String) {
        held.remove(kind)
        let waiting = gates[kind] ?? []
        gates[kind] = []
        for gate in waiting { gate.resume() }
    }

    func releaseAll() {
        for kind in gates.keys { release(kind) }
        held.removeAll()
    }

    private func beginCall(_ kind: String) throws {
        var entry = counts[kind] ?? Counts()
        entry.calls += 1
        let live = (inFlight[kind] ?? 0) + 1
        inFlight[kind] = live
        entry.peakInFlight = max(entry.peakInFlight, live)
        counts[kind] = entry
        guard !failures.contains(kind) else {
            inFlight[kind] = live - 1
            throw URLError(.notConnectedToInternet)
        }
    }

    private func finishCall(_ kind: String) { inFlight[kind] = (inFlight[kind] ?? 1) - 1 }

    private func park(_ kind: String) async throws {
        guard held.contains(kind) else { return }
        try await withCheckedThrowingContinuation { gates[kind, default: []].append($0) }
    }

    // MARK: - Reads

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        try beginCall(Self.network)
        defer { finishCall(Self.network) }
        try await park(Self.network)
        return ResponsivenessFixture.snapshot(marker: marker, date: date, mealCount: mealCount)
    }

    /// The day cache lives in the harness's real SQLite facade, not here.
    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? { nil }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        try beginCall(Self.history)
        defer { finishCall(Self.history) }
        try await park(Self.history)
        return ResponsivenessFixture.history(end: end, days: days, marker: marker)
    }

    func cachedHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview? { nil }

    func loadMealImage(userID: UUID, path: String) async throws -> Data {
        try beginCall(Self.storage)
        defer { finishCall(Self.storage) }
        try await park(Self.storage)
        return ResponsivenessFixture.mealPhotoBytes
    }

    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? {
        try beginCall(Self.goals)
        defer { finishCall(Self.goals) }
        try await park(Self.goals)
        return StoredDashboardGoal(calorieTargetKcal: marker, proteinG: 90, carbsG: 200,
                                   fatG: 70, source: .computed)
    }

    func cachedGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func loadGoalsContext(userID: UUID) async throws -> GoalsPageContext {
        try beginCall(Self.goals)
        defer { finishCall(Self.goals) }
        try await park(Self.goals)
        throw MorselError.configurationMissing
    }

    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        try beginCall(Self.goals)
        defer { finishCall(Self.goals) }
        try await park(Self.goals)
        return ResponsivenessFixture.goal(marker: marker)
    }

    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}

    // MARK: - Writes / menus

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
    func attachMealPhoto(userID: UUID, itemID: UUID, photo: FoodImageUpload) async throws {}
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        ResponsivenessFixture.uuid(9_999)
    }

    func localMealRecord(userID: UUID, localMealID: UUID) async throws -> MealRecord? { nil }
    func listMenus(userID: UUID) async throws -> [NamedMenu] { [] }
    func createMenu(userID: UUID, editor: MenuEditorDraft) async throws -> NamedMenu {
        throw MorselError.configurationMissing
    }

    func updateMenu(userID: UUID, menuID: UUID, editor: MenuEditorDraft) async throws {}
    func deleteMenu(userID: UUID, menuID: UUID) async throws {}
}

/// One mounted shell rig: the REAL facade over a real SQLite store, the REAL
/// view model, and the REAL page area. The remote is the harness's counting,
/// delaying, failing seam.
@MainActor
final class ResponsivenessRig {
    let remote: ResponsivenessRemote
    let facade: LocalFirstDashboardRepository
    let viewModel: DashboardViewModel
    let pager: JournalPagerModel
    let machine: JournalTurnMachine
    let scene: ScenePhaseBox
    let window: UIWindow
    let directory: URL

    init(remote: ResponsivenessRemote, facade: LocalFirstDashboardRepository,
         viewModel: DashboardViewModel, pager: JournalPagerModel,
         machine: JournalTurnMachine, scene: ScenePhaseBox,
         window: UIWindow, directory: URL) {
        self.remote = remote
        self.facade = facade
        self.viewModel = viewModel
        self.pager = pager
        self.machine = machine
        self.scene = scene
        self.window = window
        self.directory = directory
    }

    var pixels: WindowPixels { WindowPixels(window) }

    func unmount() { window.isHidden = true }

    /// Drains the run loop (bounded) until `condition` holds.
    func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

@MainActor
enum ResponsivenessRigBuilder {
    /// Builds and mounts one rig. `cacheDirectory` reuses an earlier mount's
    /// SQLite file so a warm cache can be measured in comparable conditions.
    static func make(marker: Double, cacheDirectory: URL? = nil, hold: [String] = [],
                     mealCount: Int = 1,
                     importer: HealthKitWeightImporter? = nil,
                     healthStore: LocalHealthStore? = nil) async throws -> ResponsivenessRig {
        let remote = ResponsivenessRemote()
        await remote.setMarker(marker)
        await remote.setMealCount(mealCount)
        for kind in hold { await remote.hold(kind) }
        let directory = cacheDirectory
            ?? URL(fileURLWithPath: "/tmp/morsel-196-evidence/store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = LocalDataStore.storeURL(root: directory, accountID: ResponsivenessFixture.account)
        let facade = LocalFirstDashboardRepository(
            remote: remote, store: try LocalDataStore(databaseURL: database),
            snapshotCache: try LocalSnapshotCache(databaseURL: database), requestSync: {})
        let viewModel = DashboardViewModel(
            repository: facade, userID: ResponsivenessFixture.account,
            weightImporter: importer, healthStore: healthStore,
            dateProvider: { ResponsivenessFixture.day })
        let pager = JournalPagerModel()
        let machine = JournalTurnMachine(base: .today)
        let scene = ScenePhaseBox()
        let shell = BudgetShell(viewModel: viewModel, scene: scene, pager: pager, machine: machine)
        let host = UIHostingController(rootView: AnyView(
            ScenePhaseHost(scene: scene) {
                shell.frame(width: 390, height: 844)
            }))
        let uiScene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first, "the host app scene must be connected")
        let window = UIWindow(windowScene: uiScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return ResponsivenessRig(remote: remote, facade: facade, viewModel: viewModel,
                                 pager: pager, machine: machine, scene: scene,
                                 window: window, directory: directory)
    }
}

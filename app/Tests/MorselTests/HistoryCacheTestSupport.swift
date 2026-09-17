import XCTest
@testable import Morsel

// Synthetic values only. Every held call is released explicitly, including cancelled tasks.
actor HistoryCacheRemote: DashboardRepository {
    private var held = false
    private var heldCache = false
    private var gates: [String: CheckedContinuation<Void, Error>] = [:]
    private var value: Double = 100

    func hold(cache: Bool = false) { held = true; heldCache = cache; value = 200 }
    func pending(_ key: String) -> Bool { gates[key] != nil }
    func release(_ key: String, error: Error? = nil) {
        let gate = gates.removeValue(forKey: key)
        if let error { gate?.resume(throwing: error) } else { gate?.resume() }
    }
    func releaseAll() {
        held = false
        heldCache = false
        let pending = gates.values
        gates.removeAll()
        for gate in pending { gate.resume() }
    }
    private func wait(_ key: String) async throws {
        try await withCheckedThrowingContinuation { gates[key] = $0 }
    }
    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        let result = HistoryCacheFixture.overview(end: end, days: days, value: value)
        if held { try await wait("history-\(days)") }
        return result
    }
    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        let result = HistoryCacheFixture.snapshot(date: date, value: value)
        if held { try await wait("day-\(date.timeIntervalSince1970)") }
        return result
    }
    func cachedHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview? {
        guard heldCache else { return nil }
        let result = HistoryCacheFixture.overview(end: end, days: days, value: 100)
        try await wait("cache-history-\(days)")
        return result
    }
    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? {
        guard heldCache else { return nil }
        let result = HistoryCacheFixture.snapshot(date: date, value: 100)
        try await wait("cache-day-\(date.timeIntervalSince1970)")
        return result
    }
    func confirmMealItem(userID: UUID, itemID: UUID) async throws {}
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {}
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID { UUID() }
    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        throw URLError(.notConnectedToInternet)
    }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
}

enum HistoryCacheFixture {
    static func overview(end: Date, days: Int, value: Double) -> HistoryOverview {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: end)
        return HistoryOverview(days: (0..<days).reversed().map { offset in
            HistoryDay(date: calendar.date(byAdding: .day, value: -offset, to: today) ?? today,
                       eatenKcal: value, logged: true)
        }, goal: nil)
    }
    static func snapshot(date: Date, value: Double) -> DashboardSnapshot {
        DashboardSnapshot(date: DashboardMath.startOfLocalDay(date), meals: [MealRecord(
            mealLogID: UUID(), mealType: .lunch, eatenAt: date, source: .manual, imagePath: nil,
            items: [MealItem(itemID: UUID(), name: "Synthetic rice \(value)", quantity: 1, unit: .serving,
                             caloriesKcal: value, proteinG: 1, carbsG: 2, fatG: 3,
                             fiberG: nil, sugarG: nil, confidence: nil, notes: nil, source: .manual)]
        )], goal: nil)
    }
}

@MainActor
class HistoryCacheTestCase: XCTestCase {
    let account = UUID()
    let today = DashboardMath.startOfLocalDay(Date(timeIntervalSince1970: 1_770_000_000))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-cache-\(UUID())")
    let remote = HistoryCacheRemote()

    override func tearDown() async throws {
        await remote.releaseAll()
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
    func repository(accountID: UUID? = nil) throws -> LocalFirstDashboardRepository {
        let url = LocalDataStore.storeURL(root: directory, accountID: accountID ?? account)
        return LocalFirstDashboardRepository(remote: remote, store: try LocalDataStore(databaseURL: url),
                                              snapshotCache: try LocalSnapshotCache(databaseURL: url))
    }
    func model(_ repo: any DashboardRepository, accountID: UUID? = nil) -> HistoryViewModel {
        HistoryViewModel(repository: repo, userID: accountID ?? account, dateProvider: { self.today })
    }
    func seed(_ repo: any DashboardRepository, days: Int = 7, date: Date? = nil) async throws {
        _ = try await repo.loadHistory(userID: account, end: today, days: days)
        _ = try await repo.loadToday(userID: account, date: date ?? today)
    }
    func day(_ date: Date? = nil) -> HistoryDay {
        HistoryDay(date: date ?? today, eatenKcal: 100, logged: true)
    }
    func dayKey(_ date: Date? = nil) -> String { "day-\((date ?? today).timeIntervalSince1970)" }
    func waitFor(_ key: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await remote.pending(key)), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let pending = await remote.pending(key)
        XCTAssertTrue(pending, "held request never started: \(key)", file: file, line: line)
        if !pending { await remote.releaseAll() }
    }
    func complete(_ task: Task<Void, Never>, file: StaticString = #filePath, line: UInt = #line) async {
        let done = expectation(description: "held read completed")
        Task { await task.value; done.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [done], timeout: 3)
        if result != .completed {
            task.cancel()
            await remote.releaseAll()
            XCTFail("released read did not complete", file: file, line: line)
        }
    }
}

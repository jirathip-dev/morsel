import Foundation
import XCTest
@testable import Morsel

@MainActor
final class TodayReadHarness {
    struct Read {
        let userID: UUID
        let date: Date
        let continuation: CheckedContinuation<DashboardSnapshot, Error>
    }
    var reads: [Read] = []
    var pending: Set<Int> = []
    var cacheCalls = 0
    var parkCache = false
    var cacheWaiters: [CheckedContinuation<DashboardSnapshot?, Never>] = []
    var cached: DashboardSnapshot?
    var writes = 0
    var localRecord: MealRecord?
    var draining = false

    func cache() async -> DashboardSnapshot? {
        cacheCalls += 1
        if parkCache { return await withCheckedContinuation { cacheWaiters.append($0) } }
        return cached
    }

    func read(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        if draining { return value(date: date, marker: 999) }
        return try await withCheckedThrowingContinuation {
            pending.insert(reads.count)
            reads.append(Read(userID: userID, date: date, continuation: $0))
        }
    }

    func value(date: Date, marker: Double) -> DashboardSnapshot {
        DashboardSnapshot(date: date, meals: [], goal: DashboardGoal(
            calorieTargetKcal: marker, proteinG: 90, carbsG: 200, fatG: 70, source: .computed))
    }

    func finish(_ index: Int, marker: Double = 2000, error: Error? = nil) {
        guard pending.remove(index) != nil else { return }
        let read = reads[index]
        if let error {
            read.continuation.resume(throwing: error)
        } else {
            read.continuation.resume(returning: value(date: read.date, marker: marker))
        }
    }

    func releaseCache() {
        parkCache = false
        let waiting = cacheWaiters
        cacheWaiters.removeAll()
        for waiter in waiting { waiter.resume(returning: cached) }
    }

    func drain() {
        draining = true
        releaseCache()
        for index in pending { finish(index) }
    }
}

struct TodayReadRepository: DashboardRepository {
    let harness: TodayReadHarness
    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? { await harness.cache() }
    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        try await harness.read(userID: userID, date: date)
    }
    func confirmMealItem(userID: UUID, itemID: UUID) async throws { await wrote() }
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws { await wrote() }
    func attachMealPhoto(userID: UUID, itemID: UUID, photo: FoodImageUpload) async throws { await wrote() }
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws { await wrote() }
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        await wrote()
        return await harness.localRecord?.mealLogID ?? UUID()
    }
    func localMealRecord(userID: UUID, localMealID: UUID) async throws -> MealRecord? { await harness.localRecord }
    @MainActor private func wrote() { harness.writes += 1 }
    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        HistoryOverview(days: [], goal: nil, weightTrend: [])
    }
    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        throw MorselError.configurationMissing
    }
}

@MainActor
class TodayRefreshTestCase: XCTestCase {
    let date = DashboardMath.startOfLocalDay(Date(timeIntervalSince1970: 1_789_300_800))
    var harness = TodayReadHarness()
    private var storedModel: DashboardViewModel?
    var model: DashboardViewModel {
        guard let storedModel else { preconditionFailure("setUp must initialize the Today refresh model") }
        return storedModel
    }

    override func setUp() {
        super.setUp()
        harness = TodayReadHarness()
        storedModel = DashboardViewModel(repository: TodayReadRepository(harness: harness),
                                         userID: UUID(), dateProvider: { self.date })
    }

    override func tearDown() {
        harness.drain()
        storedModel = nil
        super.tearDown()
    }

    func until(_ description: String, _ condition: () -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), description, file: file, line: line)
        if !condition() { harness.drain() } // Failed witnesses must not hang the native runner.
    }
}

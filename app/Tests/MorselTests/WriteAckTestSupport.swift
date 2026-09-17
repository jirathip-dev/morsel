import Combine
import XCTest
@testable import Morsel

// Issue #190 test support — the scripted remote and the shared fixtures the
// write-acknowledgement suites drive: the day read parks until the witness
// answers it (in the order the reads were entered), writes are logged — and can
// be refused or parked — and the cache read is counted. Conventions follow
// TodayRefreshTestSupport.swift / GoalsDraftRevisionHarness.swift.

@MainActor
final class WriteAckHarness {
    var readDates: [Date] = []
    var writeLog: [String] = []
    var cacheReads = 0
    var cached: DashboardSnapshot?
    var localRecord: MealRecord?
    /// Every write refuses with this error while set.
    var refusal: Error?
    /// Writes park until `releaseWrites()` while set (a held double tap).
    var parksWrites = false
    private var parkedReads: [Int: CheckedContinuation<DashboardSnapshot, Error>] = [:]
    private var parkedWrites: [CheckedContinuation<Void, Error>] = []
    private var draining = false

    func cachedRead() async -> DashboardSnapshot? {
        cacheReads += 1
        return cached
    }

    func read(date: Date) async throws -> DashboardSnapshot {
        if draining { return day(date: date, meals: []) }
        return try await withCheckedThrowingContinuation { continuation in
            parkedReads[readDates.count] = continuation
            readDates.append(date)
        }
    }

    func write(_ name: String) async throws {
        writeLog.append(name)
        if let refusal { throw refusal }
        guard parksWrites else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            parkedWrites.append(continuation)
        }
    }

    /// Answers the read entered at `index` with the day `meals` describe.
    func answer(_ index: Int, with meals: [MealRecord]) {
        parkedReads.removeValue(forKey: index)?
            .resume(returning: day(date: readDates[index], meals: meals))
    }

    func fail(_ index: Int, _ error: Error) {
        parkedReads.removeValue(forKey: index)?.resume(throwing: error)
    }

    func releaseWrites() {
        let waiting = parkedWrites
        parkedWrites.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// A failed witness must still finish the runner: every parked read answers.
    func drain() {
        draining = true
        let waiting = parkedReads
        parkedReads.removeAll()
        for (index, continuation) in waiting {
            continuation.resume(returning: day(date: readDates[index], meals: []))
        }
        releaseWrites()
    }

    func day(date: Date, meals: [MealRecord]) -> DashboardSnapshot {
        DashboardSnapshot(
            date: DashboardMath.startOfLocalDay(date), meals: meals,
            goal: DashboardGoal(calorieTargetKcal: 2_000, proteinG: 150,
                                carbsG: 200, fatG: 70, source: .computed)
        )
    }
}

struct WriteAckRepository: DashboardRepository {
    let harness: WriteAckHarness

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot { try await harness.read(date: date) }
    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? { await harness.cachedRead() }
    func confirmMealItem(userID: UUID, itemID: UUID) async throws { try await harness.write("review:\(itemID)") }
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {
        try await harness.write("edit:\(update.itemID)")
    }
    func attachMealPhoto(userID: UUID, itemID: UUID, photo: FoodImageUpload) async throws {
        try await harness.write("photo:\(itemID)")
    }
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws { try await harness.write("delete:\(mealLogID)") }
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        try await harness.write("log")
        return UUID()
    }
    func localMealRecord(userID: UUID, localMealID: UUID) async throws -> MealRecord? { await harness.localRecord }
    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        HistoryOverview(days: [], goal: nil, weightTrend: [])
    }
    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws { try await harness.write("goals") }
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        throw MorselError.configurationMissing
    }
}

@MainActor
class WriteAckTestCase: XCTestCase {
    let account = UUID()
    let date = DashboardMath.startOfLocalDay(Date(timeIntervalSince1970: 1_789_300_800))
    var harness = WriteAckHarness()
    private var storedModel: DashboardViewModel?
    var model: DashboardViewModel {
        guard let storedModel else { preconditionFailure("setUp must build the Today model") }
        return storedModel
    }

    override func setUp() {
        super.setUp()
        restart()
    }

    /// A fresh model over a fresh harness (per-action isolation inside one test).
    @discardableResult
    func restart() -> DashboardViewModel {
        harness = WriteAckHarness()
        let built = DashboardViewModel(
            repository: WriteAckRepository(harness: harness),
            userID: account, dateProvider: { self.date }
        )
        storedModel = built
        return built
    }

    override func tearDown() {
        harness.drain()
        storedModel = nil
        super.tearDown()
    }

    /// The day the witnesses mutate, read through the parked first pass.
    func loadedDay(_ meals: [MealRecord]) async {
        let first = Task { await model.load() }
        await until("the first day read is in flight") { harness.readDates.count == 1 }
        harness.answer(0, with: meals)
        await first.value
    }

    @discardableResult
    func until(_ description: String, _ condition: () -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        if !condition() { harness.drain() }
        XCTAssertTrue(condition(), description, file: file, line: line)
        return condition()
    }

    func meal(_ items: [MealItem], imagePath: String? = nil,
              syncState: MealSyncState = .synced) -> MealRecord {
        MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: date, source: .photoVision,
                   imagePath: imagePath, items: items, syncState: syncState)
    }

    func item(_ name: String, quantity: Double = 1, caloriesKcal: Double? = 220,
              confidence: Double? = 0.4) -> MealItem {
        MealItem(itemID: UUID(), name: name, quantity: quantity, unit: .serving,
                 caloriesKcal: caloriesKcal, proteinG: 4, carbsG: 48, fatG: 1, fiberG: nil,
                 sugarG: nil, confidence: confidence, notes: nil, source: .photoVision)
    }
}

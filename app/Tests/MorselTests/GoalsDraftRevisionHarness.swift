import XCTest
@testable import Morsel

// Issue #186 — the Goals draft double: the cached paint, the remote context,
// the direction computation and the write can each be held open so a "late"
// arrival is deterministic, and every Goals read is stamped with the account
// it was asked for. The rest of the read graph is absent by contract: a
// regression that reaches for it fails loudly instead of painting.

@MainActor
final class GoalsDraftRepository: DashboardRepository {
    // Goals-page fixtures.
    var cachedGoal: StoredDashboardGoal?
    var contextStored: StoredDashboardGoal?
    var contextProfile: DashboardProfile?
    var contextLatestWeight: SyncedWeightSample?
    var cachedGoalError: Error?
    var contextError: Error?
    var saveError: Error?
    private(set) var savedGoals: [DashboardGoal] = []
    /// Every account the Goals reads were stamped with, in arrival order.
    private(set) var cachedGoalRequests: [UUID] = []
    private(set) var contextRequests: [UUID] = []

    /// Hold a read open so its arrival is the test's to schedule.
    var holdsCachedGoal = false
    var holdsContext = false
    var holdsSave = false
    private(set) var parkedOnCachedGoal = false
    private(set) var parkedOnContext = false
    private(set) var parkedOnSave = false
    private var cachedGate: CheckedContinuation<Void, Never>?
    private var contextGate: CheckedContinuation<Void, Never>?
    private var saveGate: CheckedContinuation<Void, Never>?

    func releaseCachedGoal() {
        holdsCachedGoal = false
        cachedGate?.resume()
        cachedGate = nil
    }

    func releaseContext() {
        holdsContext = false
        contextGate?.resume()
        contextGate = nil
    }

    func releaseSave() {
        holdsSave = false
        saveGate?.resume()
        saveGate = nil
    }

    func cachedGoals(userID: UUID) async throws -> StoredDashboardGoal? {
        cachedGoalRequests.append(userID)
        if holdsCachedGoal {
            await withCheckedContinuation { continuation in
                cachedGate = continuation
                parkedOnCachedGoal = true
            }
        }
        if let cachedGoalError {
            throw cachedGoalError
        }
        return cachedGoal
    }

    func loadGoalsContext(userID: UUID) async throws -> GoalsPageContext {
        contextRequests.append(userID)
        if holdsContext {
            await withCheckedContinuation { continuation in
                contextGate = continuation
                parkedOnContext = true
            }
        }
        if let contextError {
            throw contextError
        }
        return GoalsPageContext(
            stored: contextStored, profile: contextProfile,
            latestWeight: contextLatestWeight, profileRowRead: true
        )
    }

    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {
        if holdsSave {
            await withCheckedContinuation { continuation in
                saveGate = continuation
                parkedOnSave = true
            }
        }
        if let saveError {
            throw saveError
        }
        savedGoals.append(goal)
    }

    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? {
        cachedGoal
    }

    // A parked direction computation (the #185 interplay).
    private(set) var directions: [GoalDirection] = []
    private var computeContinuations: [Int: CheckedContinuation<DashboardGoal, Error>] = [:]
    private var started: XCTestExpectation?
    var compute: ((GoalDirection) async throws -> DashboardGoal)?

    init() {
        compute = { [unowned self] direction in
            let index = directions.count
            directions.append(direction)
            return try await withCheckedThrowingContinuation { continuation in
                computeContinuations[index] = continuation
                started?.fulfill()
                started = nil
            }
        }
    }

    func expectNextCompute(_ expectation: XCTestExpectation) {
        started = expectation
    }

    func finishCompute(_ index: Int, _ result: Result<DashboardGoal, Error>) {
        guard let continuation = computeContinuations.removeValue(forKey: index) else {
            XCTFail("No parked computation \(index)")
            return
        }
        continuation.resume(with: result)
    }

    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        if let compute {
            return try await compute(direction)
        }
        return DashboardGoal(
            calorieTargetKcal: 2_600, proteinG: 160, carbsG: 310, fatG: 80, source: .computed
        )
    }

    // The rest of the Goals page's read graph is absent by contract: a
    // regression that reaches for it fails loudly instead of painting.
    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        throw MorselError.requestFailed(500, "Goals must not run the full Today read")
    }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        throw MorselError.requestFailed(500, "Goals must not read History")
    }

    func loadMealImage(userID: UUID, path: String) async throws -> Data {
        throw MorselError.requestFailed(500, "Goals must not read meal photos")
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {
        throw MorselError.requestFailed(500, "unsupported in the goals draft double")
    }

    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {
        throw MorselError.requestFailed(500, "unsupported in the goals draft double")
    }

    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {
        throw MorselError.requestFailed(500, "unsupported in the goals draft double")
    }

    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        throw MorselError.requestFailed(500, "unsupported in the goals draft double")
    }
}

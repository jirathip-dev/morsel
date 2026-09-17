import Foundation
@testable import Morsel

// Issue #184 — the request spy for the Goals-open path. Every repository call
// the page makes is recorded; the full Today dashboard read is counted and
// fails loudly, so a regression cannot come back unnoticed. `cachedToday` is
// the narrow local read the page IS allowed to make: it can be parked (a held
// storage read) and can serve a chosen calorie total or fail.

@MainActor
final class GoalsPageRequestSpy: DashboardRepository {
    /// Every repository call the goals page makes, in order.
    private(set) var calls: [String] = []
    /// The narrow local-day totals served in order (nil = nothing cached for
    /// that local day yet); the last entry repeats.
    var dayTotals: [Double?] = [nil]
    var dayTotalError: Error?
    /// Park the narrow local read / the goals-context read until released.
    var holdsStorage = false
    var holdsContext = false
    private(set) var parkedOnStorage = false
    private(set) var parkedOnContext = false
    private var storageGate: CheckedContinuation<Void, Never>?
    private var contextGate: CheckedContinuation<Void, Never>?
    private var servedDayTotals = 0
    /// What a full Today read returns when a test deliberately seeds through
    /// it; nil means the goals page must never trigger one.
    var seededToday: DashboardSnapshot?

    // Goals-page reads + fixtures.
    var storedGoal: StoredDashboardGoal?
    var contextProfile: DashboardProfile?
    var contextLatestWeight: SyncedWeightSample?
    var goalsContextError: Error?
    private(set) var savedGoal: DashboardGoal?
    /// Full Today dashboard reads: must stay 0 on the goals-open path.
    private(set) var fullDashboardReads = 0
    var compute: ((GoalDirection) async throws -> DashboardGoal)?

    func releaseStorage() {
        holdsStorage = false
        storageGate?.resume()
        storageGate = nil
    }

    func releaseContext() {
        holdsContext = false
        contextGate?.resume()
        contextGate = nil
    }

    func cachedGoals(userID: UUID) async throws -> StoredDashboardGoal? {
        calls.append("cachedGoals")
        return storedGoal
    }

    func loadGoalsContext(userID: UUID) async throws -> GoalsPageContext {
        calls.append("loadGoalsContext")
        if holdsContext {
            await withCheckedContinuation { continuation in
                contextGate = continuation
                parkedOnContext = true
            }
        }
        if let goalsContextError {
            throw goalsContextError
        }
        return GoalsPageContext(
            stored: storedGoal, profile: contextProfile,
            latestWeight: contextLatestWeight, profileRowRead: true
        )
    }

    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? {
        calls.append("cachedToday")
        // Consume the served total BEFORE parking so a parked read keeps its
        // own value and a later read gets the next one.
        let index = min(servedDayTotals, dayTotals.count - 1)
        servedDayTotals += 1
        if holdsStorage {
            await withCheckedContinuation { continuation in
                storageGate = continuation
                parkedOnStorage = true
            }
        }
        if let dayTotalError {
            throw dayTotalError
        }
        guard let total = dayTotals.isEmpty ? nil : dayTotals[index] else {
            return nil
        }
        return DashboardSnapshot(date: date, meals: [Self.meal(calories: total, at: date)], goal: nil)
    }

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        calls.append("loadToday")
        fullDashboardReads += 1
        guard let seededToday else {
            throw MorselError.requestFailed(500, "Goals must not run the full Today dashboard read")
        }
        return seededToday
    }

    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? {
        storedGoal
    }

    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {
        savedGoal = goal
        storedGoal = StoredDashboardGoal(
            calorieTargetKcal: goal.calorieTargetKcal, proteinG: goal.proteinG,
            carbsG: goal.carbsG, fatG: goal.fatG, source: goal.source
        )
    }

    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        if let compute { return try await compute(direction) }
        return DashboardGoal(calorieTargetKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70, source: .computed)
    }

    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        calls.append("loadHistory")
        throw MorselError.requestFailed(500, "Goals must not read History")
    }

    func loadMealImage(userID: UUID, path: String) async throws -> Data {
        calls.append("loadMealImage")
        throw MorselError.requestFailed(500, "Goals must not read meal photos")
    }

    func confirmMealItem(userID: UUID, itemID: UUID) async throws {
        throw MorselError.requestFailed(500, "unsupported in the goals-page spy")
    }

    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws {
        throw MorselError.requestFailed(500, "unsupported in the goals-page spy")
    }

    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {
        throw MorselError.requestFailed(500, "unsupported in the goals-page spy")
    }

    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        throw MorselError.requestFailed(500, "unsupported in the goals-page spy")
    }

    /// One meal carrying `calories` kcal: the cached local-day snapshot the
    /// narrow read sums (DashboardMath.totals).
    static func meal(calories: Double, at date: Date) -> MealRecord {
        MealRecord(
            mealLogID: UUID(), mealType: .lunch, eatenAt: date, source: .manual,
            items: [MealItem(
                itemID: UUID(), name: "fixture", quantity: 1, unit: .serving,
                caloriesKcal: calories, proteinG: 0, carbsG: 0, fatG: 0,
                fiberG: 0, sugarG: 0, confidence: 1, notes: nil
            )]
        )
    }
}

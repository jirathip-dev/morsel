import Foundation
import XCTest
@testable import Morsel

@MainActor
final class JournalDiaryLoadTests: XCTestCase {
    func testDateChangeSupersedesAnInFlightDayWithoutPaintingItsResult() async throws {
        let first = Date(timeIntervalSince1970: 1_780_000_000)
        let second = Calendar.current.date(byAdding: .day, value: -1, to: first) ?? first
        var clock = first
        let repository = DiaryReadRepository()
        repository.parkedDate = DashboardMath.startOfLocalDay(first)
        let model = DashboardViewModel(repository: repository, userID: UUID(), dateProvider: { clock })
        let oldRead = Task { await model.load() }
        for _ in 0..<100 where repository.pending == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(repository.pending, "the old day must actually be in flight")
        clock = second
        await model.load()
        XCTAssertEqual(model.snapshot?.date, DashboardMath.startOfLocalDay(second),
                       "a new date must load without waiting for the old day")
        repository.release()
        await oldRead.value
        XCTAssertEqual(model.snapshot?.date, DashboardMath.startOfLocalDay(second),
                       "the stale day must never publish over the selected day")
    }
}

final class DiaryReadRepository: DashboardRepository, @unchecked Sendable {
    var parkedDate: Date?
    var pending: CheckedContinuation<DashboardSnapshot, Error>?
    var requestedDates: [Date] = []
    var cached: DashboardSnapshot?
    var failure: Error?
    var savedDraft: MealDraft?
    var confirmedItem: UUID?
    var updatedItem: MealItemUpdate?
    var meals: [MealRecord] = []

    func release() {
        if let parkedDate { pending?.resume(returning: DashboardSnapshot(date: parkedDate, meals: [], goal: nil)) }
        pending = nil
    }
    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? {
        cached?.date == DashboardMath.startOfLocalDay(date) ? cached : nil
    }
    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        let day = DashboardMath.startOfLocalDay(date)
        requestedDates.append(day)
        if day == parkedDate { return try await withCheckedThrowingContinuation { pending = $0 } }
        if let failure { throw failure }
        return DashboardSnapshot(date: day, meals: meals.filter {
            DashboardMath.startOfLocalDay($0.eatenAt) == day
        }, goal: nil)
    }
    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        HistoryOverview(days: [], goal: nil, weightTrend: [])
    }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func confirmMealItem(userID: UUID, itemID: UUID) async throws { confirmedItem = itemID }
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws { updatedItem = update }
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws {}
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        savedDraft = draft
        return UUID()
    }
    func loadMealImage(userID: UUID, path: String) async throws -> Data { Data() }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws {}
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        DashboardGoal(calorieTargetKcal: 2_000, proteinG: 100, carbsG: 200, fatG: 70, source: .computed)
    }
}

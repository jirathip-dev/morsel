import Foundation
import XCTest
@testable import Morsel

@MainActor
final class TrainingDayFixture {
    static let states = [
        "usual", "confirmed", "unavailable", "unconfirmed", "blank", "invalid", "valid-draft", "pending",
        "save-error", "confirmed-sheet", "edit", "undo", "missing-health", "denied-health", "stale-health",
        "zero-health", "partial-health", "workout-only", "health-loading", "health-error", "unavailable-sheet",
        "manual-consent", "manual-ready", "empty", "loading", "stale-data", "error",
        "multi-meal", "partial-meal", "rollover"
    ]
    static let pages: Set<String> = ["usual", "confirmed", "unavailable", "undo", "empty", "loading", "stale-data",
                                     "error", "multi-meal", "partial-meal"]
    let state: String
    var clock = Date(timeIntervalSince1970: 1_789_531_200)
    let gate = TrainingDayGate()
    lazy var model = TrainingFuelModel(now: { self.clock }, accept: {
        if self.state == "pending" { await self.gate.wait() }
        if self.state == "save-error" { throw CocoaError(.fileWriteUnknown) }
    })
    let repository: TrainingDayRepository
    lazy var viewModel = DashboardViewModel(repository: repository, userID: UUID(), dateProvider: { self.clock })
    var tasks: [Task<Void, Never>] = []

    init(_ state: String) {
        self.state = state
        repository = TrainingDayRepository()
    }

    func prepare() async {
        let unavailable = ["unavailable", "unavailable-sheet", "loading", "error"].contains(state)
        let goal = DashboardGoal(calorieTargetKcal: 2_126, proteinG: 100, carbsG: 250, fatG: 65,
                                 source: state.hasPrefix("manual-") ? .manual : .computed)
        let item = MealItem(itemID: UUID(), name: "Focaccia", quantity: 1, unit: .serving,
                            caloriesKcal: state == "partial-meal" ? nil : 300,
                            proteinG: 8, carbsG: 46, fatG: 9, fiberG: nil, sugarG: nil,
                            confidence: 0.9, notes: "Fictional training-day test fixture")
        var meals = [MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: clock,
                                source: .manual, items: [item])]
        if state == "empty" { meals = [] }
        if state == "multi-meal" {
            meals.append(MealRecord(mealLogID: UUID(), mealType: .dinner, eatenAt: clock,
                                    source: .manual, items: [item]))
        }
        let snapshot = DashboardSnapshot(date: clock, meals: meals, goal: unavailable ? nil : goal)
        repository.snapshot = snapshot
        repository.state = state
        if state == "loading" {
            tasks.append(Task { await self.viewModel.load() })
            await wait { self.viewModel.isLoading }
        } else {
            await viewModel.load()
        }
        model.synchronize(unavailable ? nil : snapshot)
        seedHealth()
        await prepareAnswer()
    }

    private func prepareAnswer() async {
        if ["confirmed", "confirmed-sheet", "edit", "undo", "rollover"].contains(state) {
            model.openSheet()
            model.draft = "300"
            await model.confirm()
            model.cancel()
        }
        if state == "undo" { model.undo(); model.cancel() }
        if state == "rollover" { clock = clock.addingTimeInterval(86_400); model.synchronize(nil) }
        if !Self.pages.contains(state) { model.openSheet() }
        if state == "edit" { model.beginReview() }
        if state == "invalid" { model.draft = "-5" }
        if ["valid-draft", "pending", "save-error", "manual-consent", "manual-ready"].contains(state) {
            model.draft = "300"
        }
        if state == "manual-ready" { model.acknowledgesDayOnly = true }
        if state == "save-error" { await model.confirm() }
        if state == "pending" {
            tasks.append(Task { await self.model.confirm() })
            await wait { self.model.isPending }
        }
        await prepareHealthRead()
    }

    private func prepareHealthRead() async {
        if state == "health-loading" {
            tasks.append(Task {
                await self.model.readHealth { await self.gate.wait(); return TrainingFuelContext() }
            })
            await wait { self.model.isReadingHealth }
        }
    }

    private func seedHealth() {
        let sample = state == "stale-health" ? clock.addingTimeInterval(-86_400) : clock
        let movement = TrainingFuelReading(value: state == "zero-health" ? "0 kcal" : "386 kcal",
                                          sampleDate: sample, source: "Apple Health · active energy", checkedAt: clock)
        let workout = TrainingFuelReading(value: "Strength training · 48 min", sampleDate: sample,
                                         source: "Apple Health · Watch", checkedAt: clock)
        let missing = ["missing-health", "denied-health", "health-error"].contains(state)
        model.context = TrainingFuelContext(
            movement: missing || state == "workout-only" ? nil : movement,
            workout: missing || state == "partial-health" ? nil : workout,
            movementFailed: state == "health-error", workoutFailed: state == "health-error")
    }

    private func wait(_ ready: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !ready(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ready(), "Fixture did not enter \(state)")
    }

    func finish() async {
        model.cancel()
        gate.finish()
        repository.state = "usual"
        repository.gate.finish()
        for task in tasks { task.cancel(); await task.value }
        tasks = []
    }
}

@MainActor
final class TrainingDayGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
}

@MainActor
final class TrainingDayRepository: DashboardRepository {
    var snapshot: DashboardSnapshot?
    var state = "usual"
    let gate = TrainingDayGate()

    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        if state == "loading" { await gate.wait() }
        if state == "error" || state == "stale-data" { throw URLError(.notConnectedToInternet) }
        guard let snapshot else { throw URLError(.badServerResponse) }
        return snapshot
    }
    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? {
        state == "stale-data" ? snapshot : nil
    }
    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        HistoryOverview(days: [], goal: nil, weightTrend: [])
    }
    func logMeal(userID: UUID, draft: MealDraft, photo: FoodImageUpload?) async throws -> UUID {
        throw URLError(.unsupportedURL)
    }
    func confirmMealItem(userID: UUID, itemID: UUID) async throws { throw URLError(.unsupportedURL) }
    func updateMealItem(userID: UUID, update: MealItemUpdate) async throws { throw URLError(.unsupportedURL) }
    func deleteMealLog(userID: UUID, mealLogID: UUID) async throws { throw URLError(.unsupportedURL) }
    func loadMealImage(userID: UUID, path: String) async throws -> Data { throw URLError(.unsupportedURL) }
    func loadGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }
    func computeGoals(userID: UUID, direction: GoalDirection) async throws -> DashboardGoal {
        throw URLError(.unsupportedURL)
    }
    func saveGoals(userID: UUID, goal: DashboardGoal) async throws { throw URLError(.unsupportedURL) }
}

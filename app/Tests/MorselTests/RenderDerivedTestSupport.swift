import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #195 — shared fixtures and stubs for the derived-work measurement probe
// and the reuse regression. Synthetic values only; no production seam here.

/// One scripted day read; every other capability is unused by these tests.
@MainActor
final class ProbeRemote: DashboardRepository {
    var snapshot: DashboardSnapshot
    var overview: HistoryOverview?
    private(set) var dayReads = 0
    init(snapshot: DashboardSnapshot) { self.snapshot = snapshot }
    func loadToday(userID: UUID, date: Date) async throws -> DashboardSnapshot {
        dayReads += 1
        return snapshot
    }
    func loadHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview {
        overview ?? HistoryOverview(days: [], goal: nil)
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

/// Synthetic day builders: `small` is a light day, `dense` a 40-meal one whose
/// item count matches the heavy end the measurement probe reports.
enum RenderDerivedFixture {
    static func snapshot(day: Date, meals: Int, itemsPerMeal: Int, kcal: Double = 120) -> DashboardSnapshot {
        let types = MealType.allCases
        return DashboardSnapshot(date: day, meals: (0..<meals).map { index in
            MealRecord(
                mealLogID: UUID(),
                mealType: types[index % types.count],
                eatenAt: day.addingTimeInterval(Double(index) * 600 + 28_800),
                source: .manual,
                items: (0..<itemsPerMeal).map { item in
                    MealItem(
                        itemID: UUID(), name: "synthetic \(index)-\(item)", quantity: 1, unit: .serving,
                        caloriesKcal: kcal + Double(item), proteinG: 6, carbsG: 20, fatG: 4,
                        fiberG: 2, sugarG: 3, confidence: item.isMultiple(of: 4) ? 0.4 : 0.9,
                        notes: nil, source: .manual
                    )
                }
            )
        }, goal: nil)
    }

    /// A meal whose one item always needs review (low confidence, manual).
    static func reviewMeal(day: Date, kcal: Double = 200) -> MealRecord {
        MealRecord(
            mealLogID: UUID(), mealType: .snack, eatenAt: day.addingTimeInterval(20 * 3_600),
            source: .manual,
            items: [MealItem(
                itemID: UUID(), name: "synthetic review", quantity: 1, unit: .serving,
                caloriesKcal: kcal, proteinG: 3, carbsG: 9, fatG: 2, fiberG: nil, sugarG: nil,
                confidence: 0.3, notes: nil, source: .manual
            )]
        )
    }
}

/// Mounts a real view in a scene-backed window (a scene-less window paints black).
@MainActor
enum RenderDerivedMount {
    static func window(_ root: some View) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return window
    }

    /// Synchronous run-loop pump: async contexts cannot call `RunLoop.run(until:)`.
    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

/// The un-reused reference: the exact scans the base computed on every access.
@MainActor
enum RenderDerivedReference {
    static func assertParity(_ model: DashboardViewModel, meals: [MealRecord],
                             file: StaticString = #filePath, line: UInt = #line) {
        let totals = model.totals
        let groups = model.mealGroups
        let review = model.reviewItems
        XCTAssertEqual(totals, DashboardMath.totals(for: meals), file: file, line: line)
        let reference = MealType.allCases.compactMap { type -> MealGroup? in
            let matching = meals.filter { $0.mealType == type }
            return matching.isEmpty ? nil : MealGroup(type: type, meals: matching)
        }
        XCTAssertEqual(groups, reference, file: file, line: line)
        XCTAssertEqual(review, meals.flatMap(\.items).filter(\.needsReview), file: file, line: line)
    }
}

import Foundation
import SwiftUI

#if DEBUG
private enum PreviewData {
    static let userID = UUID()

    static let snapshot = DashboardSnapshot(
        date: Date(),
        meals: [
            MealRecord(
                mealLogID: UUID(),
                mealType: .breakfast,
                eatenAt: Date(),
                source: .photoVision,
                items: [
                    MealItem(
                        itemID: UUID(),
                        name: "Greek yogurt & granola",
                        quantity: 1,
                        unit: .serving,
                        caloriesKcal: 250,
                        proteinG: 24,
                        carbsG: 30,
                        fatG: 9,
                        fiberG: nil,
                        sugarG: nil,
                        confidence: 0.90,
                        notes: nil,
                        source: .photoVision
                    )
                ]
            ),
            MealRecord(
                mealLogID: UUID(),
                mealType: .lunch,
                eatenAt: Date(),
                source: .photoVision,
                items: [
                    MealItem(
                        itemID: UUID(),
                        name: "Jasmine rice",
                        quantity: 1,
                        unit: .serving,
                        caloriesKcal: 220,
                        proteinG: nil,
                        carbsG: 48,
                        fatG: nil,
                        fiberG: nil,
                        sugarG: nil,
                        confidence: 0.90,
                        notes: nil,
                        source: .photoVision
                    ),
                    MealItem(
                        itemID: UUID(),
                        name: "Stir-fried veg",
                        quantity: 1,
                        unit: .serving,
                        caloriesKcal: 90,
                        proteinG: nil,
                        carbsG: 10,
                        fatG: 4,
                        fiberG: 4,
                        sugarG: nil,
                        confidence: 0.70,
                        notes: "approx portion",
                        source: .photoVision
                    )
                ]
            )
        ],
        goal: DashboardGoal(
            calorieTargetKcal: 2_077,
            proteinG: 156,
            carbsG: 233,
            fatG: 58,
            source: .computed
        )
    )
}

#Preview("Today") {
    let viewModel = DashboardViewModel(
        repository: MockDashboardRepository(snapshot: PreviewData.snapshot),
        userID: PreviewData.userID
    )
    TodayView(viewModel: viewModel, showSettings: {})
}
#endif

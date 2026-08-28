import Combine
import Foundation

struct MealGroup: Identifiable, Equatable {
    let type: MealType
    let meals: [MealRecord]

    var id: MealType { type }

    var totalCalories: Double {
        DashboardMath.totals(for: meals).caloriesKcal
    }

    var firstMealTime: Date? {
        meals.first?.eatenAt
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var snapshot: DashboardSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var reviewedItemIDs: Set<UUID> = []

    private let repository: any DashboardRepository
    private let userID: UUID
    private let accessToken: String
    private let dateProvider: () -> Date

    init(
        repository: any DashboardRepository,
        userID: UUID,
        accessToken: String,
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.userID = userID
        self.accessToken = accessToken
        self.dateProvider = dateProvider
    }

    var totals: DashboardTotals {
        DashboardMath.totals(for: snapshot?.meals ?? [])
    }

    var mealGroups: [MealGroup] {
        guard let meals = snapshot?.meals else {
            return []
        }
        return MealType.allCases.compactMap { type in
            let matchingMeals = meals.filter { $0.mealType == type }
            return matchingMeals.isEmpty ? nil : MealGroup(type: type, meals: matchingMeals)
        }
    }

    var reviewItems: [MealItem] {
        snapshot?.meals
            .flatMap(\.items)
            .filter { item in
                !reviewedItemIDs.contains(item.itemID)
                    && DashboardMath.confidenceBadge(for: item.confidence).needsReview
            } ?? []
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            snapshot = try await repository.loadToday(
                userID: userID,
                accessToken: accessToken,
                date: dateProvider()
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markReviewed(_ itemID: UUID) {
        reviewedItemIDs.insert(itemID)
    }
}

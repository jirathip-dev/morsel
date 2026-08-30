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
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var weightImportError: String?

    let repository: any DashboardRepository
    let userID: UUID
    private let weightImporter: HealthKitWeightImporter?
    private let dateProvider: () -> Date
    private var reloadAfterLoad = false

    init(
        repository: any DashboardRepository,
        userID: UUID,
        weightImporter: HealthKitWeightImporter? = nil,
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.userID = userID
        self.weightImporter = weightImporter
        self.dateProvider = dateProvider
    }

    var totals: DashboardTotals {
        DashboardMath.totals(for: snapshot?.meals ?? [])
    }

    var netEnergy: Double {
        DashboardMath.netEnergy(intake: totals.caloriesKcal, activeBurn: snapshot?.activeEnergyBurned ?? 0)
    }

    var netEnergyDeltaFromGoal: Double? {
        guard let goal = snapshot?.goal else { return nil }
        return netEnergy - goal.calorieTargetKcal
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
            .filter(\.needsReview) ?? []
    }

    func importWeights() async {
        guard let weightImporter else { return }
        do {
            try await weightImporter.importBodyMass()
            try await weightImporter.importActiveEnergy()
            await load()
            weightImporter.startObserving { [weak self] error in
                Task { @MainActor in
                    self?.weightImportError = error.localizedDescription
                }
            }
        } catch is CancellationError {
            return
        } catch {
            weightImportError = error.localizedDescription
        }
    }

    func load() async {
        if isLoading {
            reloadAfterLoad = true
            return
        }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            if reloadAfterLoad {
                reloadAfterLoad = false
                Task { await load() }
            }
        }
        do {
            snapshot = try await repository.loadToday(
                userID: userID,
                date: dateProvider()
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addMeal(draft: MealDraft, photo: FoodImageUpload?) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await repository.logMeal(userID: userID, draft: draft, photo: photo)
            snapshot = try await repository.loadToday(userID: userID, date: dateProvider())
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func markReviewed(_ itemID: UUID) async -> Bool {
        do {
            try await repository.confirmMealItem(userID: userID, itemID: itemID)
            snapshot = try await repository.loadToday(userID: userID, date: dateProvider())
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateMealItem(_ update: MealItemUpdate) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await repository.updateMealItem(userID: userID, update: update)
            snapshot = try await repository.loadToday(userID: userID, date: dateProvider())
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteMeal(_ mealLogID: UUID) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await repository.deleteMealLog(userID: userID, mealLogID: mealLogID)
            snapshot = try await repository.loadToday(userID: userID, date: dateProvider())
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

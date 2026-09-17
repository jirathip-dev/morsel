import Foundation

// Issue #190 — a confirmed write owns its own outcome: the projections below
// touch ONLY the acknowledged record, and the day read stays freshness (it is
// invalidated by `confirmedWrite`, never awaited). They live beside
// ViewModel.swift because that file sits at the 400-line budget; like
// `LocalFirstDashboardRepository`'s cross-file extensions (#152/#188), these
// seams are internal so the state-owning file can reach them.

extension DashboardViewModel {
    /// Issue #190 — one mutation per acknowledged record: a repeated tap joins
    /// the write already in flight instead of issuing a second write.
    func joinedWrite(_ key: String, _ write: @escaping () async throws -> Void) async throws {
        if let inFlight = writesInFlight[key] {
            try await inFlight.value
            return
        }
        let task = Task { @MainActor in try await write() }
        writesInFlight[key] = task
        defer { writesInFlight[key] = nil }
        try await task.value
    }

    /// Issue #190 — the day with its meals replaced by `change`; every other
    /// day read (goal, trend, provenance) keeps its bytes.
    func confirmingMeals(_ snapshot: DashboardSnapshot,
                         _ change: (MealRecord) -> MealRecord?) -> DashboardSnapshot {
        DashboardSnapshot(date: snapshot.date, meals: snapshot.meals.compactMap(change), goal: snapshot.goal,
                          weightTrend: snapshot.weightTrend, activeEnergyBurned: snapshot.activeEnergyBurned,
                          readProvenance: snapshot.readProvenance, datedTarget: snapshot.datedTarget)
    }

    /// Issue #190 — ONLY the acknowledged meal row changes.
    func confirming(_ mealLogID: UUID, in snapshot: DashboardSnapshot,
                    _ change: (MealRecord) -> MealRecord) -> DashboardSnapshot {
        confirmingMeals(snapshot) { $0.mealLogID == mealLogID ? change($0) : $0 }
    }

    /// Issue #190 — ONLY the acknowledged item's own row changes.
    func confirmingItem(_ itemID: UUID, in snapshot: DashboardSnapshot,
                        _ change: (MealItem) -> MealItem) -> DashboardSnapshot {
        confirmingMeals(snapshot) { meal in
            guard meal.items.contains(where: { $0.itemID == itemID }) else { return meal }
            return acknowledgedRow(meal, items: meal.items.map { $0.itemID == itemID ? change($0) : $0 })
        }
    }

    /// Issue #190 — the acknowledged item: exactly the fields its own write
    /// owns, with no invented confidence, notes, artwork or menu grouping.
    func acknowledgedRow(_ item: MealItem, _ update: MealItemUpdate? = nil,
                         confidence: Double? = nil) -> MealItem {
        MealItem(itemID: item.itemID, name: update?.name ?? item.name, quantity: update?.quantity ?? item.quantity,
                 unit: item.unit, caloriesKcal: update?.caloriesKcal ?? item.caloriesKcal,
                 proteinG: update?.proteinG ?? item.proteinG, carbsG: update?.carbsG ?? item.carbsG,
                 fatG: update?.fatG ?? item.fatG, fiberG: item.fiberG, sugarG: item.sugarG,
                 confidence: confidence ?? item.confidence,
                 notes: update?.source == .manualEdit ? MealSource.manualEdit.rawValue : item.notes,
                 source: item.source, mealImage: item.mealImage, menuGroupID: item.menuGroupID,
                 menuName: item.menuName, artworkID: item.artworkID)
    }

    /// Issue #190 — the acknowledged meal: the fields its own write owns.
    func acknowledgedRow(_ meal: MealRecord, items: [MealItem]? = nil, image: MealImage? = nil) -> MealRecord {
        MealRecord(mealLogID: meal.mealLogID, mealType: meal.mealType, eatenAt: meal.eatenAt, source: meal.source,
                   imagePath: image?.path ?? meal.imagePath, image: image ?? meal.image, items: items ?? meal.items,
                   itemsRead: meal.itemsRead, syncState: meal.syncState)
    }
}

import SwiftUI

// Issue #176 — Today's presentation ownership; issue #229 — the saved-edit
// confirmation the row paints. Moved out of Views.swift so the shipped files
// stay inside the repo lint budgets.

@MainActor
final class JournalPresentationModel: ObservableObject {
    @Published private(set) var editingItem: MealItem?
    @Published private(set) var mealToDelete: MealRecord?
    /// Issue #229 — the item whose edit was just saved, for the row's
    /// confirmation line. Local, truthful state: the save was accepted and the
    /// journal reloaded; a row still queued for sync keeps its own `pending
    /// sync` marker, so the confirmation never claims a server round-trip.
    @Published private(set) var savedItemID: UUID?

    var isPresenting: Bool { editingItem != nil || mealToDelete != nil }

    func requestEdit(_ item: MealItem) {
        guard !isPresenting else { return }
        savedItemID = nil
        editingItem = item
    }

    func requestDelete(_ meal: MealRecord) {
        guard !isPresenting else { return }
        mealToDelete = meal
    }

    /// A successful edit save closes the sheet the way its Cancel does.
    func finishEdit() { editingItem = nil }

    /// Issue #229 — records the row that must show the saved confirmation.
    func noteSaved(_ itemID: UUID) {
        savedItemID = itemID
    }

    /// The confirmation copy for one row (nil unless it is the saved row).
    func savedConfirmation(for itemID: UUID) -> String? {
        savedItemID == itemID ? "Updated" : nil
    }

    /// `.sheet(item:)` writes its dismissal through these bindings.
    var editBinding: Binding<MealItem?> {
        Binding(get: { self.editingItem }, set: { self.editingItem = $0 })
    }
    var deleteBinding: Binding<MealRecord?> {
        Binding(get: { self.mealToDelete }, set: { self.mealToDelete = $0 })
    }
}

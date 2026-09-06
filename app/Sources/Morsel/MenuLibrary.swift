import Foundation

// Issue #152 — menu library state shared by the Add-Meal picker and the
// Menus screen. Loads through the repository (local-first facade or the
// remote Supabase path); writes run the authenticated seams and refresh the
// in-memory list so both surfaces always agree.

@MainActor
final class MenuLibraryModel: ObservableObject {
    @Published private(set) var menus: [NamedMenu] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: any DashboardRepository
    private let userID: UUID

    init(repository: any DashboardRepository, userID: UUID) {
        self.repository = repository
        self.userID = userID
    }

    var isEmpty: Bool {
        menus.isEmpty
    }

    func loadMenus() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await repository.listMenus(userID: userID)
            menus = loaded.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
            if errorMessage == nil {
                menus = []
            }
        }
        isLoading = false
    }

    /// Saves a new menu (menuID nil) or edits an existing one; refreshes
    /// the shared list on success. Returns true only when the write landed.
    func save(editor: MenuEditorDraft, editing menuID: UUID?) async -> Bool {
        errorMessage = nil
        do {
            if let menuID {
                try await repository.updateMenu(userID: userID, menuID: menuID, editor: editor)
            } else {
                _ = try await repository.createMenu(userID: userID, editor: editor)
            }
            await loadMenus()
            return true
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
            return false
        }
    }

    func delete(menuID: UUID) async -> Bool {
        errorMessage = nil
        do {
            try await repository.deleteMenu(userID: userID, menuID: menuID)
            await loadMenus()
            return true
        } catch {
            errorMessage = DashboardUserMessage.userMessage(for: error)
            return false
        }
    }
}

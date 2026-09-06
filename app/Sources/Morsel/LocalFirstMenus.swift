import Foundation

// Issue #152 — local-first named menus. The menu list is small and changes
// rarely: reads hydrate from the account-scoped cache first and write the
// authoritative remote snapshot through on success; CRUD executes on the
// authenticated remote path (menus are account templates — same honest
// offline behavior as editing a synced meal) and refreshes the cache. Meal
// logs stay snapshot copies, so menu edits never rewrite past rows.

extension LocalFirstDashboardRepository {
    func listMenus(userID: UUID) async throws -> [NamedMenu] {
        let userKey = userID.uuidString
        do {
            let menus = try await remote.listMenus(userID: userID)
            if let payload = try? Self.encode(menus) {
                try? snapshotCache.saveMenusCache(userKey: userKey, payload: payload)
            }
            return menus
        } catch {
            guard let payload = try snapshotCache.loadMenusCache(userKey: userKey) else {
                throw error
            }
            return try Self.decode([NamedMenu].self, payload)
        }
    }

    func createMenu(userID: UUID, editor: MenuEditorDraft) async throws -> NamedMenu {
        let menu = try await remote.createMenu(userID: userID, editor: editor)
        refreshMenusCache(userID: userID)
        return menu
    }

    func updateMenu(userID: UUID, menuID: UUID, editor: MenuEditorDraft) async throws {
        try await remote.updateMenu(userID: userID, menuID: menuID, editor: editor)
        refreshMenusCache(userID: userID)
    }

    func deleteMenu(userID: UUID, menuID: UUID) async throws {
        try await remote.deleteMenu(userID: userID, menuID: menuID)
        refreshMenusCache(userID: userID)
    }

    /// Refreshes the durable menu cache after a successful write (best
    /// effort — a cache hiccup must never fail an already-saved menu).
    private func refreshMenusCache(userID: UUID) {
        Task {
            if let menus = try? await remote.listMenus(userID: userID),
               let payload = try? Self.encode(menus) {
                try? snapshotCache.saveMenusCache(userKey: userID.uuidString, payload: payload)
            }
        }
    }
}

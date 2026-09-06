import XCTest
@testable import Morsel

// Issue #152 — named menus: template CRUD on the mock repository, snapshot
// logging ('Log from menu' stamps a shared group id + a menu name copy on
// every item), the edit-after-log immutability guarantee (template edits
// NEVER rewrite past meals), and the display grouping both journal surfaces
// render from (consecutive same-group items coalesce; loose items stay flat).
@MainActor
final class NamedMenusTests: XCTestCase {
    private let userID = UUID()

    private func makeRepository(menus: [NamedMenu] = []) -> MockDashboardRepository {
        let repository = MockDashboardRepository(
            snapshot: DashboardSnapshot(
                date: Date(timeIntervalSince1970: 100),
                meals: [],
                goal: nil
            )
        )
        repository.seed(menus: menus)
        return repository
    }

    private func templateItem(_ name: String, kcal: Double?) -> MenuTemplateItem {
        MenuTemplateItem(name: name, quantity: 1, unit: .serving, caloriesKcal: kcal)
    }

    // MARK: - Repository CRUD

    func testListMenusSortsAlphabetically() async throws {
        let repository = makeRepository(menus: [
            NamedMenu(menuID: UUID(), name: "zinger", items: [templateItem("z", kcal: 1)]),
            NamedMenu(menuID: UUID(), name: "alpha", items: [templateItem("a", kcal: 1)])
        ])

        let menus = try await repository.listMenus(userID: userID)

        XCTAssertEqual(menus.map(\.name), ["alpha", "zinger"])
    }

    func testCreateUpdateDeleteMenuRoundTrip() async throws {
        let repository = makeRepository()

        let created = try await repository.createMenu(
            userID: userID,
            editor: MenuEditorDraft(name: "  Brunch set  ", items: [templateItem("eggs", kcal: 90)])
        )
        XCTAssertEqual(created.name, "Brunch set")
        XCTAssertEqual(created.items.count, 1)

        try await repository.updateMenu(
            userID: userID,
            menuID: created.menuID,
            editor: MenuEditorDraft(name: "Brunch set", items: [
                templateItem("eggs", kcal: 90),
                templateItem("toast", kcal: 120)
            ])
        )
        var menus = try await repository.listMenus(userID: userID)
        XCTAssertEqual(menus.first?.items.count, 2)

        try await repository.deleteMenu(userID: userID, menuID: created.menuID)
        menus = try await repository.listMenus(userID: userID)
        XCTAssertTrue(menus.isEmpty)
    }

    // MARK: - Logging a menu (snapshot semantics)

    func testLogFromMenuStampsSharedGroupAndNameCopy() async throws {
        let menu = NamedMenu(menuID: UUID(), name: "Eggs on toast", items: [
            templateItem("toast", kcal: 120),
            templateItem("eggs", kcal: 90)
        ])
        let repository = makeRepository(menus: [menu])

        let groupID = UUID()
        let draft = MealDraft(
            mealType: .breakfast,
            eatenAt: Date(timeIntervalSince1970: 100),
            notes: nil,
            items: menu.items.map { $0.draft(menuGroupID: groupID, menuName: menu.name) }
        )
        _ = try await repository.logMeal(userID: userID, draft: draft, photo: nil)

        let today = try await repository.loadToday(userID: userID, date: draft.eatenAt)
        let items = try XCTUnwrap(today.meals.first?.items)
        XCTAssertEqual(items.count, 2)
        for item in items {
            XCTAssertEqual(item.menuName, "Eggs on toast")
            XCTAssertEqual(item.menuGroupID, groupID)
        }
        let rows = MealDisplayGrouping.rows(from: items)
        XCTAssertEqual(rows.count, 1)
        guard case let .set(name, _, members) = rows[0] else {
            return XCTFail("Expected the logged menu to render as one set")
        }
        XCTAssertEqual(name, "Eggs on toast")
        XCTAssertEqual(members.count, 2)
    }

    func testMenuEditAfterLogNeverRewritesThePastMeal() async throws {
        let menu = NamedMenu(menuID: UUID(), name: "Breakfast set", items: [
            templateItem("toast", kcal: 120)
        ])
        let repository = makeRepository(menus: [menu])

        let groupID = UUID()
        let draft = MealDraft(
            mealType: .breakfast,
            eatenAt: Date(timeIntervalSince1970: 100),
            notes: nil,
            items: menu.items.map { $0.draft(menuGroupID: groupID, menuName: menu.name) }
        )
        _ = try await repository.logMeal(userID: userID, draft: draft, photo: nil)

        // Rename the template AND swap its items — the logged snapshot must
        // keep the original name copy, item count and group stamp.
        try await repository.updateMenu(
            userID: userID,
            menuID: menu.menuID,
            editor: MenuEditorDraft(name: "Breakfast set v2", items: [
                templateItem("toast", kcal: 120),
                templateItem("eggs", kcal: 90),
                templateItem("sauce", kcal: 15)
            ])
        )

        let today = try await repository.loadToday(userID: userID, date: draft.eatenAt)
        let items = try XCTUnwrap(today.meals.first?.items)
        XCTAssertEqual(items.map(\.name), ["toast"])
        XCTAssertEqual(items.first?.menuName, "Breakfast set")
        XCTAssertEqual(items.first?.menuGroupID, groupID)
    }

    func testEditingASetMemberKeepsItsGrouping() async throws {
        let repository = makeRepository()
        let groupID = UUID()
        let draft = MealDraft(
            mealType: .dinner,
            eatenAt: Date(timeIntervalSince1970: 100),
            notes: nil,
            items: [
                MenuTemplateItem(name: "rice", quantity: 1, unit: .serving, caloriesKcal: 200)
                    .draft(menuGroupID: groupID, menuName: "Rice bowl")
            ]
        )
        let mealID = try await repository.logMeal(userID: userID, draft: draft, photo: nil)
        _ = mealID

        let today = try await repository.loadToday(userID: userID, date: draft.eatenAt)
        let meal = try XCTUnwrap(today.meals.first)
        let item = try XCTUnwrap(meal.items.first)
        try await repository.updateMealItem(
            userID: userID,
            update: MealItemUpdate(itemID: item.itemID, name: "brown rice")
        )

        let after = try await repository.loadToday(userID: userID, date: draft.eatenAt)
        let edited = try XCTUnwrap(after.meals.first?.items.first)
        XCTAssertEqual(edited.name, "brown rice")
        XCTAssertEqual(edited.menuName, "Rice bowl", "An item edit must not detach the item from its logged set")
        XCTAssertEqual(edited.menuGroupID, groupID)
        XCTAssertEqual(MealDisplayGrouping.rows(from: after.meals.first?.items ?? []).count, 1)
    }

    // MARK: - Display grouping

    func testGroupingKeepsLooseItemsFlatBetweenSets() {
        let groupA = UUID()
        let groupB = UUID()
        let looseBetween = MealItem(
            itemID: UUID(), name: "coffee", quantity: 1, unit: .cup, caloriesKcal: 5,
            proteinG: nil, carbsG: nil, fatG: nil, fiberG: nil, sugarG: nil,
            confidence: 1, notes: nil
        )
        let trailingLoose = MealItem(
            itemID: UUID(), name: "water", quantity: 1, unit: .cup, caloriesKcal: 0,
            proteinG: nil, carbsG: nil, fatG: nil, fiberG: nil, sugarG: nil,
            confidence: 1, notes: nil
        )
        let items = [
            MealItem(
                itemID: UUID(), name: "toast", quantity: 1, unit: .piece, caloriesKcal: 120,
                proteinG: nil, carbsG: nil, fatG: nil, fiberG: nil, sugarG: nil,
                confidence: 1, notes: nil, menuGroupID: groupA, menuName: "Set one"
            ),
            MealItem(
                itemID: UUID(), name: "eggs", quantity: 2, unit: .piece, caloriesKcal: 180,
                proteinG: nil, carbsG: nil, fatG: nil, fiberG: nil, sugarG: nil,
                confidence: 1, notes: nil, menuGroupID: groupA, menuName: "Set one"
            ),
            looseBetween,
            MealItem(
                itemID: UUID(), name: "salad", quantity: 1, unit: .serving, caloriesKcal: 60,
                proteinG: nil, carbsG: nil, fatG: nil, fiberG: nil, sugarG: nil,
                confidence: 1, notes: nil, menuGroupID: groupB, menuName: "Side salad"
            ),
            trailingLoose
        ]

        let rows = MealDisplayGrouping.rows(from: items)

        XCTAssertEqual(rows.count, 4)
        guard case let .set(name, _, members) = rows[0] else {
            return XCTFail("First row must be the set")
        }
        XCTAssertEqual(name, "Set one")
        XCTAssertEqual(members.count, 2)
        guard case .loose(looseBetween) = rows[1] else {
            return XCTFail("Coffee must stay a flat loose row between the sets")
        }
        guard case let .set(nameB, _, _) = rows[2] else {
            return XCTFail("Third row must be the second set")
        }
        XCTAssertEqual(nameB, "Side salad")
        guard case .loose = rows[3] else {
            return XCTFail("Trailing loose items must stay flat")
        }
    }

    func testRowsFromUntaggedItemsAreAllLoose() {
        let items = [
            MealItem(
                itemID: UUID(), name: "oats", quantity: 1, unit: .serving, caloriesKcal: 220,
                proteinG: nil, carbsG: nil, fatG: nil, fiberG: nil, sugarG: nil,
                confidence: 1, notes: nil
            ),
            MealItem(
                itemID: UUID(), name: "milk", quantity: 1, unit: .cup, caloriesKcal: 90,
                proteinG: nil, carbsG: nil, fatG: nil, fiberG: nil, sugarG: nil,
                confidence: 1, notes: nil
            )
        ]

        let rows = MealDisplayGrouping.rows(from: items)

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { row in
            if case .loose = row { return true }
            return false
        })
    }

    func testSetLabelShowsNameWithSetSuffix() {
        XCTAssertEqual(MealDisplayGrouping.setLabel(name: "Eggs on toast"), "Eggs on toast (set)")
    }

    // MARK: - Editor draft validation

    func testMenuEditorDraftValidation() {
        let item = templateItem("eggs", kcal: 90)
        XCTAssertTrue(MenuEditorDraft(name: "Brunch", items: [item]).isValid)
        XCTAssertFalse(MenuEditorDraft(name: "   ", items: [item]).isValid)
        XCTAssertFalse(MenuEditorDraft(name: "Brunch", items: []).isValid)
        XCTAssertEqual(MenuEditorDraft(name: "  Brunch  ", items: [item]).trimmedName, "Brunch")
    }

    func testMenuSummaryLine() {
        let menu = NamedMenu(menuID: UUID(), name: "Brunch", items: [
            templateItem("eggs", kcal: 90),
            templateItem("toast", kcal: 120)
        ])
        XCTAssertEqual(menu.summaryLine, "2 items · 210 kcal")
    }
}

import XCTest
import Supabase
@testable import Morsel

// Issue #194 — the dense-read ACs. Every case drives the PRODUCTION read
// methods through the capped transport (a deployment whose `db-max-rows` is
// small): a read that does not page sees a silent prefix of the collection, so
// these assertions are the completeness the fix owes the user — meals, items,
// weight samples and menus, all of them, across multiple pages.

final class BoundedPagingTests: CappedPagingTestCase {
    override func setUp() {
        super.setUp()
        CappedReadTransport.reset(.dense(meals: 7, itemsPerMeal: 2, weights: 7), cap: 3)
    }

    override func tearDown() {
        CappedReadTransport.release()
        CappedReadTransport.reset(CappedFixture(), cap: 3)
        super.tearDown()
    }

    /// AC1 — a capped server still yields the complete, deduplicated day.
    func testCappedServerReturnsEveryMealAndItemAcrossPages() async throws {
        let repository = try await repository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)

        XCTAssertEqual(snapshot.meals.count, 7, "every meal the capped server holds must be delivered")
        XCTAssertEqual(Set(snapshot.meals.map(\.mealLogID)).count, 7, "no meal is delivered twice")
        for meal in snapshot.meals {
            XCTAssertEqual(meal.items.count, 2, "every item of \(meal.mealLogID) must be delivered")
        }
        let dayCalories = snapshot.meals.flatMap(\.items).reduce(0) { $0 + ($1.caloriesKcal ?? 0) }
        XCTAssertEqual(dayCalories, 7 * 210, accuracy: 0.001, "the assembled day is not a partial prefix")
        XCTAssertGreaterThan(CappedReadTransport.records("meal_logs").count, 1, "the read really paged")
        XCTAssertGreaterThan(CappedReadTransport.records("meal_items").count, 1, "the items read really paged")

        // The uncapped reference: the same fixture with the cap out of the way.
        CappedReadTransport.reset(.dense(meals: 7, itemsPerMeal: 2, weights: 7), cap: 500)
        let uncapped = try await repository.loadToday(userID: account, date: referenceInstant)
        XCTAssertEqual(snapshot.meals.map(\.mealLogID), uncapped.meals.map(\.mealLogID))
        XCTAssertEqual(snapshot.meals.map { $0.items.map(\.itemID) }, uncapped.meals.map { $0.items.map(\.itemID) })
        XCTAssertEqual(snapshot.weightTrend, uncapped.weightTrend)
        XCTAssertEqual(CappedReadTransport.records("meal_logs").count, 2,
                       "one page plus the confirmation request that proves the collection ended")
    }

    /// AC1 — the trend window's samples survive a cap too.
    func testCappedServerReturnsEveryWeightSampleAcrossPages() async throws {
        let repository = try await repository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)

        XCTAssertEqual(snapshot.weightTrend.count, 7, "every sample in the trend window must be delivered")
        XCTAssertEqual(snapshot.weightTrend.map(\.kilograms), (1...7).map { 80 + Double($0) / 10 })
        XCTAssertGreaterThan(CappedReadTransport.records("weight_logs").count, 1, "the trend read really paged")
    }

    /// AC1 — menus and their items survive a cap.
    func testCappedServerReturnsEveryMenuAndItemAcrossPages() async throws {
        CappedReadTransport.reset(.dense(meals: 0, itemsPerMeal: 0, menus: 5, itemsPerMenu: 3), cap: 2)
        let repository = try await repository()
        let menus = try await repository.listMenus(userID: account)

        XCTAssertEqual(menus.map(\.name), ["Menu 01", "Menu 02", "Menu 03", "Menu 04", "Menu 05"])
        for menu in menus {
            XCTAssertEqual(menu.items.count, 3, "every item of \(menu.name) must be delivered")
        }
        XCTAssertEqual(Set(menus.map(\.menuID)).count, 5, "no menu is delivered twice")
        XCTAssertGreaterThan(CappedReadTransport.records("meal_menus").count, 1, "the menu read really paged")
        XCTAssertGreaterThan(CappedReadTransport.records("menu_items").count, 1, "the item read really paged")
    }

    /// AC1/AC3 — the History ledger's totals and grouping match the uncapped
    /// reference: nothing is dropped and nothing is counted twice.
    func testHistoryTotalsMatchTheUncappedReferenceAcrossPages() async throws {
        let fixture = CappedFixture.dense(meals: 6, itemsPerMeal: 3)
        CappedReadTransport.reset(fixture, cap: 2)
        let repository = try await repository()
        let capped = try await repository.loadHistory(userID: account, end: referenceInstant, days: 7)

        CappedReadTransport.reset(fixture, cap: 500)
        let uncapped = try await repository.loadHistory(userID: account, end: referenceInstant, days: 7)

        XCTAssertEqual(capped.days.map(\.date), uncapped.days.map(\.date))
        XCTAssertEqual(capped.days.map(\.logged), uncapped.days.map(\.logged))
        XCTAssertEqual(capped.days.map(\.eatenKcal), uncapped.days.map(\.eatenKcal))
        XCTAssertEqual(capped.days.reduce(0) { $0 + $1.eatenKcal }, 6 * 330, accuracy: 0.001)
    }

    /// AC2 — a long id list goes out in documented chunks, complete and disjoint.
    func testLargeMealIDListsGoOutInBoundedChunks() async throws {
        CappedReadTransport.reset(.dense(meals: 120, itemsPerMeal: 1), cap: 500)
        let repository = try await repository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)

        XCTAssertEqual(snapshot.meals.count, 120)
        XCTAssertEqual(snapshot.meals.flatMap(\.items).count, 120)
        var chunks: [[String]] = []
        for chunk in CappedReadTransport.records("meal_items").map(\.ids) where chunks.last != chunk {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks.map(\.count), [50, 50, 20], "ids go out in chunks of \(BoundedRead.idChunkSize)")
        XCTAssertEqual(Set(chunks.flatMap { $0 }).count, 120, "no meal id is requested twice")
        XCTAssertEqual(Set(chunks.flatMap { $0 }), Set(snapshot.meals.map { $0.mealLogID.uuidString.lowercased() }),
                       "every meal id is requested exactly once across the chunks")
        XCTAssertEqual(CappedReadTransport.records("meal_items").count, 6,
                       "each chunk costs its page plus the confirmation request")
    }

    /// AC2 — every paged request carries a total order: the natural key plus a
    /// tie-breaking identity.
    func testPageRequestsCarryStableOrderingAndTieBreakers() async throws {
        CappedReadTransport.reset(.dense(meals: 3, itemsPerMeal: 1, weights: 2, menus: 2, itemsPerMenu: 1), cap: 1)
        let repository = try await repository()
        _ = try await repository.loadToday(userID: account, date: referenceInstant)
        _ = try await repository.loadHistory(userID: account, end: referenceInstant, days: 7)
        _ = try await repository.listMenus(userID: account)

        XCTAssertEqual(orders("meal_logs"), ["eaten_at.asc.nullslast,id.asc.nullslast"])
        XCTAssertEqual(orders("meal_items"), ["created_at.asc.nullslast,id.asc.nullslast"])
        XCTAssertEqual(orders("weight_logs"), ["measured_at.asc.nullslast,kg.asc.nullslast"])
        XCTAssertEqual(orders("meal_menus"), ["name.asc.nullslast,id.asc.nullslast"])
        XCTAssertEqual(orders("menu_items"), ["menu_id.asc.nullslast,id.asc.nullslast"])
    }

    /// AC4 — the account/date scope applies to every page and every chunk; a
    /// chunk's ids are all inside the account's own day window.
    func testEveryPageAndChunkCarriesTheAccountAndWindowScope() async throws {
        CappedReadTransport.reset(.dense(meals: 120, itemsPerMeal: 1, weights: 4), cap: 50)
        let repository = try await repository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)

        let dayMealIDs = Set(snapshot.meals.map { $0.mealLogID.uuidString.lowercased() })
        let logPages = CappedReadTransport.records("meal_logs")
        XCTAssertGreaterThan(logPages.count, 1)
        for page in logPages {
            XCTAssertEqual(query(page, "user_id"), "eq.\(account.uuidString)")
            XCTAssertNotNil(query(page, "eaten_at"), "every page keeps the day window")
        }
        let chunks = CappedReadTransport.records("meal_items")
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertFalse(chunk.ids.isEmpty, "a chunk is never empty")
            XCTAssertTrue(Set(chunk.ids).isSubset(of: dayMealIDs), "every chunk stays inside the day's meals")
        }
        for page in CappedReadTransport.records("weight_logs") {
            XCTAssertEqual(query(page, "user_id"), "eq.\(account.uuidString)")
            XCTAssertNotNil(query(page, "measured_at"), "every page keeps the trend window")
        }
    }

    /// AC4 — dense paging must not fan out: pages and chunks of one read are
    /// sequential, and the read graph's declared ceiling still holds.
    func testChunkAndPageFanoutStaysBounded() async throws {
        CappedReadTransport.reset(.dense(meals: 120, itemsPerMeal: 1), cap: 5)
        let repository = try await repository()
        _ = try await repository.loadToday(userID: account, date: referenceInstant)

        let settled = CappedReadTransport.snapshot()
        XCTAssertEqual(settled.peak("meal_logs"), 1, "one read's pages are fetched one at a time")
        XCTAssertEqual(settled.peak("meal_items"), 1, "one read's chunks are fetched one at a time")
        XCTAssertGreaterThan(settled.count(.started, "meal_items"), 1, "the fixture really is chunked")
        XCTAssertLessThanOrEqual(settled.peakInFlight, ReadGraph.maxInFlightRequests,
                                 "the read graph's declared ceiling still holds")
    }

    private func orders(_ table: String) -> [String] {
        Array(Set(CappedReadTransport.records(table).compactMap(\.order))).sorted()
    }

    private func query(_ record: CappedReadTransport.Recorded, _ name: String) -> String? {
        URLComponents(string: record.url)?.queryItems?.first { $0.name == name }?.value
    }
}

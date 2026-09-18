import XCTest
import Supabase
@testable import Morsel

// Issue #194 — the failure, cancellation and boundary halves of the ACs: a
// failed page must never be cached or published as a partial snapshot, a
// cancelled read must stop requesting pages, and page boundaries must not lose
// or double count rows (equal timestamps, a repeated boundary row, an exactly
// full collection whose last page is empty).

final class BoundedPagingBoundaryTests: CappedPagingTestCase {
    override func setUp() {
        super.setUp()
        CappedReadTransport.reset(.dense(meals: 7, itemsPerMeal: 2), cap: 3)
    }

    override func tearDown() {
        CappedReadTransport.release()
        CappedReadTransport.reset(CappedFixture(), cap: 3)
        super.tearDown()
    }

    /// AC3 — an intermediate page failure fails the read instead of returning
    /// the pages that already arrived.
    func testAnIntermediatePageFailureFailsTheRead() async throws {
        CappedReadTransport.plan("meal_logs", failFrom: 3)
        let repository = try await repository()

        await assertThrows("a failed page must not be reported as a successful read") {
            _ = try await repository.loadToday(userID: self.account, date: self.referenceInstant)
        }
        XCTAssertEqual(CappedReadTransport.records("meal_logs").count, 2, "page 1 succeeded, page 2 failed")
        XCTAssertEqual(CappedReadTransport.records("meal_items").count, 0, "no item read follows a failed log read")
    }

    /// AC3 — the local-first facade publishes the CACHED complete snapshot, and
    /// the cache keeps it byte-for-byte: no silent partial snapshot.
    func testAFailedPageNeverReplacesTheCachedSnapshot() async throws {
        CappedReadTransport.reset(.dense(meals: 7, itemsPerMeal: 2), cap: 3)
        let client = try client()
        _ = try await client.auth.session
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("morsel-194-\(UUID().uuidString).sqlite")
        let facade = LocalFirstDashboardRepository(
            remote: SupabaseDashboardRepository(client: client),
            store: try LocalDataStore(databaseURL: databaseURL),
            snapshotCache: try LocalSnapshotCache(databaseURL: databaseURL)
        )
        let dayKey = LocalFirstDashboardRepository.dayKey(referenceInstant)

        let fresh = try await facade.loadToday(userID: account, date: referenceInstant)
        XCTAssertEqual(fresh.meals.count, 7, "the first read is complete")
        XCTAssertEqual(fresh.readProvenance?.isCached, false)
        let cachedComplete = try XCTUnwrap(try facade.snapshotCache.loadDashboardCache(dayKey: dayKey))

        CappedReadTransport.plan("meal_logs", failFrom: 3)
        let degraded = try await facade.loadToday(userID: account, date: referenceInstant)
        XCTAssertEqual(degraded.meals.count, 7, "the complete cached day is what the user sees")
        XCTAssertEqual(degraded.readProvenance?.isCached, true)
        XCTAssertEqual(try facade.snapshotCache.loadDashboardCache(dayKey: dayKey), cachedComplete,
                       "a failed page must not overwrite the complete cached snapshot")
    }

    /// AC4 — cancellation stops further pages and drains every request.
    func testCancellationStopsFurtherPages() async throws {
        CappedReadTransport.reset(.dense(meals: 9, itemsPerMeal: 1), cap: 3)
        CappedReadTransport.plan("meal_logs", holdFrom: 3)
        let repository = try await repository()
        let load = Task { try await repository.loadToday(userID: account, date: referenceInstant) }
        let parked = await waitUntil { CappedReadTransport.snapshot().count(.started, "meal_logs") == 2 }
        XCTAssertTrue(parked, "page 2 is requested and parked before the caller cancels")

        load.cancel()
        await assertThrows("a cancelled read must not report success") { _ = try await load.value }
        let drained = await waitUntil { CappedReadTransport.snapshot().inFlight == 0 }
        XCTAssertTrue(drained, "every in-flight request terminates when the read is cancelled")
        let settled = CappedReadTransport.snapshot()
        XCTAssertEqual(settled.count(.started, "meal_logs"), 2, "no page is requested after cancellation")
        XCTAssertEqual(settled.count(.cancelled, "meal_logs"), 1)
    }

    /// AC5 — rows that share an ordering key still split across pages without
    /// loss: the id tie-break makes the order total.
    func testEqualTimestampsSplitAcrossPagesStayCompleteAndUnique() async throws {
        CappedReadTransport.reset(.dense(meals: 5, itemsPerMeal: 1), cap: 2)
        let repository = try await repository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)

        XCTAssertEqual(snapshot.meals.map { $0.mealLogID.uuidString.lowercased() }, (1...5).map(CappedFixture.mealID),
                       "equal timestamps keep the id tie-break order across page boundaries")
        XCTAssertEqual(CappedReadTransport.records("meal_logs").count, 4,
                       "two full pages, one short page and the empty confirmation page")
    }

    /// AC5 — a boundary row the server delivers twice (the row an update moved
    /// later in the order) is deduplicated and never double counted.
    func testBoundaryDuplicateIsDeduplicatedAndNotDoubleCounted() async throws {
        CappedReadTransport.reset(.dense(meals: 5, itemsPerMeal: 1), cap: 2)
        CappedReadTransport.plan("meal_logs", overlap: 1)
        let repository = try await repository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)

        XCTAssertEqual(snapshot.meals.count, 5, "a repeated boundary row is delivered once")
        XCTAssertEqual(Set(snapshot.meals.map(\.mealLogID)).count, 5)
        let dayCalories = snapshot.meals.flatMap(\.items).reduce(0) { $0 + ($1.caloriesKcal ?? 0) }
        XCTAssertEqual(dayCalories, 5 * 100, accuracy: 0.001, "totals must not double count")
        let delivered = CappedReadTransport.records("meal_logs").flatMap(\.delivered)
        XCTAssertGreaterThan(delivered.count, Set(delivered).count, "the server really did repeat a row")
    }

    /// AC5 — a collection whose size is an exact multiple of the page size ends
    /// on an explicit empty page, with nothing lost or repeated.
    func testEmptyLastPageTerminatesAnExactlyFullCollection() async throws {
        CappedReadTransport.reset(.dense(meals: 6, itemsPerMeal: 1), cap: 3)
        let repository = try await repository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)

        XCTAssertEqual(snapshot.meals.count, 6)
        let pages = CappedReadTransport.records("meal_logs")
        XCTAssertEqual(pages.map(\.delivered.count), [3, 3, 0], "two full pages, then the empty last page")
        XCTAssertEqual(Set(pages.flatMap(\.delivered)).count, 6)
    }

    /// AC5 — the ledger's narrow projection deliberately carries no key: two
    /// genuinely distinct items that share a calorie value must both count.
    func testLedgerKeepsDistinctRowsThatShareTheirValues() async throws {
        var fixture = CappedFixture.dense(meals: 1, itemsPerMeal: 0)
        fixture.items = [CappedFixture.item(1, meal: 1, kcal: 100), CappedFixture.item(2, meal: 1, kcal: 100)]
        CappedReadTransport.reset(fixture, cap: 1)
        let repository = try await repository()
        let overview = try await repository.loadHistory(userID: account, end: referenceInstant, days: 7)

        XCTAssertEqual(overview.days.reduce(0) { $0 + $1.eatenKcal }, 200, accuracy: 0.001,
                       "identical calorie values on distinct rows must not collapse")
        XCTAssertEqual(CappedReadTransport.records("meal_items").map(\.delivered.count), [1, 1, 0],
                       "one row per page, then the empty last page")
    }

    /// AC5 — the documented bounds and the consistency behaviour while paging
    /// are pinned to the source that implements them.
    func testDocumentedBoundsAndConsistencyBehaviourArePinned() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Morsel/BoundedReadPaging.swift"), encoding: .utf8
        )
        XCTAssertTrue(source.contains("static let pageSize = 200"))
        XCTAssertTrue(source.contains("static let idChunkSize = 50"))
        XCTAssertTrue(source.contains("static let maxConcurrentChunks = 1"))
        XCTAssertLessThanOrEqual(BoundedRead.pageSize, 1000, "the page size stays inside PostgREST's default max-rows")
        for phrase in ["Content-Range", "concurrent INSERT", "keeps the first copy", "No index is added",
                       "no partial snapshot"] {
            XCTAssertTrue(source.contains(phrase), "the read contract must document: \(phrase)")
        }
    }

    private func assertThrows(_ message: String, _ operation: () async throws -> some Sendable) async {
        do {
            _ = try await operation()
            XCTFail(message)
        } catch {
            // expected: the read fails loudly, never a silent partial success
        }
    }
}

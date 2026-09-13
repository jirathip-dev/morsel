import XCTest
import Supabase
@testable import Morsel

// Issue #178 — bounded structured concurrency for the repository read graph.
// These tests drive the PRODUCTION Today/History/goals-context methods through
// their real Supabase request seams: the StubTransport controlled transport
// parks chosen requests, so overlap, dependency order, in-flight counts and
// termination are asserted from real request events (start/finish/cancel),
// never from sleeps or wall-clock guesses. The one measured duration is a
// labelled fixture measurement, not a production speed claim.

final class ParallelReadsTests: XCTestCase {
    private let account = UUID()
    /// 2026-09-05 11:00 +07 (the repo's local-day fixture instant).
    private let referenceInstant = ISO8601DateFormatter().date(from: "2026-09-05T04:00:00Z") ?? Date()

    override func setUp() {
        super.setUp()
        StubTransport.reset()
    }

    override func tearDown() {
        StubTransport.release()
        StubTransport.reset()
        super.tearDown()
    }

    /// The controlled transport parks EVERY Today request, so the read graph
    /// only reaches inFlight == 5 by overlapping four independent reads around
    /// the logs→items chain (the sequential mechanism stops at 1).
    func testTodayOverlapsTheIndependentReadsAndKeepsTheLogsItemsChain() async throws {
        StubTransport.reset(holding: StubTransport.readPaths)
        let load = Task { try await makeRepository().loadToday(userID: account, date: referenceInstant) }
        let fiveInFlight = await waitUntil { StubTransport.snapshot().inFlight == 5 }
        XCTAssertTrue(fiveInFlight, "four independent reads + the logs chain request must be in flight")

        let held = StubTransport.snapshot()
        XCTAssertEqual(held.peakInFlight, ReadGraph.maxInFlightRequests, "the declared ceiling is the real ceiling")
        XCTAssertEqual(held.count(.started, "meal_items"), 0, "items must wait for the logs response")
        XCTAssertGreaterThanOrEqual(held.peakInFlight, 2, "independent reads really overlap")

        StubTransport.release("meal_logs")
        let itemsFollowed = await waitUntil { StubTransport.snapshot().count(.started, "meal_items") == 1 }
        XCTAssertTrue(itemsFollowed, "items start once logs answers, while the other reads are still held")
        let settled = StubTransport.snapshot()
        let logsFinished = try XCTUnwrap(settled.sequence(.finished, "meal_logs"))
        let itemsStart = try XCTUnwrap(settled.sequence(.started, "meal_items"))
        XCTAssertLessThan(logsFinished, itemsStart, "logs→items ordering stays valid")

        StubTransport.release()
        let snapshot = try await load.value
        XCTAssertEqual(snapshot.meals.count, 1)
        XCTAssertEqual(StubTransport.snapshot().inFlight, 0, "no request outlives the read")
    }

    func testHistoryAndGoalsContextOverlapAndKeepBaselineValues() async throws {
        StubTransport.reset(holding: ["goals", "profiles", "weight_logs"])
        let history = Task {
            try await makeRepository().loadHistory(userID: account, end: referenceInstant, days: 7)
        }
        let threeInFlight = await waitUntil { StubTransport.snapshot().inFlight == 3 }
        XCTAssertTrue(threeInFlight, "History's profile and weight reads overlap its held goals read")
        StubTransport.release()
        let overview = try await history.value
        XCTAssertEqual(overview.days.count, 7)
        XCTAssertEqual(overview.days.first(where: \.logged)?.eatenKcal, 300)
        XCTAssertEqual(overview.goal?.calorieTargetKcal, 2000)

        StubTransport.reset(holding: ["goals", "profiles", "weight_logs"])
        let context = Task { try await makeRepository().loadGoalsContext(userID: account) }
        let threeRows = await waitUntil { StubTransport.snapshot().inFlight == 3 }
        XCTAssertTrue(threeRows, "the goals context's three independent rows overlap")
        StubTransport.release()
        let goalsContext = try await context.value
        XCTAssertEqual(goalsContext.stored?.calorieTargetKcal, 2000)
        XCTAssertEqual(goalsContext.profile?.weightKg, 81.5)
        XCTAssertEqual(goalsContext.latestWeight?.kilograms, 81.4)
        XCTAssertEqual(StubTransport.snapshot().inFlight, 0)
    }

    func testTodaySnapshotMatchesTheSequentialBaselineValues() async throws {
        let repository = try await makeRepository()
        let snapshot = try await repository.loadToday(userID: account, date: referenceInstant)

        XCTAssertEqual(snapshot.date, Calendar.autoupdatingCurrent.startOfDay(for: referenceInstant))
        XCTAssertEqual(snapshot.goal, DashboardGoal(
            calorieTargetKcal: 2000, proteinG: 150, carbsG: 200, fatG: 60, source: .manual
        ))
        XCTAssertEqual(snapshot.activeEnergyBurned, 320)
        XCTAssertEqual(snapshot.weightTrend.map(\.kilograms), [81.2], "whole-second dedupe keeps the later sample")
        let meal = try XCTUnwrap(snapshot.meals.first)
        XCTAssertEqual(meal.mealType, .lunch)
        XCTAssertEqual(meal.items.first?.name, "jasmine rice")
        XCTAssertEqual(meal.items.first?.caloriesKcal, 300)

        // Stale manual row (older write) + profile → the computed path wins
        // (issue #113), with the newest synced weight as weight_used.
        StubTransport.respond("goals", .init(body: """
        [{"calorie_target_kcal": 2000, "protein_g": 150, "carbs_g": 200, "fat_g": 60, \
        "source": "manual", "updated_at": "2026-09-04T00:00:00.000Z"}]
        """))
        let computed = try await repository.loadToday(userID: account, date: referenceInstant)
        XCTAssertEqual(computed.goal, DashboardGoal(
            calorieTargetKcal: 2727, proteinG: 205, carbsG: 307, fatG: 76, source: .computed
        ))
    }

    func testEmptyDayAndAuthExpiryTerminateWithNoOrphanTasks() async throws {
        for table in StubTransport.readPaths {
            StubTransport.respond(table, .init(body: "[]"))
        }
        let snapshot = try await makeRepository().loadToday(userID: account, date: referenceInstant)
        XCTAssertTrue(snapshot.meals.isEmpty)
        XCTAssertNil(snapshot.goal)
        var settled = StubTransport.snapshot()
        XCTAssertEqual(settled.count(.started, "meal_logs"), 1)
        XCTAssertEqual(settled.count(.started, "meal_items"), 0, "an empty day issues no item read")
        XCTAssertEqual(settled.inFlight, 0)

        StubTransport.reset()
        StubTransport.respond("token", .init(
            status: 401, body: "{\"error\":\"invalid_grant\",\"error_description\":\"expired\"}"
        ))
        await assertThrows("an expired, unrefreshable session fails the read") {
            try await self.makeRepository(expiresAt: Date().addingTimeInterval(-60))
                .loadToday(userID: self.account, date: self.referenceInstant)
        }
        settled = StubTransport.snapshot()
        XCTAssertEqual(settled.count(.started, "/rest/v1", prefix: true), 0, "no table read may be issued")
        XCTAssertEqual(settled.inFlight, 0)
    }

    func testPartialFailureAndCancellationLeaveNoOrphanTasks() async throws {
        StubTransport.reset(holding: ["energy_burned_logs"])
        StubTransport.respond("weight_logs", .init(
            status: 500, body: "{\"message\":\"upstream refused\",\"code\":\"XX000\"}"
        ))
        await assertThrows("a failed independent read fails the whole Today read") {
            try await self.makeRepository().loadToday(userID: self.account, date: self.referenceInstant)
        }
        let orphanFree = await waitUntil { StubTransport.snapshot().inFlight == 0 }
        XCTAssertTrue(orphanFree, "the held sibling reads are cancelled, not orphaned")

        StubTransport.reset(holding: StubTransport.readPaths)
        let load = Task { try await makeRepository().loadToday(userID: account, date: referenceInstant) }
        let fiveHeld = await waitUntil { StubTransport.snapshot().inFlight == 5 }
        XCTAssertTrue(fiveHeld, "five requests are in flight before the caller cancels")
        load.cancel()
        await assertThrows("a cancelled read must not report success") { _ = try await load.value }
        let drained = await waitUntil { StubTransport.snapshot().inFlight == 0 }
        XCTAssertTrue(drained, "every in-flight request terminates when the read is cancelled")
        let settled = StubTransport.snapshot()
        XCTAssertEqual(settled.count(.cancelled, "meal_logs"), 1)
        XCTAssertEqual(settled.count(.started, "meal_items"), 0)
    }

    func testTodayWindowFollowsTheDeviceZoneAcrossTheSpringForwardDay() async throws {
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York") ?? previousZone
        defer { NSTimeZone.default = previousZone }
        XCTAssertEqual(
            Calendar.autoupdatingCurrent.timeZone.identifier, "America/New_York",
            "the process zone override must drive the device calendar for this test to mean anything"
        )
        var zone = Calendar(identifier: .gregorian)
        zone.timeZone = TimeZone(identifier: "America/New_York") ?? previousZone
        // 2026-03-08 is the US spring-forward day: this local day is 23 hours.
        let instant = ISO8601DateFormatter().date(from: "2026-03-08T17:00:00Z") ?? Date()
        let expectedStart = zone.startOfDay(for: instant)
        let expectedEnd = zone.date(byAdding: .day, value: 1, to: expectedStart) ?? expectedStart
        let expectedTrendStart = zone.date(byAdding: .day, value: -29, to: expectedStart) ?? expectedStart

        let snapshot = try await makeRepository().loadToday(userID: account, date: instant)
        XCTAssertEqual(snapshot.date, expectedStart)
        let settled = StubTransport.snapshot()
        let mealBounds = settled.queryValues("meal_logs", "eaten_at")
        XCTAssertTrue(mealBounds.contains("gte.\(MorselDate.iso8601(expectedStart))"),
                      "the local day start is the lower bound: \(mealBounds)")
        XCTAssertTrue(mealBounds.contains("lt.\(MorselDate.iso8601(expectedEnd))"),
                      "the next local day start is the exclusive upper bound: \(mealBounds)")
        XCTAssertTrue(
            settled.queryValues("weight_logs", "measured_at")
                .contains("gte.\(MorselDate.iso8601(expectedTrendStart))"),
            "the 29-day trend window keeps the local day grid"
        )
    }

    func testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts() async throws {
        let delay: TimeInterval = 0.2
        StubTransport.reset(delay: delay)
        let started = Date()
        let snapshot = try await makeRepository().loadToday(userID: account, date: referenceInstant)
        let elapsed = Date().timeIntervalSince(started)
        let settled = StubTransport.snapshot()
        let reads = settled.count(.started, "/rest/v1", prefix: true)
        print("issue178-fixture reads=\(reads) peakInFlight=\(settled.peakInFlight) elapsed=\(elapsed)")
        XCTAssertEqual(reads, 6, "goals, profiles, weight, energy, logs, items")
        XCTAssertEqual(snapshot.meals.count, 1)
        // Fixture arithmetic: six reads at 200 ms are ≥ 1.2 s one-by-one; the
        // concurrent graph is bounded by its 2-deep logs→items chain.
        XCTAssertLessThan(elapsed, 3 * delay, "the reads must not run one after another")
    }

    private func assertThrows(_ message: String, _ operation: () async throws -> some Sendable) async {
        do {
            _ = try await operation()
            XCTFail(message)
        } catch {
            // expected: the read fails loudly, never a silent success
        }
    }

    private func makeRepository(expiresAt: Date = Date().addingTimeInterval(3600)) async throws
        -> SupabaseDashboardRepository {
        guard let baseURL = URL(string: "https://stub.supabase.test") else {
            preconditionFailure("stub base URL must be valid")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        configuration.urlCache = nil
        let client = SupabaseClient(
            supabaseURL: baseURL, supabaseKey: "stub-anon-key",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: StubSessionStorage(userID: account, expiresAt: expiresAt),
                    storageKey: "sb-stub-auth-token", autoRefreshToken: false
                ),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
        // Exercise the real session seam before the read (auth-expiry lands here).
        _ = try await client.auth.session
        return SupabaseDashboardRepository(client: client)
    }

    /// Bounded wait for a REAL request event: no ordering claim rests on it,
    /// it only keeps a stuck read from hanging the suite.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}

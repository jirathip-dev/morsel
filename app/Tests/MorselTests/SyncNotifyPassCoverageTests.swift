import XCTest
@testable import Morsel

// Issue #189 — construction/start order and the SQLite-backed pass matrix.
// The engine is built exactly as `AccountReliabilityServices` builds it over
// one account file, and every expectation is about the pass's REAL effects on
// the outbox, the Health store and the model that renders them.
@MainActor
final class SyncNotifyPassCoverageTests: XCTestCase {
    private let stores = SyncNotifyStores()
    private let reference = Date(timeIntervalSince1970: 1_788_566_400)

    private var day: Date { DashboardMath.startOfLocalDay(reference) }
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3_600) }

    override func setUpWithError() throws { try stores.createRoot() }
    override func tearDownWithError() throws { stores.removeRoot() }

    // MARK: - AC3: an immediate startup completion cannot beat installation

    func testStartupDrainBeforeHookInstallationIsStillDeliveredExactlyOnce() async throws {
        let remote = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        let repository = try stores.repository(remote: remote)
        let mealID = try await repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(9)), photo: nil
        )
        let writer = SyncNotifyMealWriter()
        let engine = try stores.engine(mealRemote: writer, healthRemote: nil, now: { self.reference })

        // The app's engine exists (durable retry / importer paths can drive it)
        // before the shell's `.task` installs the hook, so this immediate
        // startup drain finishes with nobody listening.
        await engine.runPass()
        XCTAssertEqual(writer.committedMealIDs, [mealID], "the startup drain really delivered")

        let events = SyncNotifyEvents()
        let model = try stores.viewModel(
            repository: repository, healthStore: try stores.health(), date: reference
        )
        await stores.reconcile(engine, model: model, into: events)

        XCTAssertEqual(events.count, 1, "installation cannot be beaten by an earlier completion")
        XCTAssertEqual(events.changes.first?.releasedMealIDs, [mealID])
        XCTAssertTrue(events.changes.first?.changesJournal == true)

        await engine.runPass() // nothing is left: no replay, no duplicate
        XCTAssertEqual(events.count, 1)
    }

    func testCompletionsBeforeInstallationArriveAsOneBoundedEvent() async throws {
        let remote = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        let repository = try stores.repository(remote: remote)
        let writer = SyncNotifyMealWriter()
        let engine = try stores.engine(mealRemote: writer, healthRemote: nil, now: { self.reference })

        let firstID = try await repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(9)), photo: nil
        )
        await engine.runPass() // finish #1, nobody listening
        let secondID = try await repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(13)), photo: nil
        )
        await engine.runPass() // finish #2 merges into the same buffered change

        let events = SyncNotifyEvents()
        let model = try stores.viewModel(
            repository: repository, healthStore: try stores.health(), date: reference
        )
        await stores.reconcile(engine, model: model, into: events)

        XCTAssertEqual(events.count, 1, "buffered completions stay bounded to ONE event")
        XCTAssertEqual(events.changes.first?.releasedMealIDs, [firstID, secondID])
        XCTAssertTrue(try stores.store().queuedMeals().isEmpty)
    }

    func testProductionSyncNowPathDeliversTheSameBoundedEvent() async throws {
        let remote = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        let repository = try stores.repository(remote: remote)
        let mealID = try await repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(9)), photo: nil
        )
        let writer = SyncNotifyMealWriter()
        let engine = try stores.engine(mealRemote: writer, healthRemote: nil, now: { self.reference })
        let events = SyncNotifyEvents()
        let model = try stores.viewModel(
            repository: repository, healthStore: try stores.health(), date: reference
        )
        await stores.reconcile(engine, model: model, into: events)
        // The server carries the row under the same client id after the commit.
        remote.snapshot = DashboardSnapshot(
            date: day, meals: [FirstPaintFixture.meal(id: mealID, at: at(9))], goal: nil
        )

        engine.syncNow() // the shipped driver, not the test-only runPass entry point
        let deadline = Date().addingTimeInterval(10)
        while model.snapshot?.meals.first?.syncState != .synced, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.changes.first?.releasedMealIDs, [mealID])
        XCTAssertEqual(model.snapshot?.meals.first?.syncState, .synced, "the journal converged through the hook")
    }

    // MARK: - AC5: meal-only / Health-only / mixed / empty passes, SQLite-backed

    func testSQLiteBackedEmptyAndMealOnlyPassesReportTheirOutputs() async throws {
        let rig = try await makeRig()

        // (1) EMPTY pass: nothing queued, nothing dirty.
        await rig.engine.runPass()
        XCTAssertEqual(rig.events.count, 0, "an empty pass notifies nobody")
        XCTAssertEqual(rig.remote.dayReads, 0, "and reads nothing")

        // (2) MEAL-ONLY pass.
        let mealID = try await rig.repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(9)), photo: nil
        )
        await rig.model.load()
        XCTAssertEqual(rig.model.snapshot?.meals.first?.syncState, .pending, "the queued row paints first")
        rig.remote.snapshot = DashboardSnapshot(
            date: day, meals: [FirstPaintFixture.meal(id: mealID, at: at(9))], goal: nil
        )
        await rig.engine.runPass()

        let mealPass = try XCTUnwrap(rig.events.change(at: 0))
        XCTAssertEqual(rig.events.count, 1)
        XCTAssertEqual(mealPass.releasedMealIDs, [mealID])
        XCTAssertEqual(mealPass.syncedWeightCount + mealPass.syncedEnergyCount, 0)
        XCTAssertEqual(rig.model.snapshot?.meals.first?.syncState, .synced, "journal output converged")
        XCTAssertTrue(rig.model.healthStatus == .unknown, "a meal-only pass leaves the Health status alone")
        XCTAssertTrue(rig.healthRemote.weightPushes.isEmpty)
    }

    func testSQLiteBackedHealthOnlyAndMixedPassesReportTheirOutputs() async throws {
        let rig = try await makeRig()

        // (3) HEALTH-ONLY pass: one dirty body-mass sample plus one dirty day.
        try await rig.health.upsert([WeightLog(measuredAt: at(7), kilograms: 72.4)])
        try await rig.health.upsertEnergyBurned([EnergyBurnedLog(burnedAt: day, activeKilocalories: 480)])
        let readsBeforeHealth = rig.remote.dayReads
        await rig.engine.runPass()
        let healthPass = try XCTUnwrap(rig.events.change(at: 0))
        XCTAssertEqual(rig.events.count, 1)
        XCTAssertTrue(healthPass.releasedMealIDs.isEmpty)
        XCTAssertEqual(healthPass.syncedWeightCount, 1)
        XCTAssertEqual(healthPass.syncedEnergyCount, 1)
        XCTAssertEqual(rig.remote.dayReads, readsBeforeHealth, "Health-only output is the status, not the journal")
        XCTAssertEqual(rig.healthRemote.weightPushes.count, 1)
        XCTAssertEqual(rig.healthRemote.energyPushes.count, 1)
        XCTAssertEqual(rig.model.healthStatus, .synced(reference, syncedKinds: [.bodyMass, .activeEnergy]))

        // (4) MIXED pass: a new queued meal plus one more dirty sample.
        let firstID = try await rig.repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(9)), photo: nil
        )
        let secondID = try await rig.repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(13)), photo: nil
        )
        rig.remote.snapshot = DashboardSnapshot(date: day, meals: [
            FirstPaintFixture.meal(id: firstID, at: at(9)),
            FirstPaintFixture.meal(id: secondID, at: at(13))
        ], goal: nil)
        try await rig.health.upsert([WeightLog(measuredAt: at(20), kilograms: 72.6)])
        let readsBeforeMixed = rig.remote.dayReads
        await rig.engine.runPass()

        let mixedPass = try XCTUnwrap(rig.events.change(at: 1))
        XCTAssertEqual(rig.events.count, 2)
        XCTAssertEqual(mixedPass.releasedMealIDs.sorted(), [firstID, secondID].sorted())
        XCTAssertEqual(mixedPass.syncedWeightCount, 1, "only the newly dirty sample uploads")
        XCTAssertEqual(mixedPass.syncedEnergyCount, 0)
        XCTAssertTrue(mixedPass.changesJournal && mixedPass.changesHealthStatus)
        XCTAssertEqual(rig.remote.dayReads, readsBeforeMixed + 1, "the mixed event reconciles the journal once")
        XCTAssertEqual(rig.model.snapshot?.meals.count, 2)
        XCTAssertTrue(rig.model.snapshot?.meals.allSatisfy { $0.syncState == .synced } == true)
        XCTAssertFalse(try rig.health.hasPendingUploads())
    }

    /// The app's account wiring over one SQLite file, with the shipped hook
    /// installed on the model that renders the day.
    private struct PassRig {
        let health: LocalHealthStore
        let remote: FirstPaintRemote
        let repository: LocalFirstDashboardRepository
        let model: DashboardViewModel
        let healthRemote: SyncNotifyHealthRemote
        let engine: LocalSyncEngine
        let events: SyncNotifyEvents
    }

    private func makeRig() async throws -> PassRig {
        let health = try stores.health()
        let remote = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        let repository = try stores.repository(remote: remote)
        let model = try stores.viewModel(repository: repository, healthStore: health, date: reference)
        let healthRemote = SyncNotifyHealthRemote()
        let engine = try stores.engine(
            mealRemote: SyncNotifyMealWriter(), healthRemote: healthRemote, now: { self.reference }
        )
        let events = SyncNotifyEvents()
        await stores.reconcile(engine, model: model, into: events)
        return PassRig(
            health: health, remote: remote, repository: repository, model: model,
            healthRemote: healthRemote, engine: engine, events: events
        )
    }
}

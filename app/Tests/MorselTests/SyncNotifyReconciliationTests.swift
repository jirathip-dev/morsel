import XCTest
@testable import Morsel

// Issue #189 — the reconciliation events a pass must emit are about ACTUAL
// changes, not remaining queue depth. Every witness here runs the real engine
// over the real account SQLite file and installs the shipped hook (journal day
// re-read + Health status re-derive), so convergence is observed on the model
// that renders it — never on source strings.
@MainActor
final class SyncNotifyReconciliationTests: XCTestCase {
    private let stores = SyncNotifyStores()
    /// 2026-09-05T00:00:00Z — a fixed local day and the injected pass clock.
    private let reference = Date(timeIntervalSince1970: 1_788_566_400)

    private var day: Date { DashboardMath.startOfLocalDay(reference) }
    private func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3_600) }

    override func setUpWithError() throws { try stores.createRoot() }
    override func tearDownWithError() throws { stores.removeRoot() }

    // MARK: - AC1: a successful final-meal drain reconciles the journal

    func testFinalMealDrainReconcilesTheJournalWithoutTabSwitching() async throws {
        let health = try stores.health()
        let remote = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        let repository = try stores.repository(remote: remote)
        let mealID = try await repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(12)), photo: nil
        )
        let model = try stores.viewModel(repository: repository, healthStore: health, date: reference)
        await model.load()
        XCTAssertEqual(model.snapshot?.meals.map(\.mealLogID), [mealID])
        XCTAssertEqual(model.snapshot?.meals.first?.syncState, .pending, "the queued row paints first")
        let readsBeforeDrain = remote.dayReads

        // The server now carries the row under the SAME client id (its primary
        // key), so the authoritative read must replace the pending copy.
        remote.snapshot = DashboardSnapshot(
            date: day, meals: [FirstPaintFixture.meal(id: mealID, at: at(12), name: "server bowl")], goal: nil
        )
        let writer = SyncNotifyMealWriter()
        let engine = try stores.engine(mealRemote: writer, healthRemote: nil, now: { self.reference })
        let events = SyncNotifyEvents()
        await stores.reconcile(engine, model: model, into: events)

        await engine.runPass()

        XCTAssertEqual(events.count, 1, "a successful final drain emits exactly ONE reconciliation event")
        XCTAssertEqual(events.changes.first?.releasedMealIDs, [mealID])
        XCTAssertTrue(events.changes.first?.changesJournal == true)
        XCTAssertFalse(events.changes.first?.changesHealthStatus == true, "no Health work rode along")
        XCTAssertEqual(writer.committedMealIDs, [mealID])
        XCTAssertTrue(try stores.store().queuedMeals().isEmpty, "the authoritative result released the row")
        XCTAssertEqual(model.snapshot?.meals.count, 1, "never a duplicate row")
        XCTAssertEqual(model.snapshot?.meals.first?.syncState, .synced, "the journal converged in place")
        XCTAssertEqual(model.selectedDate, day, "convergence needed no tab switch")
        XCTAssertGreaterThan(remote.dayReads, readsBeforeDrain, "the event drove the authoritative re-read")
    }

    // MARK: - AC2: Health-only success names its kinds, a no-op pass reloads nothing

    func testHealthOnlySuccessUpdatesPerTypeStatusWithoutReloadingTheDashboard() async throws {
        let health = try stores.health()
        let remote = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        let model = try stores.viewModel(
            repository: try stores.repository(remote: remote), healthStore: health, date: reference
        )
        await model.load()
        let readsBeforePass = remote.dayReads
        // An energy-only dirty day; this account has no body-mass row at all.
        try await health.upsertEnergyBurned([EnergyBurnedLog(burnedAt: day, activeKilocalories: 512)])

        let healthRemote = SyncNotifyHealthRemote()
        let engine = try stores.engine(mealRemote: nil, healthRemote: healthRemote, now: { self.reference })
        let events = SyncNotifyEvents()
        await stores.reconcile(engine, model: model, into: events)

        await engine.runPass()

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events.changes.first?.changesHealthStatus == true)
        XCTAssertFalse(events.changes.first?.changesJournal == true, "Health-only never reloads the journal")
        XCTAssertEqual(events.changes.first?.syncedEnergyCount, 1)
        XCTAssertEqual(events.changes.first?.syncedWeightCount, 0, "zero body-mass rows is never a weight sync")
        XCTAssertEqual(remote.dayReads, readsBeforePass, "…and the dashboard was not reloaded")
        XCTAssertEqual(
            model.healthStatus, .synced(reference, syncedKinds: [.activeEnergy]),
            "the per-type status names exactly the kinds that uploaded"
        )
        XCTAssertFalse(try health.hasPendingUploads())
        XCTAssertNil(try health.lastWeightUpload(), "an energy-only upload never stamps weight")
    }

    func testNoOpPassNotifiesNobodyAndDoesNotReload() async throws {
        let health = try stores.health()
        let remote = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        let model = try stores.viewModel(
            repository: try stores.repository(remote: remote), healthStore: health, date: reference
        )
        await model.load()
        let readsBeforePass = remote.dayReads

        let healthRemote = SyncNotifyHealthRemote()
        let engine = try stores.engine(
            mealRemote: SyncNotifyMealWriter(), healthRemote: healthRemote, now: { self.reference }
        )
        let events = SyncNotifyEvents()
        await stores.reconcile(engine, model: model, into: events)

        await engine.runPass() // empty queue, nothing dirty: a pure no-op pass

        XCTAssertEqual(events.count, 0, "a pass that changed nothing is not an event")
        XCTAssertEqual(remote.dayReads, readsBeforePass, "a no-op pass must not reload the dashboard")
        XCTAssertTrue(model.healthStatus == .unknown, "no Health claim was invented")
        XCTAssertTrue(healthRemote.weightPushes.isEmpty && healthRemote.energyPushes.isEmpty)
    }

    // MARK: - AC4: refusal notifications are bounded to visible changes

    func testVisibleRefusalChangeNotifiesOnceAndUnchangedFailureDoesNotStorm() async throws {
        let remote = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        let repository = try stores.repository(remote: remote)
        let mealID = try await repository.logMeal(
            userID: stores.account, draft: FirstPaintFixture.draft(eatenAt: at(8)), photo: nil
        )
        let writer = SyncNotifyMealWriter()
        writer.refusal = .permanent(.auth)
        let engine = try stores.engine(mealRemote: writer, healthRemote: nil, now: { self.reference })
        let events = SyncNotifyEvents()
        let model = try stores.viewModel(
            repository: repository, healthStore: try stores.health(), date: reference
        )
        await stores.reconcile(engine, model: model, into: events)

        await engine.runPass() // pending → needsAttention(.auth): one visible change
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.changes.last?.refusalChangedMealIDs, [mealID])
        XCTAssertEqual(try stores.store().queuedMeal(mealID: mealID)?.state, .needsAttention)
        XCTAssertTrue(writer.committedMealIDs.isEmpty, "a refusal is never a delivery success")

        await engine.runPass() // the SAME failure again: nothing visible moved
        XCTAssertEqual(events.count, 1, "an unchanged failure must not reload the journal")

        writer.refusal = .permanent(.validation)
        await engine.runPass() // the visible refusal text changed: exactly one more event
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.changes.last?.refusalChangedMealIDs, [mealID])
        XCTAssertEqual(try stores.store().queuedMeal(mealID: mealID)?.lastErrorCategory, .validation)

        await engine.runPass() // validation rows are not retried: still two
        XCTAssertEqual(events.count, 2, "no reload storm from a refusal nothing can move")
    }

    func testFailedHealthPassStaysPendingAndNotifiesNobody() async throws {
        let health = try stores.health()
        let remote = FirstPaintRemote(snapshot: DashboardSnapshot(date: day, meals: [], goal: nil))
        let model = try stores.viewModel(
            repository: try stores.repository(remote: remote), healthStore: health, date: reference
        )
        await model.load()
        try await health.upsert([WeightLog(measuredAt: at(7), kilograms: 72.4)])
        try await health.upsertEnergyBurned([EnergyBurnedLog(burnedAt: day, activeKilocalories: 480)])
        let healthRemote = SyncNotifyHealthRemote()
        healthRemote.isFailing = true
        let engine = try stores.engine(mealRemote: nil, healthRemote: healthRemote, now: { self.reference })
        let events = SyncNotifyEvents()
        await stores.reconcile(engine, model: model, into: events)
        let readsBeforePass = remote.dayReads

        await engine.runPass() // the upload fails: rows stay dirty

        XCTAssertEqual(events.count, 0, "a failed pass changed nothing to reconcile")
        XCTAssertEqual(remote.dayReads, readsBeforePass, "…and must not reload the dashboard")
        XCTAssertNil(try health.lastSuccessfulUpload(), "a failed upload never claims a sync")
        XCTAssertTrue(try health.hasPendingUploads(), "the rows are still awaiting upload")
        XCTAssertTrue(model.healthStatus == .unknown, "no Health claim was invented")

        healthRemote.isFailing = false
        await engine.runPass() // the retry succeeds: exactly one event, and the types are honest
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.changes.last?.syncedWeightCount, 1)
        XCTAssertEqual(events.changes.last?.syncedEnergyCount, 1)
        XCTAssertEqual(model.healthStatus, .synced(reference, syncedKinds: [.bodyMass, .activeEnergy]))
    }
}

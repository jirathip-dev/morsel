import XCTest
@testable import Morsel

// Issue #186 — a draft revision owns background hydration and the save
// acknowledgement. Every case drives the PRODUCTION GoalsEditorViewModel
// through its real methods (load / edit / choose / save / fieldError) with
// parked continuations for the cached paint, the remote context, the compute
// and the write, so a "late" arrival is the test's to schedule: no sleeps,
// no clock reads, no source-string assertions.

@MainActor
final class GoalsDraftRevisionTests: XCTestCase {
    private let account = UUID()

    private enum WaitFailure: Error { case timedOut }

    /// A missed handshake aborts instead of falling through into an unbounded wait.
    private func waitFor(
        _ message: String, _ condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(message)", file: file, line: line)
                throw WaitFailure.timedOut
            }
            await Task.yield()
        }
    }

    /// The unstructured load/choose task may suspend; the TEST only awaits a bounded waiter.
    private func finish(
        _ task: Task<Void, Never>, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let done = XCTestExpectation(description: message)
        Task {
            await task.value
            done.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [done], timeout: 3)
        guard result == .completed else {
            task.cancel()
            XCTFail("Timed out waiting for \(message)", file: file, line: line)
            throw WaitFailure.timedOut
        }
    }

    private func manualRow(
        _ calories: Double, _ protein: Double, _ carbs: Double, _ fat: Double
    ) -> StoredDashboardGoal {
        StoredDashboardGoal(
            calorieTargetKcal: calories, proteinG: protein, carbsG: carbs, fatG: fat, source: .manual
        )
    }

    // MARK: - AC1/AC2: a late cached first paint cannot replace the draft

    @MainActor
    func testLateCachedPaintCannotOverwriteAnEditedFieldAndStillFillsPristineOnes() async throws {
        let repository = GoalsDraftRepository()
        repository.cachedGoal = manualRow(2_000, 150, 200, 70)
        repository.holdsCachedGoal = true
        let viewModel = GoalsEditorViewModel(repository: repository, userID: account)

        let load = Task { await viewModel.load() }
        try await waitFor("cached paint parked") { repository.parkedOnCachedGoal }

        // The user starts the draft while the cached paint is still in flight.
        viewModel.edit("calories", value: "")
        viewModel.edit("protein", value: "not-a-number")
        repository.releaseCachedGoal()
        try await finish(load, "goals load")

        // AC1 — the late cached row cannot overwrite edits, including text
        // emptied or left invalid, nor their manual source.
        XCTAssertEqual(viewModel.calories, "")
        XCTAssertEqual(viewModel.protein, "not-a-number")
        XCTAssertEqual(viewModel.sources["calories"], .manual)
        XCTAssertEqual(viewModel.sources["protein"], .manual)
        XCTAssertEqual(viewModel.sourceIndicator, "writes source: manual")
        XCTAssertEqual(viewModel.fieldError("calories"), "Enter a number of 0 or more.")
        XCTAssertEqual(viewModel.fieldError("protein"), "Enter a number of 0 or more.")
        XCTAssertFalse(viewModel.isValid)
        // AC2 — pristine fields hydrate normally, with the row's own source.
        XCTAssertEqual(viewModel.carbs, "200.0")
        XCTAssertEqual(viewModel.fat, "70.0")
        XCTAssertEqual(viewModel.sources["carbs"], .manual)
        XCTAssertNil(viewModel.fieldError("carbs"))
        XCTAssertFalse(viewModel.didSave)
    }

    // MARK: - AC1/AC2: a late remote context cannot replace the draft

    @MainActor
    func testLateRemoteContextCannotOverwriteAnEditedFieldAndStillFillsPristineOnes() async throws {
        let repository = GoalsDraftRepository()
        repository.cachedGoal = manualRow(2_000, 150, 200, 70)
        repository.contextStored = manualRow(2_100, 160, 210, 75)
        repository.holdsContext = true
        let viewModel = GoalsEditorViewModel(repository: repository, userID: account)

        let load = Task { await viewModel.load() }
        try await waitFor("remote context parked") { repository.parkedOnContext }

        viewModel.edit("protein", value: "")
        repository.releaseContext()
        try await finish(load, "goals load")

        // AC1 — the emptied field keeps its text, its manual source and its
        // validation error; nothing re-fills it from the late row.
        XCTAssertEqual(viewModel.protein, "")
        XCTAssertEqual(viewModel.sources["protein"], .manual)
        XCTAssertEqual(viewModel.fieldError("protein"), "Enter a number of 0 or more.")
        // AC2 — every pristine field takes the late row: the read still
        // reconciles the page (and its provenance baseline) around the draft.
        XCTAssertEqual(viewModel.calories, "2100.0")
        XCTAssertEqual(viewModel.carbs, "210.0")
        XCTAssertEqual(viewModel.fat, "75.0")
        XCTAssertEqual(viewModel.sources["calories"], .manual)
        XCTAssertEqual(viewModel.goal?.calorieTargetKcal, 2_100)
        XCTAssertNil(viewModel.fieldError("calories"))
    }

    // MARK: - AC1/AC2: the pager-revisit refresh cannot replace the draft

    @MainActor
    func testPagerRevisitRefreshCannotOverwriteTheDraftAndStillFillsPristineFields() async throws {
        let repository = GoalsDraftRepository()
        repository.cachedGoal = manualRow(2_000, 150, 200, 70)
        repository.contextStored = manualRow(2_000, 150, 200, 70)
        let viewModel = GoalsEditorViewModel(repository: repository, userID: account)
        await viewModel.load()
        XCTAssertEqual(viewModel.calories, "2000.0")

        viewModel.edit("calories", value: "")
        viewModel.edit("protein", value: "abc")
        XCTAssertEqual(viewModel.sourceIndicator, "writes source: manual")

        // The pager re-activates Goals: `.task(id: reloadKey)` re-runs load()
        // on the SAME model, and both reads now serve a newer row.
        repository.cachedGoal = manualRow(2_400, 170, 220, 80)
        repository.contextStored = manualRow(2_400, 170, 220, 80)
        await viewModel.load()

        // AC1 — the refreshed row cannot overwrite the draft fields.
        XCTAssertEqual(viewModel.calories, "")
        XCTAssertEqual(viewModel.protein, "abc")
        XCTAssertEqual(viewModel.sources["calories"], .manual)
        XCTAssertEqual(viewModel.sources["protein"], .manual)
        XCTAssertEqual(viewModel.sourceIndicator, "writes source: manual")
        XCTAssertEqual(viewModel.fieldError("protein"), "Enter a number of 0 or more.")
        XCTAssertFalse(viewModel.isValid)
        XCTAssertFalse(viewModel.didSave)
        // AC2 — the pristine fields take the refresh (2400 / 220 / 80).
        XCTAssertEqual(viewModel.carbs, "220.0")
        XCTAssertEqual(viewModel.fat, "80.0")
        XCTAssertNil(viewModel.fieldError("carbs"))
    }

    // MARK: - AC3: only the submitted revision may be acknowledged

    @MainActor
    func testEditingAgainDuringSaveLeavesTheNewRevisionUnsaved() async throws {
        let repository = GoalsDraftRepository()
        repository.contextStored = manualRow(2_000, 150, 200, 70)
        let viewModel = GoalsEditorViewModel(repository: repository, userID: account)
        await viewModel.load()

        viewModel.edit("calories", value: "2300")
        repository.holdsSave = true
        let submitting = Task { await viewModel.save() }
        try await waitFor("the write parked") { repository.parkedOnSave }
        XCTAssertTrue(viewModel.isSaving)

        // The user edits again while the older revision is on the wire.
        viewModel.edit("calories", value: "2500")
        repository.releaseSave()
        let savedOlderRevision = await submitting.value

        // AC3 — the older save cannot acknowledge the newer revision.
        XCTAssertFalse(savedOlderRevision)
        XCTAssertFalse(viewModel.didSave)
        XCTAssertEqual(viewModel.calories, "2500")
        XCTAssertEqual(repository.savedGoals.map(\.calorieTargetKcal), [2_300])

        // The newer revision is one real save away, and THAT one is acknowledged.
        let savedNewerRevision = await viewModel.save()
        XCTAssertTrue(savedNewerRevision)
        XCTAssertTrue(viewModel.didSave)
        // The accepted save stores the canonical one-decimal display text.
        XCTAssertEqual(viewModel.calories, "2500.0")
        XCTAssertEqual(repository.savedGoals.map(\.calorieTargetKcal), [2_300, 2_500])
    }

    // MARK: - AC3: a refresh during the write cannot rewrite the submission

    @MainActor
    func testRefreshDuringASaveCannotRewriteTheSubmittedValues() async throws {
        let repository = GoalsDraftRepository()
        repository.contextStored = manualRow(2_000, 150, 200, 70)
        let viewModel = GoalsEditorViewModel(repository: repository, userID: account)
        await viewModel.load()

        viewModel.edit("calories", value: "2300")
        repository.holdsSave = true
        let submitting = Task { await viewModel.save() }
        try await waitFor("the write parked") { repository.parkedOnSave }

        // A background refresh serves a newer row while the write is on the
        // wire: what is being stored is what the page must show.
        repository.cachedGoal = manualRow(2_600, 170, 240, 90)
        repository.contextStored = manualRow(2_600, 170, 240, 90)
        await viewModel.load()
        XCTAssertEqual(viewModel.calories, "2300.0", "the refresh must not rewrite the submission")

        repository.releaseSave()
        let saved = await submitting.value
        XCTAssertTrue(saved)
        XCTAssertTrue(viewModel.didSave)
        XCTAssertEqual(viewModel.calories, "2300.0")
        XCTAssertEqual(repository.savedGoals.map(\.calorieTargetKcal), [2_300])
    }

    // MARK: - AC4: a late computation cannot replace the draft either

    @MainActor
    func testLateComputeCannotOverwriteAnEditedDraft() async throws {
        let repository = GoalsDraftRepository()
        repository.contextStored = manualRow(2_000, 150, 200, 70)
        let viewModel = GoalsEditorViewModel(repository: repository, userID: account)
        await viewModel.load()

        let arrived = XCTestExpectation(description: "bulk computation arrives")
        repository.expectNextCompute(arrived)
        let choosing = Task { await viewModel.choose(.bulk) }
        await fulfillment(of: [arrived], timeout: 3)

        viewModel.edit("protein", value: "165")
        repository.finishCompute(0, .success(DashboardGoal(
            calorieTargetKcal: 2_600, proteinG: 160, carbsG: 310, fatG: 80, source: .computed
        )))
        await choosing.value

        XCTAssertEqual(viewModel.protein, "165")
        XCTAssertEqual(viewModel.sources["protein"], .manual)
        XCTAssertNil(viewModel.selectedDirection)
        XCTAssertNil(viewModel.pendingDirection)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.didSave)
    }

    // MARK: - AC4: an account change rebuilds a pristine draft

    @MainActor
    func testAccountChangeStartsAPristineDraftAndLateReadsStayWithTheirAccount() async throws {
        let repository = GoalsDraftRepository()
        repository.cachedGoal = manualRow(2_000, 150, 200, 70)
        repository.contextStored = manualRow(2_000, 150, 200, 70)
        let previousAccount = account
        let previous = GoalsEditorViewModel(repository: repository, userID: previousAccount)
        await previous.load()
        previous.edit("calories", value: "2300")
        previous.edit("fat", value: "")
        XCTAssertEqual(previous.sources["calories"], .manual)

        // The account changes: the root is re-identified per user
        // (MorselApp `.id(session.userID)`), so Goals is rebuilt.
        let newAccount = UUID()
        repository.cachedGoal = manualRow(2_100, 160, 210, 75)
        repository.contextStored = manualRow(2_100, 160, 210, 75)
        repository.holdsCachedGoal = true
        let rebuilt = GoalsEditorViewModel(repository: repository, userID: newAccount)
        let load = Task { await rebuilt.load() }
        try await waitFor("the new account's cached paint parked") { repository.parkedOnCachedGoal }

        // Pristine: no draft field, source, baseline or saved banner leaks
        // across the rebuild, and every read is stamped with its own account.
        XCTAssertTrue(rebuilt.calories.isEmpty)
        XCTAssertTrue(rebuilt.fat.isEmpty)
        XCTAssertNil(rebuilt.goal)
        XCTAssertFalse(rebuilt.didSave)
        XCTAssertEqual(repository.cachedGoalRequests, [previousAccount, newAccount])
        XCTAssertEqual(repository.contextRequests, [previousAccount])

        repository.releaseCachedGoal()
        try await finish(load, "the new account's goals load")

        XCTAssertEqual(rebuilt.calories, "2100.0")
        XCTAssertEqual(rebuilt.sources["calories"], .manual)
        XCTAssertFalse(rebuilt.didSave)
        // The previous account's model keeps its own draft untouched.
        XCTAssertEqual(previous.calories, "2300")
        XCTAssertEqual(previous.fat, "")
    }
}

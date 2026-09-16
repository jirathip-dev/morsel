import Combine
import XCTest
@testable import Morsel
import HealthKit

#if canImport(HealthKit)
// Issue #173 (P1, tracker #172) — the Health read-prompt status seam is async
// end to end: NO semaphore/thread wait may sit on the production status call
// chain. These regressions drive the REAL HealthKitWeightReader through a
// scripted HKHealthStore so delayed/errored/silent HealthKit answers are
// observable with real MainActor timing:
//   (1) a delayed status callback must leave the MainActor heartbeat alive —
//       the behavioral regression for the removed blocking bridge;
//   (2) body-mass and active-energy read states stay independent per type;
//   (3) an errored status query means unknown — never answered, granted,
//       denied or synced;
//   (4)+(5) cancellation and late completions resolve exactly once and
//       cannot double-resume the checked continuation.
@MainActor
final class HealthStatusAsyncTests: XCTestCase {
    // MARK: - (1) Delayed completion: the MainActor keeps making progress

    func testDelayedStatusCallbackKeepsMainActorHeartbeatAlive() async throws {
        let store = ScriptedStatusHealthStore()
        store.callbackDelay = 0.4
        store.script([.status(.unnecessary), .status(.unnecessary)])
        let reader = try HealthKitWeightReader(healthStore: store)
        let importer = try HealthKitWeightImporter(reader: reader, store: MockWeightLogStore())
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(
                snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil)
            ),
            userID: UUID(), weightImporter: importer
        )

        let started = Date()
        let refresh = Task { await viewModel.refreshHealthCalmStatus() }
        // Heartbeat: count MainActor hops while HealthKit has not answered.
        // A blocking status bridge starves this loop; the async seam lets it
        // run one hop per sleep interval until both callbacks arrive.
        var beats = 0
        while store.completedCallbacks < 2, Date().timeIntervalSince(started) < 5 {
            beats += 1
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let elapsed = Date().timeIntervalSince(started)
        await refresh.value

        // Raw before/after trace captured from the lane logs (.report.md):
        // blocked base mechanism ≈ 1 beat; async seam ≈ one hop per ~5 ms.
        print("HEARTBEAT[issue-173] beats=\(beats) elapsed=\(elapsed)s")
        XCTAssertEqual(store.completedCallbacks, 2, "both per-type callbacks answered")
        XCTAssertGreaterThanOrEqual(
            elapsed, 0.3,
            "the delayed callback really gated the status derivation"
        )
        XCTAssertGreaterThanOrEqual(
            beats, 5,
            "the MainActor must make progress while HealthKit answers — "
                + "a semaphore/thread wait starves it"
        )
        XCTAssertEqual(
            viewModel.healthStatus, .noWeightData,
            "answered-but-empty is the no-data state — never a synced claim, "
                + "never proof that read access was granted"
        )
    }

    // MARK: - (2) Per-type states stay independent

    func testPerTypePromptStatusStaysIndependent() async throws {
        let store = ScriptedStatusHealthStore()
        store.script([.status(.unnecessary), .status(.shouldRequest)])
        let reader = try HealthKitWeightReader(healthStore: store)

        let bodyDecided = await reader.authorizationStatus(for: .bodyMass)
        let energyDecided = await reader.authorizationStatus(for: .activeEnergyBurned)

        XCTAssertTrue(bodyDecided, "body mass: the read prompt was answered")
        XCTAssertFalse(
            energyDecided,
            "active energy keeps its own state: read access is not granted"
        )
        XCTAssertEqual(store.requestedReadTypes.count, 2, "one query per type")
        XCTAssertEqual(
            store.requestedReadTypes.first?.map(\.identifier),
            [HKQuantityTypeIdentifier.bodyMass.rawValue],
            "the body-mass check asks for exactly its own type"
        )
        XCTAssertEqual(
            store.requestedReadTypes.last?.map(\.identifier),
            [HKQuantityTypeIdentifier.activeEnergyBurned.rawValue]
        )
    }

    // MARK: - (3) Error/timeout means unknown — never answered, granted, denied

    func testStatusQueryErrorMeansUnknownNeverClaimsAnsweredOrSynced() async throws {
        let store = ScriptedStatusHealthStore()
        store.script([.error])
        let reader = try HealthKitWeightReader(healthStore: store)

        let decided = await reader.authorizationStatus(for: .bodyMass)

        XCTAssertFalse(
            decided,
            "an errored/timed-out status query means unknown — never answered "
                + "(and never presented as denied)"
        )

        let importer = try HealthKitWeightImporter(reader: reader, store: MockWeightLogStore())
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(
                snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil)
            ),
            userID: UUID(), weightImporter: importer
        )
        await viewModel.refreshHealthCalmStatus()

        XCTAssertEqual(
            viewModel.healthStatus, .permissionRequired,
            "an unknown read state asks for access — the app claims nothing stronger"
        )
        XCTAssertFalse(viewModel.healthStatus.copy.contains("synced"))
        XCTAssertFalse(viewModel.healthStatus.copy.contains("denied"))
    }

    // MARK: - (4)+(5) Cancellation and late completion resume exactly once

    func testCanceledStatusAwaitResolvesOnceOnLateCallback() async throws {
        let store = ScriptedStatusHealthStore()
        store.script([.silence])
        let reader = try HealthKitWeightReader(healthStore: store)

        let poll = Task { await reader.authorizationStatus(for: .bodyMass) }
        try await waitUntil { store.startedCallbacks == 1 }
        poll.cancel()
        store.firePending(with: .unnecessary) // the late HealthKit answer

        let decided = await poll.value
        XCTAssertTrue(decided, "the single late callback resumes the continuation exactly once")
        XCTAssertEqual(store.completedCallbacks, 1, "exactly one completion was delivered")
    }

    func testLateCallbackAfterCanceledRefreshCompletesCleanly() async throws {
        let store = ScriptedStatusHealthStore()
        store.script([.silence, .status(.unnecessary)])
        let reader = try HealthKitWeightReader(healthStore: store)
        let importer = try HealthKitWeightImporter(reader: reader, store: MockWeightLogStore())
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(
                snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil)
            ),
            userID: UUID(), weightImporter: importer
        )

        let refresh = Task { await viewModel.refreshHealthCalmStatus() }
        try await waitUntil { store.startedCallbacks == 1 }
        refresh.cancel()
        store.firePending(with: .unnecessary)

        await refresh.value
        XCTAssertEqual(store.completedCallbacks, 2)
        XCTAssertEqual(
            viewModel.healthStatus, .noWeightData,
            "the late answer derives exactly one calm status — no double publish"
        )
    }

    /// Bounded poll so a wedged seam fails fast instead of hanging a runner.
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// #209: outer deadlines fail the regression instead of hanging the suite on
/// the old bridge. Silent completions are drained only AFTER that assertion.
@MainActor
final class HealthStatusDeadlineTests: XCTestCase {
    func testNeverInvokingStatusReturnsUnknownWithinBound() async throws {
        let store = ScriptedStatusHealthStore()
        store.script([.silence])
        let reader = try HealthKitWeightReader(healthStore: store)
        var answer: Bool?
        let started = ContinuousClock.now
        let poll = Task { answer = await reader.authorizationStatus(for: .bodyMass) }
        defer { store.firePending(with: .unknown); poll.cancel() }

        await waitUntil(timeout: .seconds(3)) { answer != nil }
        let elapsed = started.duration(to: .now)
        print("DEADLINE[issue-209] answer=\(String(describing: answer)) elapsed=\(elapsed)")
        XCTAssertEqual(answer, false, "silent HealthKit must resolve unknown before the 3s outer deadline")
        XCTAssertLessThan(elapsed, .seconds(3), "production deadline is 2s; outer budget allows scheduling")
        XCTAssertEqual(store.completedCallbacks, 0, "no callback supplied the result")
    }

    func testBothSilentTypesFinishAndLateCallbacksCannotPublish() async throws {
        let store = ScriptedStatusHealthStore()
        store.script([.silence, .silence])
        let reader = try HealthKitWeightReader(healthStore: store)
        let importer = try HealthKitWeightImporter(reader: reader, store: MockWeightLogStore())
        let viewModel = DashboardViewModel(
            repository: MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil)),
            userID: UUID(), weightImporter: importer
        )
        var publications: [HealthCalmStatus] = []
        let subscription = viewModel.$healthStatus.dropFirst().sink { publications.append($0) }
        defer { subscription.cancel() }
        var finished = false
        let started = ContinuousClock.now
        let refresh = Task {
            await viewModel.refreshHealthCalmStatus()
            finished = true
        }
        defer {
            store.script([]) // Let a base-RED refresh drain its second request too.
            store.firePending(with: .unknown)
            refresh.cancel()
        }

        await waitUntil(timeout: .seconds(5)) { finished }
        let elapsed = started.duration(to: .now)
        print("STATUS-CHAIN[issue-209] finished=\(finished) elapsed=\(elapsed) publishes=\(publications.count)")
        XCTAssertTrue(finished, "two silent per-type requests must finish before the 5s outer deadline")
        guard finished else { return }
        XCTAssertLessThan(elapsed, .seconds(5))
        XCTAssertEqual(store.startedCallbacks, 2)
        XCTAssertEqual(store.completedCallbacks, 0)
        XCTAssertEqual(publications, [.permissionRequired], "false stays unknown, never denied or synced")

        // A later real refresh owns the state. Old completions may not overwrite
        // it OR cause a duplicate publication of the same value.
        store.script([.status(.unnecessary), .status(.unnecessary)])
        await viewModel.refreshHealthCalmStatus()
        XCTAssertEqual(publications, [.permissionRequired, .noWeightData])
        store.firePending(with: .unnecessary)
        XCTAssertEqual(store.completedCallbacks, 4, "both late callbacks really fired")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.healthStatus, .noWeightData)
        XCTAssertEqual(publications, [.permissionRequired, .noWeightData], "late callbacks must be inert")
    }

    private func waitUntil(timeout: Duration, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Scriptable `HKHealthStore` double: answers
/// `getRequestStatusForAuthorization` (optionally after a background-queue
/// delay), fails it, or stays silent so the test can fire a late completion.
/// Only the status seam is intercepted — the rest of HealthKit is untouched.
private final class ScriptedStatusHealthStore: HKHealthStore, @unchecked Sendable {
    enum Reply {
        case status(HKAuthorizationRequestStatus)
        case error
        /// Keep the completion; the test fires it later (late-callback probe).
        case silence
    }

    /// Completions arrive from the delivery queue too — lock every mutation.
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var pending: [(HKAuthorizationRequestStatus, Error?) -> Void] = []
    private(set) var requestedReadTypes: [Set<HKObjectType>] = []
    private(set) var startedCallbacks = 0
    private(set) var completedCallbacks = 0
    var callbackDelay: TimeInterval = 0

    func script(_ scripted: [Reply]) {
        lock.lock()
        replies = scripted
        lock.unlock()
    }

    override func getRequestStatusForAuthorization(
        toShare typesToShare: Set<HKSampleType>,
        read typesToRead: Set<HKObjectType>,
        completion: @escaping (HKAuthorizationRequestStatus, Error?) -> Void
    ) {
        lock.lock()
        let reply = replies.isEmpty ? Reply.status(.shouldRequest) : replies.removeFirst()
        requestedReadTypes.append(typesToRead)
        startedCallbacks += 1
        let delay = callbackDelay
        lock.unlock()

        guard delay > 0 else {
            deliver(reply, completion: completion)
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.deliver(reply, completion: completion)
        }
    }

    /// Fires every silent completion with a late prompt answer.
    func firePending(with status: HKAuthorizationRequestStatus) {
        lock.lock()
        let completions = pending
        pending = []
        lock.unlock()
        for completion in completions {
            completed()
            completion(status, nil)
        }
    }

    private func deliver(
        _ reply: Reply,
        completion: @escaping (HKAuthorizationRequestStatus, Error?) -> Void
    ) {
        switch reply {
        case let .status(status):
            completed()
            completion(status, nil)
        case .error:
            completed()
            completion(.unknown, NSError(domain: HKErrorDomain, code: 1))
        case .silence:
            lock.lock()
            pending.append(completion)
            lock.unlock()
        }
    }

    private func completed() {
        lock.lock()
        completedCallbacks += 1
        lock.unlock()
    }
}
#endif

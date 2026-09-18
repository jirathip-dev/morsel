import XCTest
@testable import Morsel

// Issue #310 — the restore phase as state: the unresolved phase is explicit
// (never inferred from a nil session), it is bounded (a hung refresh cannot
// leave the skeleton up forever), and a failed refresh is a recorded failure
// rather than a silent nil.

@MainActor
final class RestoringShellPhaseTests: XCTestCase {
    private let account = UUID()
    private var parked: [DeferredRestoreAuth] = []

    override func tearDown() async throws {
        // Drain any attempt the test left parked so no continuation leaks.
        for auth in parked {
            auth.release(.failure(URLError(.cancelled)))
        }
        parked = []
        try await super.tearDown()
    }

    private func parkedAuth() -> DeferredRestoreAuth {
        let auth = DeferredRestoreAuth()
        parked.append(auth)
        return auth
    }

    func testColdLaunchStartsUnresolvedAndADeferredRestoreKeepsItThere() async throws {
        let auth = parkedAuth()
        let store = SessionStore()
        XCTAssertTrue(store.isRestoring, "cold launch starts in the unresolved phase")
        XCTAssertNil(store.session, "no session is invented before the attempt answers")

        let attempt = Task { await store.restore(using: auth) }
        let reached = await RestoringShellMount.wait(until: { auth.isParked })
        XCTAssertTrue(reached, "the attempt must reach the restore transport")

        // A token refresh parks the same way: unresolved, and NOT resolved-empty.
        XCTAssertEqual(store.phase, .restoring)
        XCTAssertNil(store.session)
        XCTAssertNil(store.restoreFailure)
        XCTAssertFalse(store.isSetupDeferred, "a cold launch is not the deferred route")

        let session = RestoringShellFixture.session(userID: account)
        auth.release(.success(session))
        await attempt.value
        XCTAssertEqual(store.phase, .signedIn)
        XCTAssertEqual(store.session, session)
        XCTAssertNil(store.restoreFailure)
    }

    func testTheRestoringPhaseHoldsForTheWholeRestoreWindow() async throws {
        let auth = parkedAuth()
        let store = SessionStore()
        let attempt = Task { await store.restore(using: auth) }
        _ = await RestoringShellMount.wait(until: { auth.isParked })

        for sample in 1...6 {
            await RestoringShellMount.settle(120)
            XCTAssertEqual(store.phase, .restoring, "sample \(sample) is still the restoring window")
            XCTAssertNil(store.session)
            XCTAssertTrue(store.isRestoring)
        }

        auth.release(.success(RestoringShellFixture.session(userID: account)))
        await attempt.value
        XCTAssertEqual(store.phase, .signedIn, "the window ends when the attempt resolves")
    }

    func testGenuineNoSessionReachesOnboardingAndNeverStaysRestoring() async throws {
        let auth = parkedAuth()
        let store = SessionStore()
        let attempt = Task { await store.restore(using: auth) }
        _ = await RestoringShellMount.wait(until: { auth.isParked })

        auth.release(.success(nil))
        await attempt.value
        XCTAssertEqual(store.phase, .needsSetup, "a fresh install reaches onboarding")
        XCTAssertFalse(store.isRestoring, "the skeleton is never permanent")
        XCTAssertFalse(store.isSetupDeferred)
        XCTAssertNil(store.session)
        XCTAssertNil(store.restoreFailure, "no stored session is not a failure")
    }

    func testPreviouslyDeferredSetupReachesSignInOnceTheAttemptResolves() async throws {
        let auth = parkedAuth()
        let store = SessionStore()
        store.deferSetup()
        XCTAssertEqual(store.pendingRoute, .setupDeferred)

        let attempt = Task { await store.restore(using: auth) }
        _ = await RestoringShellMount.wait(until: { auth.isParked })
        XCTAssertEqual(store.phase, .restoring, "the deferred route does not fabricate a resolution")

        auth.release(.success(nil))
        await attempt.value
        XCTAssertEqual(store.phase, .needsSignIn, "the deferred route still reaches sign-in")
        XCTAssertTrue(store.isSetupDeferred)
        XCTAssertNil(store.session)
    }

    func testASettledDeferredRouteStaysOnSignInWithoutReOpeningTheSkeleton() async throws {
        let auth = parkedAuth()
        let store = SessionStore()
        await store.signOut(using: auth)
        XCTAssertEqual(store.phase, .needsSignIn)
        XCTAssertTrue(store.isSetupDeferred)

        await store.restore(using: auth)
        XCTAssertFalse(store.isRestoring, "a settled route never re-enters the skeleton")
        XCTAssertEqual(store.phase, .needsSignIn)
        XCTAssertEqual(auth.restoreCalls, 0, "a settled route starts no restore")
    }

    func testAHungRefreshResolvesToSignInWithinTheBound() async throws {
        let auth = parkedAuth()
        let store = SessionStore(restoreBound: .milliseconds(150))
        let attempt = Task { await store.restore(using: auth) }
        _ = await RestoringShellMount.wait(until: { auth.isParked })
        XCTAssertTrue(store.isRestoring)

        let bounded = await RestoringShellMount.wait(3, until: { !store.isRestoring })
        XCTAssertTrue(bounded, "a refresh that never answers must not leave the skeleton up")
        XCTAssertEqual(store.phase, .needsSignIn, "the bounded failure resolves to the sign-in route")
        XCTAssertEqual(store.restoreFailure, .timedOut)
        XCTAssertTrue(store.isSetupDeferred)

        auth.release(.success(RestoringShellFixture.session(userID: account)))
        await attempt.value
        XCTAssertEqual(store.phase, .needsSignIn, "a late completion never re-routes a settled shell")
        XCTAssertEqual(store.restoreFailure, .timedOut)
    }

    func testAFailedRefreshIsAnExplicitStateDistinctFromAGenuineNoSession() async throws {
        let auth = parkedAuth()
        let store = SessionStore()
        let attempt = Task { await store.restore(using: auth) }
        _ = await RestoringShellMount.wait(until: { auth.isParked })

        auth.release(.failure(URLError(.notConnectedToInternet)))
        await attempt.value
        XCTAssertEqual(store.phase, .needsSignIn)
        XCTAssertEqual(store.restoreFailure, .refreshFailed, "the failure is a state, not a nil")
        XCTAssertNil(store.session)
        XCTAssertTrue(store.isSetupDeferred, "a failed refresh resolves to the sign-in route")
        XCTAssertFalse(store.isRestoring)

        // The contrast the silent `try?` could not make: no stored session.
        let freshAuth = parkedAuth()
        let fresh = SessionStore()
        let freshAttempt = Task { await fresh.restore(using: freshAuth) }
        _ = await RestoringShellMount.wait(until: { freshAuth.isParked })
        freshAuth.release(.success(nil))
        await freshAttempt.value
        XCTAssertEqual(fresh.phase, .needsSetup)
        XCTAssertNil(fresh.restoreFailure, "a genuine no-session records no failure")
    }
}

import XCTest

// Issue #310 — the shell's restoring route pinned at source level (the native
// mirror of the hosted probes): the unresolved restore phase owns the first
// frame, no view-level timer decides how long the skeleton stays, and the
// restore path records an explicit failure instead of swallowing it into nil.
// These assertions compile against the pre-fix shell too, so they are the
// regression's cheapest bite.

final class RestoringShellRoutingTests: XCTestCase {
    private func readSource(_ name: String) throws -> String {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceRoot = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel")
        return try String(contentsOf: sourceRoot.appendingPathComponent(name), encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String? = nil) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start), "missing anchor \(start)")
        guard let end else { return String(source[startRange.lowerBound...]) }
        let endRange = try XCTUnwrap(source.range(of: end), "missing anchor \(end)")
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    func testShellDecidesTheRestoringPhaseBeforeAnySessionOrAuthSurface() throws {
        let shell = try readSource("MorselApp.swift")
        let root = try slice(
            shell, from: "struct MorselRootView: View", to: "private struct AuthenticatedDashboardView"
        )
        let restoring = try XCTUnwrap(
            root.range(of: "if sessionStore.isRestoring {"),
            "the shell must decide the restoring phase before anything else"
        )
        let session = try XCTUnwrap(
            root.range(of: "if let session = sessionStore.session {"),
            "the session branch must still exist"
        )
        XCTAssertLessThan(
            restoring.lowerBound, session.lowerBound,
            "the unresolved restore phase must own the first frame, before the session is read"
        )
        let branch = try slice(root, from: "if sessionStore.isRestoring {", to: "} else if let session")
        XCTAssertTrue(
            branch.contains("RestoringShellSkeleton()"),
            "the restoring phase must render the paper skeleton"
        )
        XCTAssertFalse(branch.contains("OnboardingView("), "restoring must never render onboarding")
        XCTAssertFalse(branch.contains("SignInView("), "restoring must never render sign-in")
    }

    func testAuthSurfacesStayReachableOnlyAfterThePhaseResolves() throws {
        let shell = try readSource("MorselApp.swift")
        let root = try slice(
            shell, from: "struct MorselRootView: View", to: "private struct AuthenticatedDashboardView"
        )
        XCTAssertTrue(root.contains("} else if sessionStore.isSetupDeferred {"), "sign-in route intact")
        XCTAssertTrue(root.contains("SignInView(auth: auth)"), "sign-in route intact")
        XCTAssertTrue(root.contains("OnboardingView("), "onboarding route intact")
        XCTAssertTrue(root.contains("sessionStore.deferSetup()"), "the deferred-setup transition is intact")
        XCTAssertTrue(root.contains("await sessionStore.restore(using: auth)"), "the shell still starts a restore")
    }

    func testRestorePathRecordsAnExplicitFailureInsteadOfASilentTry() throws {
        let store = try readSource("SessionStore.swift")
        XCTAssertFalse(
            store.contains("try? await auth.restoreSession()"),
            "a failed refresh must not collapse into the same nil as a genuine no-session"
        )
        XCTAssertTrue(store.contains("enum Phase"), "the shell phase must be an explicit state")
        XCTAssertTrue(store.contains("case restoring"))
        XCTAssertTrue(store.contains("case needsSetup"))
        XCTAssertTrue(store.contains("case needsSignIn"))
        XCTAssertTrue(store.contains("enum RestoreFailure"), "the failure must be an explicit state")
        XCTAssertTrue(store.contains("case refreshFailed"))
        XCTAssertTrue(store.contains("case timedOut"))
    }

    func testTheRestoringWindowIsNeverAVIewLevelTimer() throws {
        let shell = try readSource("MorselApp.swift")
        for token in ["Task.sleep", "asyncAfter", "DispatchQueue", "Timer", "debounce", "sleep"] {
            XCTAssertFalse(
                shell.contains(token),
                "the restoring window belongs to the state, never a view-level timer: \(token)"
            )
        }
    }

    func testRestoringSurfaceReusesThePaperSkeletonWithoutDataOrTabBar() throws {
        let skeleton = try readSource("RestoringShellSkeleton.swift")
        XCTAssertTrue(
            skeleton.contains("TodaySkeleton()"),
            "the restoring surface must reuse the existing paper-skeleton language"
        )
        XCTAssertTrue(skeleton.contains(".morselJournalPaperUnderlay()"), "the paper ground is the journal's")
        XCTAssertTrue(skeleton.contains("Color.morselBackground.ignoresSafeArea()"))
        for banned in ["JournalTabBar", "TabBar", "viewModel", "ForEach", "Date("] {
            XCTAssertFalse(
                skeleton.contains(banned),
                "the restoring surface carries no data-dependent content and no tab bar: \(banned)"
            )
        }
    }
}

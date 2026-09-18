import Combine
import Supabase
import SwiftUI
import XCTest
@testable import Morsel

// Issue #310 AC6 — rendered evidence for the three cold-launch cases in Paper
// and Night: stored session (skeleton → dashboard, no auth surface), fresh
// install (skeleton → onboarding), and an expired refresh token (skeleton →
// sign-in after the attempt, with no onboarding flash in between). Captures are
// XCTest attachments; the committed PNGs are this run's exported attachments.

@MainActor
final class RestoringShellEvidenceTests: XCTestCase {
    /// The reference surfaces a case's captures are decided against.
    struct References {
        let skeleton: Data
        let signIn: Data
        let onboarding: Data
    }

    /// One case's identity, account and references, so the case helpers stay
    /// under the repo lint's parameter cap.
    private struct CaseContext {
        let launch: String
        let theme: String
        let account: UUID
        let references: References

        var label: String { "\(theme)/\(launch)" }
    }

    private let cases = ["stored-session", "fresh-install", "expired-refresh"]
    private var windows: [UIWindow] = []
    private var parked: [DeferredRestoreAuth] = []

    override func setUp() {
        super.setUp()
        StubTransport.reset()
    }

    override func tearDown() async throws {
        for auth in parked {
            auth.release(.failure(URLError(.cancelled)))
        }
        parked = []
        for window in windows {
            RestoringShellMount.unmount(window)
        }
        windows = []
        await RestoringShellMount.settle(500)
        StubTransport.release()
        StubTransport.reset()
        try await super.tearDown()
    }

    func testColdLaunchCasesRenderInPaperAndNight() async throws {
        for (theme, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            let references = try await references(scheme)
            for launch in cases {
                let context = CaseContext(
                    launch: launch, theme: theme, account: UUID(), references: references
                )
                try await capture(context, scheme: scheme)
            }
        }
    }

    private func capture(_ context: CaseContext, scheme: ColorScheme) async throws {
        let auth = DeferredRestoreAuth()
        parked.append(auth)
        let store = SessionStore()
        let recorder = PhaseRecorder(store)
        let window = try mount(context, auth: auth, store: store, scheme: scheme)
        let reached = await RestoringShellMount.wait(until: { auth.isParked })
        XCTAssertTrue(reached, "\(context.label): the attempt must reach the transport")
        await RestoringShellMount.settle(400)
        XCTAssertEqual(store.phase, .restoring, "\(context.label): the first frame is unresolved")

        let name = "310-\(context.theme)-\(context.launch)"
        let restoring = try attach(RestoringShellMount.capture(window), "\(name)-restoring")
        XCTAssertEqual(restoring, context.references.skeleton, "\(context.label): paints the skeleton")
        XCTAssertNotEqual(restoring, context.references.signIn, "\(context.label): no sign-in surface")
        XCTAssertNotEqual(restoring, context.references.onboarding, "\(context.label): no onboarding surface")

        await resolve(context, auth: auth, store: store)
        await RestoringShellMount.settle(700)
        let settled = try attach(RestoringShellMount.capture(window), "\(name)-settled")
        assertSettled(context, store: store, recorder: recorder, settled: settled)
        RestoringShellMount.unmount(window)
        await RestoringShellMount.settle(200)
    }

    private func mount(
        _ context: CaseContext, auth: DeferredRestoreAuth, store: SessionStore, scheme: ColorScheme
    ) throws -> UIWindow {
        var client: SupabaseClient?
        if context.launch == "stored-session" {
            client = try RestoringShellFixture.stubClient(userID: context.account)
            OnboardingStore().markCompleted(for: context.account)
            RestoringShellFixture.seedTodaysDay()
        }
        let window = try RestoringShellMount.window(
            MorselRootView(
                sessionStore: store, auth: auth, supabaseClient: client,
                mcpEndpoint: RestoringShellFixture.endpoint
            ),
            scheme: scheme
        )
        windows.append(window)
        return window
    }

    /// The case's answer from the stored session: a session, no session, or the
    /// failed token refresh the owner's report is about.
    private func resolve(_ context: CaseContext, auth: DeferredRestoreAuth, store: SessionStore) async {
        switch context.launch {
        case "stored-session":
            auth.release(.success(RestoringShellFixture.session(userID: context.account)))
            let signedIn = await RestoringShellMount.wait(8, until: { store.phase == .signedIn })
            XCTAssertTrue(signedIn, "\(context.label): the stored session resolves")
        case "fresh-install":
            auth.release(.success(nil))
            let routed = await RestoringShellMount.wait(until: { store.phase == .needsSetup })
            XCTAssertTrue(routed, "\(context.label): a fresh install reaches onboarding")
        default:
            auth.release(.failure(URLError(.userAuthenticationRequired)))
            let routed = await RestoringShellMount.wait(until: { store.phase == .needsSignIn })
            XCTAssertTrue(routed, "\(context.label): a failed refresh resolves to sign-in")
        }
    }

    private func assertSettled(
        _ context: CaseContext, store: SessionStore, recorder: PhaseRecorder, settled: Data
    ) {
        let references = context.references
        switch context.launch {
        case "stored-session":
            XCTAssertEqual(store.session?.userID, context.account)
            XCTAssertNil(store.restoreFailure)
            XCTAssertEqual(recorder.phases, [.restoring, .signedIn], "\(context.label): no auth surface")
            XCTAssertNotEqual(settled, references.signIn, "\(context.label): the dashboard is not sign-in")
            XCTAssertNotEqual(settled, references.onboarding, "\(context.label): not onboarding")
            XCTAssertNotEqual(settled, references.skeleton, "\(context.label): the skeleton is replaced")
        case "fresh-install":
            XCTAssertEqual(store.phase, .needsSetup)
            XCTAssertNil(store.restoreFailure)
            XCTAssertEqual(recorder.phases, [.restoring, .needsSetup])
            XCTAssertEqual(settled, references.onboarding, "\(context.label): onboarding settles the shell")
        default:
            XCTAssertEqual(store.restoreFailure, .refreshFailed)
            XCTAssertTrue(store.isSetupDeferred, "\(context.label): the failure resolves to sign-in")
            XCTAssertEqual(
                recorder.phases, [.restoring, .needsSignIn],
                "\(context.label): no onboarding flash between the skeleton and sign-in"
            )
            XCTAssertEqual(settled, references.signIn, "\(context.label): sign-in settles the shell")
        }
    }

    private func references(_ scheme: ColorScheme) async throws -> References {
        let auth = DeferredRestoreAuth()
        return References(
            skeleton: try await reference(RestoringShellSkeleton(), scheme: scheme),
            signIn: try await reference(
                MorselActionTint { SignInView(auth: auth) { _ in } }, scheme: scheme
            ),
            onboarding: try await reference(
                MorselActionTint {
                    OnboardingView(
                        userID: UUID(), endpoint: RestoringShellFixture.endpoint, auth: auth
                    )
                },
                scheme: scheme
            )
        )
    }

    private func reference(_ root: some View, scheme: ColorScheme) async throws -> Data {
        let window = try RestoringShellMount.window(root, scheme: scheme)
        await RestoringShellMount.settle(400)
        let data = try XCTUnwrap(RestoringShellMount.capture(window).pngData())
        RestoringShellMount.unmount(window)
        await RestoringShellMount.settle(150)
        return data
    }

    private func attach(_ image: UIImage, _ name: String) throws -> Data {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("RESTORING_SHELL_CAPTURE_READY \(name)")
        return try XCTUnwrap(image.pngData())
    }
}

/// Records every phase the shell publishes, in order: the failure case's
/// "no onboarding flash" claim is a claim about this sequence.
private final class PhaseRecorder {
    private let lock = NSLock()
    private var recorded: [SessionStore.Phase] = []
    private var cancellable: AnyCancellable?

    @MainActor
    init(_ store: SessionStore) {
        cancellable = store.$phase.sink { [weak self] phase in
            guard let self else { return }
            lock.lock()
            recorded.append(phase)
            lock.unlock()
        }
    }

    var phases: [SessionStore.Phase] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

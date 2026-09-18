import Supabase
import SwiftUI
import XCTest
@testable import Morsel

// Issue #310 — the restoring shell as rendered pixels. The real root view is
// mounted with a deliberately slow restore and every capture is decided against
// the reference surfaces, so "the skeleton is shown and the auth surface is
// not" is answered by what the window painted.

@MainActor
final class RestoringShellRenderTests: XCTestCase {
    private enum Reference {
        case skeleton, signIn, onboarding
    }

    private let account = UUID()
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

    private func parkedAuth() -> DeferredRestoreAuth {
        let auth = DeferredRestoreAuth()
        parked.append(auth)
        return auth
    }

    private func mountShell(
        _ store: SessionStore, auth: DeferredRestoreAuth, scheme: ColorScheme,
        client: SupabaseClient? = nil
    ) throws -> UIWindow {
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

    private func capturePNG(_ window: UIWindow) throws -> Data {
        try XCTUnwrap(RestoringShellMount.capture(window).pngData())
    }

    /// Mounts a reference surface exactly the way the shell mounts it, captures
    /// it and unmounts it, so the shell mount is the only window left.
    private func referenceCapture(_ reference: Reference, scheme: ColorScheme) async throws -> Data {
        let signInAuth = parkedAuth()
        let account = self.account
        let root: AnyView
        switch reference {
        case .skeleton:
            root = AnyView(RestoringShellSkeleton())
        case .signIn:
            root = AnyView(MorselActionTint { SignInView(auth: signInAuth) { _ in } })
        case .onboarding:
            root = AnyView(MorselActionTint {
                OnboardingView(
                    userID: account, endpoint: RestoringShellFixture.endpoint, auth: signInAuth
                )
            })
        }
        let window = try RestoringShellMount.window(root, scheme: scheme)
        await RestoringShellMount.settle(400)
        let data = try capturePNG(window)
        RestoringShellMount.unmount(window)
        await RestoringShellMount.settle(150)
        return data
    }

    func testDeferredRestoreRendersTheSkeletonAndNeverAnAuthSurface() async throws {
        let skeleton = try await referenceCapture(.skeleton, scheme: .light)
        let signIn = try await referenceCapture(.signIn, scheme: .light)
        let onboarding = try await referenceCapture(.onboarding, scheme: .light)

        let auth = parkedAuth()
        let store = SessionStore()
        let window = try mountShell(store, auth: auth, scheme: .light)
        let reached = await RestoringShellMount.wait(until: { auth.isParked })
        XCTAssertTrue(reached, "the attempt must reach the restore transport")
        await RestoringShellMount.settle(400)

        XCTAssertEqual(store.phase, .restoring)
        XCTAssertNil(store.session, "the stored session has not answered yet")
        let captured = try capturePNG(window)
        XCTAssertEqual(captured, skeleton, "the rendered surface IS the paper skeleton")
        XCTAssertNotEqual(captured, signIn, "the sign-in surface must not be on screen")
        XCTAssertNotEqual(captured, onboarding, "the onboarding surface must not be on screen")
    }

    func testTheSkeletonIsTheRenderedSurfaceForTheWholeRestoreWindow() async throws {
        let skeleton = try await referenceCapture(.skeleton, scheme: .light)

        let auth = parkedAuth()
        let store = SessionStore()
        let client = try RestoringShellFixture.stubClient(userID: account)
        OnboardingStore().markCompleted(for: account)
        RestoringShellFixture.seedTodaysDay()
        let window = try mountShell(store, auth: auth, scheme: .light, client: client)
        let reached = await RestoringShellMount.wait(until: { auth.isParked })
        XCTAssertTrue(reached, "the attempt must reach the restore transport")

        var samples: [Data] = []
        for sample in 1...3 {
            await RestoringShellMount.settle(250)
            XCTAssertEqual(store.phase, .restoring, "sample \(sample) is still the restoring window")
            samples.append(try capturePNG(window))
        }
        for (index, sample) in samples.enumerated() {
            XCTAssertEqual(
                sample, skeleton,
                "sample \(index + 1) is the skeleton — the placeholder is the whole window, not a maybe-frame"
            )
        }

        auth.release(.success(RestoringShellFixture.session(userID: account)))
        let settled = await RestoringShellMount.wait(8, until: { store.phase == .signedIn })
        XCTAssertTrue(settled, "the attempt resolves once the stored session answers")
        await RestoringShellMount.settle(700)
        let dashboard = try capturePNG(window)
        let signIn = try await referenceCapture(.signIn, scheme: .light)
        XCTAssertNotEqual(dashboard, skeleton, "the shell moves on from the skeleton")
        XCTAssertNotEqual(dashboard, signIn, "the settled shell is the dashboard, not an auth surface")
    }

    func testFreshInstallReachesOnboardingAndDeferredSetupReachesSignIn() async throws {
        let onboarding = try await referenceCapture(.onboarding, scheme: .light)
        let signIn = try await referenceCapture(.signIn, scheme: .light)
        let skeleton = try await referenceCapture(.skeleton, scheme: .light)

        let freshAuth = parkedAuth()
        let fresh = SessionStore()
        let freshWindow = try mountShell(fresh, auth: freshAuth, scheme: .light)
        let freshReached = await RestoringShellMount.wait(until: { freshAuth.isParked })
        XCTAssertTrue(freshReached)
        freshAuth.release(.success(nil))
        let freshResolved = await RestoringShellMount.wait(until: { fresh.phase == .needsSetup })
        XCTAssertTrue(freshResolved, "a fresh install resolves out of the skeleton")
        await RestoringShellMount.settle(600)
        let freshCapture = try capturePNG(freshWindow)
        XCTAssertEqual(freshCapture, onboarding, "a fresh install still reaches onboarding")
        XCTAssertNotEqual(freshCapture, skeleton, "the skeleton is never permanent")

        let deferredAuth = parkedAuth()
        let deferred = SessionStore()
        deferred.deferSetup()
        let deferredWindow = try mountShell(deferred, auth: deferredAuth, scheme: .light)
        let deferredReached = await RestoringShellMount.wait(until: { deferredAuth.isParked })
        XCTAssertTrue(deferredReached)
        deferredAuth.release(.success(nil))
        let deferredResolved = await RestoringShellMount.wait(until: { deferred.phase == .needsSignIn })
        XCTAssertTrue(deferredResolved, "a deferred setup resolves out of the skeleton")
        await RestoringShellMount.settle(600)
        let deferredCapture = try capturePNG(deferredWindow)
        XCTAssertEqual(deferredCapture, signIn, "a previously deferred setup reaches sign-in")
    }
}

// MARK: - The skeleton's own paint (issue #310 AC5)

@MainActor
final class RestoringShellSkeletonPaintTests: XCTestCase {
    private struct ThemeCase {
        let name: String
        let scheme: ColorScheme
        let ground: RGB
    }

    private let themes = [
        ThemeCase(name: "paper", scheme: .light, ground: RGB(red: 255, green: 247, blue: 232)),
        ThemeCase(name: "night", scheme: .dark, ground: RGB(red: 42, green: 38, blue: 31))
    ]
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            RestoringShellMount.unmount(window)
        }
        windows = []
        await RestoringShellMount.settle(300)
        try await super.tearDown()
    }

    /// The pixel probes below read bands from the BOTTOM edge; this control
    /// pins the orientation so a flipped probe cannot pass vacuously.
    func testPixelProbeReadsTheTopRowFirst() async throws {
        let window = try RestoringShellMount.window(
            VStack(spacing: 0) { Color.red; Color.blue }, scheme: .light
        )
        windows.append(window)
        await RestoringShellMount.settle(400)
        let grid = try XCTUnwrap(PixelGrid(RestoringShellMount.capture(window)))
        let nearTop = grid.pixel(column: grid.width / 2, row: grid.height / 4)
        let nearBottom = grid.pixel(column: grid.width / 2, row: grid.height * 3 / 4)
        print(
            "RESTORING_SHELL_PIXEL_CONTROL top=\(nearTop.red),\(nearTop.green),\(nearTop.blue) "
                + "bottom=\(nearBottom.red),\(nearBottom.green),\(nearBottom.blue) "
                + "size=\(grid.width)x\(grid.height)"
        )
        XCTAssertGreaterThan(nearTop.red, 200, "a quarter down must be the capture's TOP half")
        XCTAssertLessThan(nearTop.blue, 80)
        XCTAssertGreaterThan(nearBottom.blue, 200, "three quarters down must be the BOTTOM half")
        XCTAssertLessThan(nearBottom.red, 80)
    }

    func testTheSkeletonPaintsThePaperGroundInBothThemesWithoutATabBar() async throws {
        var captures: [String: Data] = [:]
        for theme in themes {
            let window = try RestoringShellMount.window(RestoringShellSkeleton(), scheme: theme.scheme)
            windows.append(window)
            await RestoringShellMount.settle(400)
            let image = RestoringShellMount.capture(window)
            let grid = try XCTUnwrap(PixelGrid(image))
            let dominant = grid.dominantColor(fromBottom: grid.height)
            XCTAssertTrue(
                dominant.close(to: theme.ground, within: 12),
                "\(theme.name): the restoring surface sits on the journal's background token"
            )
            XCTAssertEqual(
                grid.contrastingPixelCount(fromBottom: 210, ground: theme.ground), 0,
                "\(theme.name): the tab bar's seat is empty on the restoring surface"
            )
            captures[theme.name] = try XCTUnwrap(image.pngData())
        }
        XCTAssertNotEqual(captures["paper"], captures["night"], "Paper and Night are genuinely different")
    }

    /// The discriminating control for the assertion above: the same probe must
    /// find the bar when a bar is actually there.
    func testTheTabBarOracleBitesOnARealBar() async throws {
        let window = try RestoringShellMount.window(
            VStack(spacing: 0) {
                RestoringShellSkeleton()
                JournalTabBar(pager: JournalPagerModel())
            },
            scheme: .light
        )
        windows.append(window)
        await RestoringShellMount.settle(400)
        let grid = try XCTUnwrap(PixelGrid(RestoringShellMount.capture(window)))
        XCTAssertGreaterThan(
            grid.contrastingPixelCount(fromBottom: 210, ground: themes[0].ground), 0,
            "the oracle must see a real tab bar"
        )
    }
}

import XCTest
@testable import Morsel

final class OnboardingTests: XCTestCase {
    func testChatPromptReplacesEndpointWithoutLeavingPlaceholder() {
        let endpoint = "https://mcp.example.test/mcp"
        let prompt = OnboardingContent.prompt(OnboardingContent.chatPrompt, endpoint: endpoint)

        XCTAssertTrue(prompt.contains(endpoint))
        XCTAssertFalse(prompt.contains("{{MCP_URL}}"))
        XCTAssertTrue(prompt.contains("get_profile"))
        XCTAssertTrue(prompt.contains("one photo = one"))
        XCTAssertEqual(OnboardingContent.signedInMarker, "Signed in ✓")
    }

    func testDefaultSetupGuidanceIsClientNeutral() throws {
        // Issue #57: the default prompt must work for any MCP client — name the
        // client's own MCP/connector field, OAuth sign-in, and get_profile —
        // without Claude-specific paths or invented mobile/plugin capabilities.
        let prompt = OnboardingContent.prompt(
            OnboardingContent.chatPrompt,
            endpoint: "https://mcp.example.test/mcp"
        )
        XCTAssertTrue(
            prompt.contains("MCP/connector settings"),
            "Default guidance must name a neutral custom-connector field"
        )
        XCTAssertTrue(prompt.contains("get_profile"), "Default guidance must include the verification call")
        XCTAssertFalse(
            prompt.lowercased().contains("claude"),
            "Default guidance must not require a Claude-only path"
        )

        // Vendor-specific flows remain available but only as clearly labeled
        // optional instructions on their own tabs.
        XCTAssertTrue(OnboardingContent.claudeCodePrompt.hasPrefix("Set up Morsel food tracking with Claude Code."))
        XCTAssertTrue(OnboardingContent.claudeDesktopPrompt.hasPrefix("Connect Morsel in Claude Desktop."))
    }

    func testEndpointConfigurationRejectsEmptyAndNonHTTPSValues() {
        XCTAssertNil(OnboardingEndpoint(configuredValue: ""))
        XCTAssertNil(OnboardingEndpoint(configuredValue: "http://mcp.example.test/mcp"))
        XCTAssertEqual(
            OnboardingEndpoint(configuredValue: " https://mcp.example.test/mcp ")?.value,
            "https://mcp.example.test/mcp"
        )
    }

    func testCopyPayloadRequiresValidConfiguredEndpoint() {
        let endpoint = OnboardingEndpoint(configuredValue: "https://mcp.example.test/mcp")
        guard let endpoint else {
            return XCTFail("Expected a valid endpoint")
        }
        XCTAssertTrue(
            OnboardingContent.prompt(OnboardingContent.chatPrompt, endpoint: endpoint.value)
                .contains(endpoint.value)
        )
        XCTAssertNil(OnboardingEndpoint(configuredValue: ""))
    }

    func testEachPlatformHasDistinctInstructions() {
        XCTAssertTrue(OnboardingContent.instructions(for: "Custom MCP").contains("custom MCP/connector field"))
        XCTAssertTrue(OnboardingContent.instructions(for: "Claude.ai").contains("Optional Claude.ai flow"))
        XCTAssertTrue(OnboardingContent.instructions(for: "Claude Desktop").contains("Claude Desktop"))
        XCTAssertTrue(OnboardingContent.instructions(for: "ChatGPT").contains("Optional ChatGPT flow"))
        XCTAssertTrue(OnboardingContent.instructions(for: "Claude Code").contains("Claude Code"))
    }

    func testDefaultPlatformIsClientNeutralCustomMcp() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel/Onboarding.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let stateStart = try XCTUnwrap(source.range(of: "@State private var platform"))
        let stateLine = String(source[stateStart.lowerBound..<source.index(stateStart.lowerBound, offsetBy: 90)])
        XCTAssertTrue(
            stateLine.contains("OnboardingPlatform.custom"),
            "Default onboarding platform must be the client-neutral Custom MCP option"
        )
        XCTAssertTrue(source.contains("case custom = \"Custom MCP\""))
    }

    func testUnauthenticatedSignInCannotAdvance() {
        var state = OnboardingState()

        XCTAssertFalse(state.authenticationSucceeded(nil))
        XCTAssertEqual(state.step, .signIn)
        XCTAssertNil(state.session)
    }

    func testDoneRequiresExplicitConfirmationEdge() {
        var state = OnboardingState()
        let session = AuthenticatedSession(userID: UUID(), email: "test@example.com")

        XCTAssertTrue(state.authenticationSucceeded(session))
        XCTAssertEqual(state.step, .signedIn)
        XCTAssertTrue(state.proceedToConnect())
        XCTAssertTrue(state.proceedToCoach())
        XCTAssertTrue(state.proceedToConfirm())
        XCTAssertFalse(state.confirmed)
        XCTAssertNotEqual(state.step, .done)

        XCTAssertTrue(state.confirmConnection())

        XCTAssertTrue(state.confirmed)
        XCTAssertEqual(state.step, .done)
    }

    func testIllegalEdgesDoNotAdvanceOrReachDone() {
        var state = OnboardingState()
        let session = AuthenticatedSession(userID: UUID(), email: nil)

        XCTAssertFalse(state.proceedToCoach())
        XCTAssertFalse(state.confirmConnection())
        XCTAssertTrue(state.authenticationSucceeded(session))
        XCTAssertFalse(state.proceedToConfirm())
        XCTAssertNotEqual(state.step, .done)
    }

    func testCoachContinueUsesGuardedTransitionCallSite() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel/Onboarding.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Button(\"Continue\") { _ = state.proceedToConfirm() }"))
        XCTAssertFalse(source.contains("Button(\"Continue\") { state.step = .done }"))
    }

    func testConfirmActionLeavesCompletionToDoneAction() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel/Onboarding.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let confirmStart = try XCTUnwrap(source.range(of: "private var confirmContent"))
        let doneStart = try XCTUnwrap(source.range(of: "private var doneContent"))
        let confirmSource = String(source[confirmStart.lowerBound..<doneStart.lowerBound])
        let doneSource = String(source[doneStart.lowerBound...])

        XCTAssertTrue(confirmSource.contains("confirmConnection()"))
        XCTAssertFalse(confirmSource.contains("onFinished()"))
        XCTAssertTrue(doneSource.contains("Button(\"Open today's log\")"))
        XCTAssertTrue(doneSource.contains("onFinished()"))
    }

    func testClaudeCodePromptKeepsFullTemplateAndEndpoint() {
        let prompt = OnboardingContent.prompt(
            OnboardingContent.claudeCodePrompt,
            endpoint: "https://mcp.example.test/mcp"
        )

        XCTAssertEqual(prompt.components(separatedBy: "\n").count, 5)
        XCTAssertTrue(prompt.contains(
            "claude mcp add --transport http morsel https://mcp.example.test/mcp"
        ))
        XCTAssertTrue(prompt.contains("Complete the OAuth browser sign-in"))
    }

    // MARK: - Issue #57 source contracts (canonical endpoint source, no stale alias copy)

    func testOnboardingCopyNeverPublishesTheNestedCompatibilityAlias() throws {
        // The /mcp/mcp nested path is a protocol-level compatibility alias only:
        // no user-facing onboarding copy may hand it to clients as the endpoint.
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel/Onboarding.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("/mcp/mcp"),
            "Onboarding copy must never reference the nested compatibility alias"
        )
        // The endpoint card and copy payload render the single configured value.
        XCTAssertTrue(source.contains("OnboardingEndpoint(configuredValue: endpoint)"))
    }

    func testConnectStepNamesNeutralCustomConnectorFieldAndVerification() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel/Onboarding.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let connectStart = try XCTUnwrap(source.range(of: "private var connectContent"))
        let coachStart = try XCTUnwrap(source.range(of: "private var coachContent"))
        let connectSource = String(source[connectStart.lowerBound..<coachStart.lowerBound])

        XCTAssertTrue(
            connectSource.contains("any MCP client's custom connector field"),
            "The connect step must present the endpoint as a neutral MCP-client URL"
        )
        XCTAssertTrue(
            connectSource.contains("get_profile"),
            "The connect step must tell the user how to verify the connection"
        )
    }

    @MainActor
    func testInitialSkipExposesHonestSignInStateWithoutInventingSession() {
        let sessionStore = SessionStore()

        XCTAssertNil(sessionStore.session)
        XCTAssertEqual(sessionStore.pendingRoute, .initialSetup)
        XCTAssertFalse(sessionStore.isSetupDeferred)

        sessionStore.deferSetup()

        XCTAssertEqual(sessionStore.pendingRoute, .setupDeferred)
        XCTAssertTrue(sessionStore.isSetupDeferred)
        XCTAssertNil(sessionStore.session, "Skipping initial setup must not invent a session")
    }

    func testRootViewWiresInitialSkipToExplicitDeferredRoute() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel/MorselApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let storeStart = try XCTUnwrap(
            source.range(of: "final class SessionStore"),
            "Expected the SessionStore declaration in MorselApp.swift"
        )
        let rootStart = try XCTUnwrap(
            source.range(of: "private struct MorselRootView", range: storeStart.upperBound..<source.endIndex),
            "Expected MorselRootView after SessionStore in MorselApp.swift"
        )
        let initialCallStart = try XCTUnwrap(
            source.range(of: "userID: pendingSession?.userID ?? UUID()", range: rootStart.upperBound..<source.endIndex),
            "Expected the initial no-session OnboardingView call in MorselRootView"
        )

        XCTAssertTrue(
            source.contains("OnboardingStore().markCompleted(for: viewModel.userID)"),
            "Signed-in onboarding must keep its completion persistence"
        )
        XCTAssertEqual(
            source.components(separatedBy: "sessionStore.deferSetup()").count - 1, 1,
            "Exactly one load-bearing initial-skip transition is expected"
        )
        XCTAssertTrue(
            source[initialCallStart.lowerBound..<source.endIndex].contains("sessionStore.deferSetup()"),
            "The initial no-session onboarding must defer setup instead of the default no-op"
        )
    }

    func testOnboardingStoreShowsOnceAndCanBeReplayed() {
        let suiteName = "OnboardingTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Expected isolated defaults")
        }
        let store = OnboardingStore(defaults: defaults)
        let userID = UUID()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(store.hasCompleted(for: userID))
        store.markCompleted(for: userID)
        XCTAssertTrue(store.hasCompleted(for: userID))
        store.reset(for: userID)
        XCTAssertFalse(store.hasCompleted(for: userID))
    }
}

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
        XCTAssertTrue(OnboardingContent.instructions(for: "Claude.ai").contains("Customize → Connectors"))
        XCTAssertTrue(OnboardingContent.instructions(for: "Claude Desktop").contains("Claude Desktop"))
        XCTAssertTrue(OnboardingContent.instructions(for: "ChatGPT").contains("Settings → Apps → Create"))
        XCTAssertTrue(OnboardingContent.instructions(for: "Claude Code").contains("Claude Code"))
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

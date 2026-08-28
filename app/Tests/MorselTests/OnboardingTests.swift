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

    func testDoneRequiresExplicitConfirmationAction() {
        var state = OnboardingState()
        state.step = .coach

        XCTAssertFalse(state.confirmed)
        XCTAssertNotEqual(state.step, .done)

        state.confirmConnection()

        XCTAssertTrue(state.confirmed)
        XCTAssertEqual(state.step, .done)
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

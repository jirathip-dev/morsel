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

    func testDoneDetectionUsesUserWriteAfterOnboardingStarted() {
        let started = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(OnboardingDetection(
            updatedAt: nil, manualConfirmation: false, startedAt: started
        ).isConnected)
        XCTAssertFalse(OnboardingDetection(
            updatedAt: started, manualConfirmation: false, startedAt: started
        ).isConnected)
        XCTAssertTrue(OnboardingDetection(
            updatedAt: Date(timeIntervalSince1970: 101), manualConfirmation: false, startedAt: started
        ).isConnected)
    }

    func testDoneDetectionDegradesToManualConfirmation() {
        let detection = OnboardingDetection(
            updatedAt: nil,
            manualConfirmation: true,
            startedAt: Date()
        )

        XCTAssertTrue(detection.isConnected)
    }

    func testOnboardingStoreShowsOnceAndCanBeReplayed() {
        let suiteName = "OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
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

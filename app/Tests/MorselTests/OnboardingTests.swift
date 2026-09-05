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
        let sourceRoot = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel")
        let shellSource = try String(contentsOf: sourceRoot.appendingPathComponent("MorselApp.swift"), encoding: .utf8)
        let storeSource = try String(contentsOf: sourceRoot.appendingPathComponent("SessionStore.swift"), encoding: .utf8)
        XCTAssertTrue(
            storeSource.contains("final class SessionStore: ObservableObject"),
            "Expected the SessionStore declaration in SessionStore.swift"
        )
        let rootStart = try XCTUnwrap(
            shellSource.range(of: "private struct MorselRootView"),
            "Expected MorselRootView in MorselApp.swift"
        )
        let initialCallStart = try XCTUnwrap(
            shellSource.range(of: "userID: pendingSession?.userID ?? UUID()", range: rootStart.upperBound..<shellSource.endIndex),
            "Expected the initial no-session OnboardingView call in MorselRootView"
        )

        XCTAssertTrue(
            shellSource.contains("OnboardingStore().markCompleted(for: viewModel.userID)"),
            "Signed-in onboarding must keep its completion persistence"
        )
        XCTAssertEqual(
            shellSource.components(separatedBy: "sessionStore.deferSetup()").count - 1, 1,
            "Exactly one load-bearing initial-skip transition is expected"
        )
        XCTAssertTrue(
            shellSource[initialCallStart.lowerBound..<shellSource.endIndex].contains("sessionStore.deferSetup()"),
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

// MARK: - Issue #75 platform contract (three choices, unified guidance, retired labels)

final class OnboardingPlatformContractTests: XCTestCase {
    func testNeutralSetupPromptNamesNoClaudeOnlyPath() throws {
        // Issue #57: the neutral prompt must work for any MCP client — name the
        // client's own MCP/connector field, OAuth sign-in, and get_profile —
        // without Claude-specific paths or invented mobile/plugin capabilities.
        // Issue #75: it is the shared setup prompt for ChatGPT and Others.
        let prompt = OnboardingContent.prompt(
            OnboardingContent.chatPrompt,
            endpoint: "https://mcp.example.test/mcp"
        )
        XCTAssertTrue(
            prompt.contains("MCP/connector settings"),
            "Neutral guidance must name a neutral custom-connector field"
        )
        XCTAssertTrue(prompt.contains("get_profile"), "Neutral guidance must include the verification call")
        XCTAssertFalse(
            prompt.lowercased().contains("claude"),
            "Neutral guidance must not require a Claude-only path"
        )
        XCTAssertFalse(prompt.contains("{{MCP_URL}}"))
    }

    func testPerClientGuidanceIsUnified() {
        // Issue #75: each of the three clients has exactly ONE guidance set —
        // the unified Claude story, the ChatGPT Apps flow, and a neutral
        // Others path — all pointing at the same endpoint card above them.
        let claudeInstructions = OnboardingContent.instructions(for: "Claude")
        XCTAssertTrue(claudeInstructions.contains("Customize → Connectors"))
        XCTAssertTrue(claudeInstructions.contains("add custom connector"))
        XCTAssertFalse(claudeInstructions.contains("{{MCP_URL}}"))

        let chatGPTInstructions = OnboardingContent.instructions(for: "ChatGPT")
        XCTAssertTrue(chatGPTInstructions.contains("Apps"))
        XCTAssertFalse(chatGPTInstructions.contains("{{MCP_URL}}"))

        let othersInstructions = OnboardingContent.instructions(for: "Others")
        XCTAssertTrue(othersInstructions.contains("MCP-capable client"))
        XCTAssertTrue(othersInstructions.contains("custom MCP/connector field"))
        XCTAssertTrue(othersInstructions.contains("get_profile"))
        XCTAssertFalse(othersInstructions.contains("{{MCP_URL}}"))
    }

    func testOnboardingPlatformsAreExactlyThreeUnifiedChoices() throws {
        // Issue #75: the segmented chooser offers exactly Claude / ChatGPT /
        // Others — one story per client, no duplicate product tabs.
        XCTAssertEqual(
            OnboardingPlatform.allCases.map(\.rawValue),
            ["Claude", "ChatGPT", "Others"]
        )

        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel/Onboarding.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let stateStart = try XCTUnwrap(source.range(of: "@State private var platform"))
        let stateLine = String(source[stateStart.lowerBound..<source.index(stateStart.lowerBound, offsetBy: 90)])
        XCTAssertTrue(
            stateLine.contains("OnboardingPlatform.claude"),
            "Default onboarding platform must be the unified Claude choice"
        )
        XCTAssertTrue(source.contains("case claude = \"Claude\""))
        XCTAssertTrue(source.contains("case chatGPT = \"ChatGPT\""))
        XCTAssertTrue(source.contains("case others = \"Others\""))
    }

    func testClaudeUnifiedPromptEmbedsEndpointInConnectorAndCliLine() {
        // Issue #75: the single Claude prompt covers the app-or-web connector
        // flow and carries the optional CLI line; both URL occurrences derive
        // from the same configured endpoint.
        let endpoint = "https://mcp.example.test/mcp"
        let prompt = OnboardingContent.prompt(
            OnboardingContent.claudePrompt,
            endpoint: endpoint
        )

        XCTAssertEqual(
            prompt.components(separatedBy: endpoint).count - 1, 2,
            "The unified Claude prompt must publish the endpoint in the connector step and the CLI line"
        )
        XCTAssertTrue(prompt.contains("claude mcp add --transport http morsel \(endpoint)"))
        XCTAssertTrue(prompt.contains("Customize → Connectors"))
        XCTAssertTrue(prompt.contains("Complete the OAuth browser sign-in"))
        XCTAssertFalse(prompt.contains("{{MCP_URL}}"))
    }

    func testEveryGeneratedPromptPublishesTheSameConfiguredEndpoint() {
        // Issue #75: every client prompt derives from the SAME configured
        // endpoint through the {{MCP_URL}} path — no per-client URL literals.
        let endpoint = "https://mcp.example.test/mcp"
        let templates = [OnboardingContent.chatPrompt, OnboardingContent.claudePrompt]
        for template in templates {
            XCTAssertTrue(template.contains("{{MCP_URL}}"))
            let prompt = OnboardingContent.prompt(template, endpoint: endpoint)
            XCTAssertTrue(prompt.contains(endpoint))
            XCTAssertFalse(prompt.contains("{{MCP_URL}}"))
        }
        XCTAssertFalse(OnboardingContent.chatPrompt.contains("https://"))
        XCTAssertFalse(OnboardingContent.claudePrompt.contains("https://"))
    }

    func testOnboardingCopyRetiresPerProductDuplicateLabels() throws {
        // Issue #75: none of the retired duplicate platform labels may appear
        // anywhere in the onboarding source — as tabs, guidance, or prompts.
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Morsel/Onboarding.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for label in ["Custom MCP", "Claude.ai", "Claude Desktop", "Claude Code"] {
            XCTAssertFalse(source.contains(label), "Retired onboarding label must not appear: \(label)")
        }
    }
}

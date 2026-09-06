import XCTest
@testable import Morsel

// Issue #141 — the onboarding connect screen's endpoint copy control must put
// EXACTLY the configured MCP endpoint (trimmed, no trailing whitespace or
// newline) on the pasteboard — never the setup prompt — and render as a paper
// 'Copy' pill (token colors, no system blue) with a brief confirmation.

@MainActor
final class EndpointCopyTests: XCTestCase {
    private func sourceRoot() throws -> URL {
        let testURL = URL(fileURLWithPath: #filePath)
        return testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func onboardingSource() throws -> String {
        try String(
            contentsOf: sourceRoot().appendingPathComponent("Sources/Morsel/Onboarding.swift"),
            encoding: .utf8
        )
    }

    func testCopyPayloadIsExactlyTheTrimmedEndpointWithoutWhitespace() throws {
        // The issue's canonical endpoint, entered with surrounding noise: the
        // string builder (OnboardingEndpoint) trims and the copy helper
        // publishes the bare value — never the prompt, never newlines.
        let endpoint = try XCTUnwrap(
            OnboardingEndpoint(configuredValue: "  https://mcp.morselfood.app/mcp\n")
        )
        let previous = UIPasteboard.general.string
        defer { UIPasteboard.general.string = previous }

        OnboardingContent.copyToPasteboard(endpoint.value)

        let pasted = UIPasteboard.general.string
        XCTAssertEqual(pasted, "https://mcp.morselfood.app/mcp")
        XCTAssertFalse(pasted?.hasSuffix("\n") ?? false)
        XCTAssertFalse(pasted?.hasSuffix(" ") ?? false)
        XCTAssertFalse(pasted?.contains("connector") ?? true, "the prompt must not be copied")
    }

    func testCopyPillWiringLivesInTheConnectStepEndpointField() throws {
        let source = try onboardingSource()
        let connectStart = try XCTUnwrap(source.range(of: "private var connectContent"))
        let coachStart = try XCTUnwrap(source.range(of: "private var coachContent"))
        let connectSource = String(source[connectStart.lowerBound..<coachStart.lowerBound])
        let fieldStart = try XCTUnwrap(connectSource.range(of: "private func endpointField"))
        let fieldEnd = try XCTUnwrap(connectSource.range(of: "private func prompt("))
        let fieldSource = String(connectSource[fieldStart.lowerBound..<fieldEnd.lowerBound])

        XCTAssertTrue(connectSource.contains("endpointField(endpointValue)"))
        XCTAssertTrue(fieldSource.contains("OnboardingContent.copyToPasteboard(value)"))
        XCTAssertTrue(fieldSource.contains("didCopyEndpoint = true"))
        XCTAssertTrue(fieldSource.contains("didCopyEndpoint ? \"Copied ✓\" : \"Copy\""))
        XCTAssertTrue(fieldSource.contains("accessibilityLabel(\"Copy MCP endpoint URL\")"))
        XCTAssertTrue(fieldSource.contains(".task(id: didCopyEndpoint)"))
    }

    func testCopyPillUsesPaperTokensAndNoSystemBlue() throws {
        let source = try onboardingSource()
        let connectStart = try XCTUnwrap(source.range(of: "private var connectContent"))
        let coachStart = try XCTUnwrap(source.range(of: "private var coachContent"))
        let connectSource = String(source[connectStart.lowerBound..<coachStart.lowerBound])

        XCTAssertTrue(connectSource.contains("Color.morselForest"))
        XCTAssertTrue(connectSource.contains("Color.morselSurface"))
        XCTAssertTrue(connectSource.contains("Color.morselInkLine"))
        XCTAssertFalse(connectSource.contains("Color.blue"))
        XCTAssertFalse(connectSource.contains(".tint("))
    }

    func testCopySetupPromptStaysDistinctFromEndpointCopy() throws {
        let source = try onboardingSource()
        let connectStart = try XCTUnwrap(source.range(of: "private var connectContent"))
        let coachStart = try XCTUnwrap(source.range(of: "private var coachContent"))
        let connectSource = String(source[connectStart.lowerBound..<coachStart.lowerBound])

        XCTAssertTrue(connectSource.contains("Copy setup prompt"))
        XCTAssertTrue(connectSource.contains("didCopy ? \"Copied ✓\" : \"Copy setup prompt\""))
        XCTAssertTrue(connectSource.contains("didCopy = true"))
        // The prompt copy payload is the full prompt; the endpoint pill copies
        // the bare endpoint value — two distinct actions, two distinct flags.
        XCTAssertTrue(
            connectSource.contains(
                "OnboardingContent.copyToPasteboard(prompt(for: platform, endpoint: endpointValue))"
            )
        )
    }

    func testNoEndpointUrlLiteralIsHardcodedInOnboardingSource() throws {
        // The endpoint always arrives from the configured build value through
        // OnboardingEndpoint — the copy control never hardcodes the URL.
        let source = try onboardingSource()
        XCTAssertFalse(source.contains("https://"))
    }
}

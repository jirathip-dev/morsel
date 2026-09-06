import XCTest
@testable import Morsel

// Issue #141/#151 — the endpoint copy control must put EXACTLY the configured
// MCP endpoint (trimmed, no trailing whitespace or newline) on the pasteboard
// — never the setup prompt — and render as a paper 'Copy' pill (token colors,
// no system blue) with a brief confirmation. #151 extracted the pill chrome
// into the SHARED EndpointCopyPill (one implementation, one pasteboard write
// through OnboardingContent.copyToPasteboard) and added it to the Settings
// MCP endpoint row; onboarding's connect step keeps the same behavior.

@MainActor
final class EndpointCopyTests: XCTestCase {
    private func sourceRoot() throws -> URL {
        let testURL = URL(fileURLWithPath: #filePath)
        return testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceFile(_ name: String) throws -> String {
        try String(
            contentsOf: sourceRoot().appendingPathComponent("Sources/Morsel/\(name)"),
            encoding: .utf8
        )
    }

    private func onboardingSource() throws -> String {
        try sourceFile("Onboarding.swift")
    }

    private func pillSource() throws -> String {
        try sourceFile("EndpointCopyPill.swift")
    }

    private func settingsSource() throws -> String {
        try sourceFile("SettingsView.swift")
    }

    private func connectContentSource() throws -> String {
        let source = try onboardingSource()
        let connectStart = try XCTUnwrap(source.range(of: "private var connectContent"))
        let coachStart = try XCTUnwrap(source.range(of: "private var coachContent"))
        return String(source[connectStart.lowerBound..<coachStart.lowerBound])
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
        // The connect step embeds the SHARED pill for the trimmed endpoint
        // value (the #141 wiring: endpointField(endpointValue) in the connect
        // content, and the field rendering EndpointCopyPill).
        let connectSource = try connectContentSource()
        let fieldStart = try XCTUnwrap(connectSource.range(of: "private func endpointField"))
        let fieldEnd = try XCTUnwrap(connectSource.range(of: "private func prompt("))
        let fieldSource = String(connectSource[fieldStart.lowerBound..<fieldEnd.lowerBound])

        XCTAssertTrue(connectSource.contains("endpointField(endpointValue)"))
        XCTAssertTrue(fieldSource.contains("EndpointCopyPill(value: value)"))
    }

    func testCopyPillUsesPaperTokensAndNoSystemBlue() throws {
        // The pill chrome lives in ONE place (EndpointCopyPill.swift): paper
        // tokens only, no system blue, no tint override — in the shared pill
        // AND in the onboarding connect slice that embeds it.
        let pill = try pillSource()
        XCTAssertTrue(pill.contains("Color.morselForest"))
        XCTAssertTrue(pill.contains("Color.morselSurface"))
        XCTAssertTrue(pill.contains("Color.morselInkLine"))
        XCTAssertFalse(pill.contains("Color.blue"))
        XCTAssertFalse(pill.contains(".tint("))

        let connectSource = try connectContentSource()
        XCTAssertFalse(connectSource.contains("Color.blue"))
        XCTAssertFalse(connectSource.contains(".tint("))
    }

    func testCopySetupPromptStaysDistinctFromEndpointCopy() throws {
        // The prompt-copy action (with its own didCopy flag) stays in the
        // connect content; the endpoint pill copies the bare endpoint value —
        // two distinct actions, two distinct flags.
        let connectSource = try connectContentSource()

        XCTAssertTrue(connectSource.contains("Copy setup prompt"))
        XCTAssertTrue(connectSource.contains("didCopy ? \"Copied ✓\" : \"Copy setup prompt\""))
        XCTAssertTrue(connectSource.contains("didCopy = true"))
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

    func testSharedEndpointCopyPillIsTheSingleCopyPillImplementation() throws {
        // #151 — one pill implementation owns the endpoint copy: the shared
        // helper write, the 1.5 s 'Copied ✓' state, the a11y label, and the
        // paper chrome. It must pass the value through untrimmed (the exact
        // configured string, byte-exact) and never hardcode the URL.
        let pill = try pillSource()
        XCTAssertTrue(pill.contains("OnboardingContent.copyToPasteboard(value)"))
        XCTAssertTrue(pill.contains("didCopy = true"))
        XCTAssertTrue(pill.contains("didCopy ? \"Copied ✓\" : \"Copy\""))
        XCTAssertTrue(pill.contains("accessibilityLabel(\"Copy MCP endpoint URL\")"))
        XCTAssertTrue(pill.contains(".task(id: didCopy)"))
        XCTAssertTrue(pill.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(pill.contains("trimmingCharacters"))
        XCTAssertFalse(pill.contains("https://"))
    }

    func testSettingsMCPEndpointRowUsesTheSharedPillForTheConfiguredValue() throws {
        // #151 — the Settings MCP endpoint row embeds the SAME shared pill
        // for the configured mcpEndpoint value (no duplicate chrome, no local
        // pasteboard write, no URL literal), and shows no copy control in the
        // unconfigured branch — placeholder first, pill only after 'else'.
        let settings = try settingsSource()
        let sectionStart = try XCTUnwrap(settings.range(of: "private var mcpSection"))
        let sectionEnd = try XCTUnwrap(settings.range(of: "private var replayRow"))
        let section = String(settings[sectionStart.lowerBound..<sectionEnd.lowerBound])

        let placeholderRange = try XCTUnwrap(section.range(of: "MCP endpoint is not configured."))
        let elseRange = try XCTUnwrap(section.range(of: "else {"))
        let pillRange = try XCTUnwrap(section.range(of: "EndpointCopyPill(value: mcpEndpoint)"))
        XCTAssertLessThan(placeholderRange.lowerBound, elseRange.lowerBound)
        XCTAssertLessThan(elseRange.lowerBound, pillRange.lowerBound)

        XCTAssertTrue(section.contains("if mcpEndpoint.isEmpty"))
        XCTAssertTrue(section.contains("Color.morselSurfaceTwo"))
        XCTAssertFalse(section.contains("Color.blue"))
        XCTAssertFalse(section.contains(".tint("))
        // The row only embeds the shared pill — Settings never writes the
        // pasteboard itself and never hardcodes the endpoint URL.
        XCTAssertFalse(settings.contains("UIPasteboard"))
        XCTAssertFalse(settings.contains("https://"))
    }
}

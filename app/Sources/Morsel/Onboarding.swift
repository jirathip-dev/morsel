import Foundation
import SwiftUI
import UIKit

struct OnboardingState: Equatable, Sendable {
    private(set) var step: OnboardingStep
    private(set) var session: AuthenticatedSession?
    private(set) var confirmed = false

    init(session: AuthenticatedSession? = nil) {
        self.session = session
        step = session == nil ? .signIn : .signedIn
    }

    mutating func beginAuthentication() -> Bool { step == .signIn }

    mutating func authenticationSucceeded(_ session: AuthenticatedSession?) -> Bool {
        guard step == .signIn, let session else { return false }
        self.session = session
        step = .signedIn
        return true
    }

    mutating func proceedToConnect() -> Bool {
        guard step == .signedIn, session != nil else { return false }
        step = .connect
        return true
    }

    mutating func proceedToCoach() -> Bool {
        guard step == .connect else { return false }
        step = .coach
        return true
    }

    mutating func proceedToConfirm() -> Bool {
        guard step == .coach else { return false }
        step = .confirm
        return true
    }

    mutating func confirmConnection() -> Bool {
        guard step == .confirm, session != nil else { return false }
        confirmed = true
        step = .done
        return true
    }
}

enum OnboardingStep: Int, CaseIterable, Sendable {
    case signIn = 1
    case signedIn
    case connect
    case coach
    case confirm
    case done
}

enum OnboardingContent {
    // Default setup guidance is client-neutral (issue #57): paste the canonical
    // MCP endpoint into the client's custom MCP/connector field, complete the
    // OAuth browser sign-in, verify with get_profile. Vendor-specific flows
    // stay in the labeled per-platform instructions below.
    static let chatPrompt = """
I use Morsel to track my food. Set yourself up as my food logger.
1. In your MCP/connector settings, add a custom connector with this URL: {{MCP_URL}}
2. When I approve the sign-in, call get_profile to verify the connection.
3. If my profile is empty, ask for my stats (height, weight, age, sex, activity, goal),
   then set_profile + compute_targets.
4. Ask me to send a photo of my next meal; log it with log_meal — one photo = one
   entry, never invent precise macros, tag estimates with confidence.
5. Hereafter log food photos without being asked; answer "how am I doing?" with get_day.
"""

    static let signedInMarker = "Signed in ✓"

    // Optional vendor-specific flow (clearly labeled Claude Code tab).
    static let claudeCodePrompt = """
Set up Morsel food tracking with Claude Code.
1. Add the MCP server: claude mcp add --transport http morsel {{MCP_URL}}
2. Complete the OAuth browser sign-in when it opens.
3. Verify by calling get_profile; if empty, ask me for stats, then set_profile.
4. Confirm: "Morsel connected — send me a photo of your next meal."
"""

    // Optional vendor-specific flow (clearly labeled Claude Desktop tab).
    static let claudeDesktopPrompt = """
Connect Morsel in Claude Desktop.
1. Open Settings → Connectors → Add custom connector.
2. Enter the Morsel MCP server URL: {{MCP_URL}}
3. Complete the OAuth browser sign-in when it opens.
4. Verify by calling get_profile.
"""

    static func prompt(_ template: String, endpoint: String) -> String {
        template.replacingOccurrences(of: "{{MCP_URL}}", with: endpoint)
            .trimmingCharacters(in: .newlines)
    }

    static func instructions(for platform: String) -> String {
        switch platform {
        case "Claude.ai":
            return "Customize → Connectors → + → Add custom connector, then paste this setup prompt."
        case "Claude Desktop":
            return "In Claude Desktop, open Settings → Connectors, add a custom connector, then paste this prompt."
        case "ChatGPT":
            return "Settings → Apps → Create, then add Morsel with this setup prompt."
        default:
            return "Claude Code can install the connector for you."
        }
    }
}

struct OnboardingEndpoint: Equatable, Sendable {
    let value: String

    init?(configuredValue: String) {
        let value = configuredValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "https", url.host != nil else {
            return nil
        }
        self.value = value
    }
}

enum OnboardingPlatform: String, CaseIterable {
    case claude = "Claude.ai"
    case desktop = "Claude Desktop"
    case chatGPT = "ChatGPT"
    case code = "Claude Code"
}

struct OnboardingStore {
    private let defaults: UserDefaults
    private let keyPrefix = "morsel.onboarding.completed."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasCompleted(for userID: UUID) -> Bool {
        defaults.bool(forKey: keyPrefix + userID.uuidString)
    }

    func markCompleted(for userID: UUID) {
        defaults.set(true, forKey: keyPrefix + userID.uuidString)
    }

    func reset(for userID: UUID) {
        defaults.removeObject(forKey: keyPrefix + userID.uuidString)
    }
}

struct OnboardingView: View {
    let userID: UUID
    let endpoint: String
    let onFinished: () -> Void
    let onSkip: () -> Void
    let auth: (any SupabaseAuthenticating)?
    let onAuthenticated: (AuthenticatedSession) -> Void

    @State private var state = OnboardingState()
    @State private var platform = OnboardingPlatform.claude
    @State private var didCopy = false

    init(
        userID: UUID,
        endpoint: String,
        auth: (any SupabaseAuthenticating)? = nil,
        session: AuthenticatedSession? = nil,
        onAuthenticated: @escaping (AuthenticatedSession) -> Void = { _ in },
        onFinished: @escaping () -> Void = {},
        onSkip: @escaping () -> Void = {}
    ) {
        self.userID = userID
        self.endpoint = endpoint
        self.auth = auth
        self.onAuthenticated = onAuthenticated
        self.onFinished = onFinished
        self.onSkip = onSkip
        _state = State(initialValue: OnboardingState(session: session))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("morsel")
                        .font(.morselData)
                        .foregroundStyle(Color.morselForest)
                    Text(title)
                        .font(.morselDisplay)
                        .foregroundStyle(Color.morselInk)
                    Text(subtitle)
                        .font(.morselBody)
                        .foregroundStyle(Color.morselInkTwo)

                    progress
                    content
                }
                .padding(24)
            }
            .background(Color.morselBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Set up later", action: onSkip)
                        .font(.morselData)
                        .foregroundStyle(Color.morselInkTwo)
                }
            }
        }
    }

    private var title: String {
        switch state.step {
        case .signIn: return "Let's set up your food logger."
        case .signedIn: return "Signed in ✓ — now connect your agent."
        case .connect: return "Now connect me in your chat app."
        case .coach: return "One photo. One honest entry."
        case .confirm: return "Ready when you are."
        case .done: return "Agent connected ✓"
        }
    }

    private var subtitle: String {
        switch state.step {
        case .signIn: return "First, prove it's you so I write to the right store."
        case .signedIn: return "That's the account I'll write to."
        case .connect: return "Your agent will write here; Morsel keeps the record readable."
        case .coach: return "Send a photo of your next meal and let your agent do the careful part."
        case .confirm: return "Confirm only after your connector has finished signing in."
        case .done: return "Your next meal is ready to log."
        }
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= state.step.rawValue ? Color.morselAccent : Color.morselLine)
                    .frame(height: 4)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch state.step {
        case .signIn: signInContent
        case .signedIn: signedInContent
        case .connect: connectContent
        case .coach: coachContent
        case .confirm: confirmContent
        case .done: doneContent
        }
    }

    private var signInContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("agent").font(.morselData).foregroundStyle(Color.morselInkThree)
            Text("Hi — I'll be your food logger. Morsel is where I write what you eat; you never fill in forms.")
                .font(.morselBody).foregroundStyle(Color.morselInk)
            Text("First, prove it's you:").font(.morselBody).foregroundStyle(Color.morselInk)
            if let auth {
                SignInView(auth: auth) { session in
                    guard state.authenticationSucceeded(session) else { return }
                    onAuthenticated(session)
                }
            }
        }
    }

    private var signedInContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("agent").font(.morselData).foregroundStyle(Color.morselInkThree)
            Text("Signed in ✓ — that's the account I'll write to. Now connect me in your chat app.")
                .font(.morselBody).foregroundStyle(Color.morselInk)
            Text("Pick where you talk to me:").font(.morselBody).foregroundStyle(Color.morselInk)
            Button("Continue to connector setup") { _ = state.proceedToConnect() }
                .buttonStyle(MorselPrimaryButtonStyle()).frame(maxWidth: .infinity)
        }
    }

    private var connectContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("agent").font(.morselData).foregroundStyle(Color.morselInkThree)
            Text("Paste this endpoint into any MCP client's custom connector field, then verify with get_profile.")
                .font(.morselBody).foregroundStyle(Color.morselInkTwo)
            Text("MCP ENDPOINT").morselSectionLabel()
            if let configuredEndpoint = OnboardingEndpoint(configuredValue: endpoint) {
                Text(configuredEndpoint.value)
                    .font(.morselData)
                    .foregroundStyle(Color.morselInk)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.morselSurfaceTwo, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("MCP endpoint not configured. Contact the app administrator.")
                    .font(.morselBody)
                    .foregroundStyle(Color.morselOver)
            }

            Picker("Platform", selection: $platform) {
                ForEach(OnboardingPlatform.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(OnboardingContent.instructions(for: platform.rawValue))
                .font(.morselBody)
                .foregroundStyle(Color.morselInkTwo)

            if let configuredEndpoint = OnboardingEndpoint(configuredValue: endpoint) {
                Text(prompt(for: platform, endpoint: configuredEndpoint.value))
                    .font(.morselData)
                    .foregroundStyle(Color.morselInk)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient.morselCard, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.morselLine) }
                    }

                    Button(didCopy ? "Copied ✓" : "Copy setup prompt") {
                    guard let configuredEndpoint = OnboardingEndpoint(configuredValue: endpoint) else { return }
                    UIPasteboard.general.string = prompt(for: platform, endpoint: configuredEndpoint.value)
                    didCopy = true
                    }
                    .buttonStyle(MorselPrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
                    .disabled(OnboardingEndpoint(configuredValue: endpoint) == nil)

            Button("Continue to first log") { _ = state.proceedToCoach() }
                .buttonStyle(MorselGhostButtonStyle())
                .frame(maxWidth: .infinity)
        }
    }

    private func prompt(for platform: OnboardingPlatform, endpoint: String) -> String {
        let template: String
        switch platform {
        case .claude, .chatGPT:
            template = OnboardingContent.chatPrompt
        case .desktop:
            template = OnboardingContent.claudeDesktopPrompt
        case .code:
            template = OnboardingContent.claudeCodePrompt
        }
        return OnboardingContent.prompt(template, endpoint: endpoint)
    }

    private var coachContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(OnboardingContent.signedInMarker)
                .font(.morselBodyStrong)
                .foregroundStyle(Color.morselAccent)
            Text("TRY THIS WITH YOUR AGENT")
                .morselSectionLabel()
            Text("send a photo of your next meal")
                .font(.morselTitle)
                .foregroundStyle(Color.morselInk)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.morselAccentSoft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 10) {
                Text("one photo = one entry")
                Text("estimates carry confidence — 0.90 honest beats 1.00 invented")
                Text("typed fallback: describe the meal if a photo is not possible")
            }
            .font(.morselBody)
            .foregroundStyle(Color.morselInkTwo)
            Button("Continue") { _ = state.proceedToConfirm() }
                .buttonStyle(MorselPrimaryButtonStyle())
                .frame(maxWidth: .infinity)
        }
    }

    private var confirmContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("When your connector is ready, confirm here to finish setup.")
                .font(.morselBody)
                .foregroundStyle(Color.morselInkTwo)
            Text("you").font(.morselData).foregroundStyle(Color.morselInkThree)
            Button("I'm connected") {
                _ = state.confirmConnection()
            }
            .buttonStyle(MorselPrimaryButtonStyle())
            .frame(maxWidth: .infinity)
        }
    }

    private var doneContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("agent").font(.morselData).foregroundStyle(Color.morselInkThree)
            Text("Agent connected ✓")
                .font(.morselTitle)
                .foregroundStyle(Color.morselAccent)
            Text("Your next meal is ready to log.")
                .font(.morselBody)
                .foregroundStyle(Color.morselInkTwo)
            Button("Open today's log") { onFinished() }
                .buttonStyle(MorselPrimaryButtonStyle())
                .frame(maxWidth: .infinity)
        }
    }
}

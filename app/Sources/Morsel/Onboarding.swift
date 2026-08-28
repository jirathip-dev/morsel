import Foundation
import SwiftUI
import UIKit

struct OnboardingState: Equatable, Sendable {
    var step: OnboardingStep = .connect
    var completed = false
    var manuallyConnected = false
    var onboardingStartedAt: Date

    init(onboardingStartedAt: Date = Date()) {
        self.onboardingStartedAt = onboardingStartedAt
    }

    var done: Bool {
        completed || manuallyConnected
    }
}

enum OnboardingStep: Int, CaseIterable, Sendable {
    case connect = 1
    case coach
    case done
}

struct OnboardingDetection: Equatable, Sendable {
    let updatedAt: Date?
    let manualConfirmation: Bool
    let startedAt: Date

    var isConnected: Bool {
        manualConfirmation || (updatedAt.map { $0 > startedAt } ?? false)
    }
}

enum OnboardingContent {
    static let chatPrompt = """
I use Morsel to track my food. Set yourself up as my food logger.
1. Tell me to open Settings → Connectors → Add custom connector and paste: {{MCP_URL}}
2. When I approve the sign-in, call get_profile to verify the connection.
3. If my profile is empty, ask for my stats (height, weight, age, sex, activity, goal),
   then set_profile + compute_targets.
4. Ask me to send a photo of my next meal; log it with log_meal — one photo = one
   entry, never invent precise macros, tag estimates with confidence.
5. Hereafter log food photos without being asked; answer "how am I doing?" with get_day.
"""

    static let claudeCodePrompt = """
Set up Morsel food tracking.
1. Add the MCP server: claude mcp add --transport http morsel {{MCP_URL}}
2. Complete the OAuth browser sign-in when it opens.
3. Verify by calling get_profile; if empty, ask me for stats, then set_profile.
4. Confirm: "Morsel connected — send me a photo of your next meal."
"""

    static func prompt(_ template: String, endpoint: String) -> String {
        template.replacingOccurrences(of: "{{MCP_URL}}", with: endpoint)
            .trimmingCharacters(in: .newlines)
    }
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

    @State private var state = OnboardingState()
    @State private var platform = Platform.chat
    @State private var didCopy = false

    private enum Platform: String, CaseIterable {
        case chat = "Claude.ai / ChatGPT"
        case desktop = "Claude Desktop"
        case code = "Claude Code"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("morsel")
                        .font(.morselData)
                        .foregroundStyle(Color.morselAccent)
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
        case .connect: return "Now connect me in your chat app."
        case .coach: return "One photo. One honest entry."
        case .done: return "Agent connected ✓"
        }
    }

    private var subtitle: String {
        switch state.step {
        case .connect: return "Your agent will write here; Morsel keeps the record readable."
        case .coach: return "Send a photo of your next meal and let your agent do the careful part."
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
        case .connect: connectContent
        case .coach: coachContent
        case .done: doneContent
        }
    }

    private var connectContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MCP ENDPOINT").morselSectionLabel()
            Text(endpoint)
                .font(.morselData)
                .foregroundStyle(Color.morselInk)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.morselSurfaceTwo, in: RoundedRectangle(cornerRadius: 8))

            Picker("Platform", selection: $platform) {
                ForEach(Platform.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(platformInstructions)
                .font(.morselBody)
                .foregroundStyle(Color.morselInkTwo)

            Text(OnboardingContent.prompt(
                platform == .code ? OnboardingContent.claudeCodePrompt : OnboardingContent.chatPrompt,
                endpoint: endpoint
            ))
                .font(.morselData)
                .foregroundStyle(Color.morselInk)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient.morselCard, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.morselLine) }

            Button(didCopy ? "Copied ✓" : "Copy setup prompt") {
                UIPasteboard.general.string = OnboardingContent.prompt(
                    platform == .code ? OnboardingContent.claudeCodePrompt : OnboardingContent.chatPrompt,
                    endpoint: endpoint
                )
                didCopy = true
            }
            .buttonStyle(MorselPrimaryButtonStyle())
            .frame(maxWidth: .infinity)

            Button("I've added Morsel") { state.step = .coach }
                .buttonStyle(MorselGhostButtonStyle())
                .frame(maxWidth: .infinity)
        }
    }

    private var platformInstructions: String {
        switch platform {
        case .chat:
            return "Open Settings → Connectors → Add custom connector, then paste this setup prompt."
        case .desktop:
            return "In Claude Desktop, open Settings → Connectors, add a custom connector, then paste this prompt."
        case .code:
            return "Claude Code can install the connector for you."
        }
    }

    private var coachContent: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            Button("Continue") { state.step = .done }
                .buttonStyle(MorselPrimaryButtonStyle())
                .frame(maxWidth: .infinity)
        }
    }

    private var doneContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Morsel checks for the first agent write. If your connector cannot be detected yet, confirm manually.")
                .font(.morselBody)
                .foregroundStyle(Color.morselInkTwo)
            Button("I'm connected") {
                state.manuallyConnected = true
                state.completed = true
                onFinished()
            }
            .buttonStyle(MorselPrimaryButtonStyle())
            .frame(maxWidth: .infinity)
        }
    }
}

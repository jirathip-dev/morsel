import SwiftUI

// Issue #94 — Settings (journal page behind the toothed cog): Appearance
// (Paper / Night ink / Follow system), MCP endpoint, Replay onboarding,
// Health margin-note copy, Sign out, and the version folio. Settings keeps
// the friendly copy table — raw Supabase/backend details never reach users.

struct SettingsJournalView: View {
    let themePreferenceKey: String
    let mcpEndpoint: String
    let replay: () -> Void
    let onSignOut: () -> Void
    let close: () -> Void
    let weightImportError: String?

    @AppStorage(MorselAppearance.themePreferenceKey)
    private var themePreferenceRaw = MorselAppearance.defaultThemePreference.rawValue

    init(
        themePreferenceKey: String,
        mcpEndpoint: String,
        replay: @escaping () -> Void,
        onSignOut: @escaping () -> Void,
        close: @escaping () -> Void,
        weightImportError: String? = nil
    ) {
        self.themePreferenceKey = themePreferenceKey
        self.mcpEndpoint = mcpEndpoint
        self.replay = replay
        self.onSignOut = onSignOut
        self.close = close
        self.weightImportError = weightImportError
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                appearanceSection
                JournalRule()
                mcpSection
                JournalRule()
                replayRow
                JournalRule()
                healthSection
                JournalRule()
                signOutRow
                Spacer(minLength: 24)
                versionLine
            }
            .padding(.leading, 46)
            .padding(.trailing, 18)
            .padding(.top, 12)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .background(Color.morselBackground.ignoresSafeArea())
        .overlay(alignment: .leading) {
            JournalPageFurniture(date: Date())
                .padding(.top, 8)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: close) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(Font.morselSerif(size: 15).weight(.semibold))
                    Text("Today")
                        .font(Font.morselHand(size: 17))
                }
                .foregroundStyle(Color.morselForest)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Today")
            Spacer()
            Text("Settings")
                .font(.morselDisplay)
                .foregroundStyle(Color.morselInk)
        }
        .padding(.bottom, 4)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance").morselSectionLabel()
            HStack(spacing: 26) {
                ForEach(MorselThemePreference.allCases, id: \.self) { preference in
                    let selected = themePreferenceRaw == preference.rawValue
                    Button {
                        themePreferenceRaw = preference.rawValue
                    } label: {
                        VStack(spacing: 3) {
                            Text(preference.title)
                                .font(Font.morselHand(size: 19))
                                .foregroundStyle(selected ? Color.morselForest : Color.morselInkTwo)
                            MarkerStroke(
                                color: selected ? Color.morselForest : .clear,
                                width: preference == .followSystem ? 78 : 34,
                                height: 4
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer()
            }
        }
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP endpoint").morselSectionLabel()
            Text(mcpEndpoint.isEmpty ? "MCP endpoint is not configured." : mcpEndpoint)
                .font(.morselData)
                .foregroundStyle(Color.morselInk)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.morselSurfaceTwo, in: RoundedRectangle(cornerRadius: 6))
            ProvenanceLabel(text: "your agent writes here · verify with get_profile")
        }
    }

    private var replayRow: some View {
        Button(action: replay) {
            HStack {
                Text("Replay onboarding")
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselInk)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkThree)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Health").morselSectionLabel()
            Text("Apple Health")
                .font(.morselBodyStrong)
                .foregroundStyle(Color.morselInk)
            // Locked V1 semantics (issue #90/94): active energy is context, a
            // margin note — never subtracted from eaten calories.
            ProvenanceLabel(text: "active energy is a margin note, never subtracted")
            if let weightImportError {
                Text(weightImportError)
                    .font(.morselBody)
                    .foregroundStyle(Color.morselOver)
            }
        }
    }

    private var signOutRow: some View {
        Button(action: onSignOut) {
            HStack {
                Text("Sign out")
                    .font(.morselBodyStrong)
                    .foregroundStyle(Color.morselOver)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkThree)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign out of Morsel")
    }

    private var versionLine: some View {
        HStack {
            Spacer()
            Text("Morsel \(Self.versionText)")
                .font(.morselFootnote)
                .foregroundStyle(Color.morselInkThree)
            Spacer()
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version)(\(build))"
    }
}

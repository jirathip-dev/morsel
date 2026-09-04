import Combine
import Supabase
import SwiftUI

@main
struct MorselApp: App {
    @StateObject private var sessionStore = SessionStore()
    @AppStorage(MorselAppearance.themePreferenceKey)
    private var themePreference = MorselAppearance.defaultThemePreference.rawValue

    private let supabaseClient: SupabaseClient?
    private let mcpEndpoint: String

    init() {
        MorselFontCatalog.register()
        let configuration = MorselConfiguration(bundle: .main)
        supabaseClient = configuration.makeClient()
        mcpEndpoint = configuration.mcpEndpoint
    }

    var body: some Scene {
        WindowGroup {
            // Issue #94: the root consumes the appearance seam — Paper forces
            // Light (the default), Night ink forces Dark, Follow system does
            // not force. Every native token resolves through the trait, so the
            // whole journal re-inks from DesignSystem.swift (no plist route —
            // the fastlane INFOPLIST_FILE template is release tooling).
            MorselRootView(
                sessionStore: sessionStore,
                auth: SupabaseAuthClient(client: supabaseClient),
                repository: SupabaseDashboardRepository(client: supabaseClient),
                supabaseClient: supabaseClient,
                mcpEndpoint: mcpEndpoint
            )
            .preferredColorScheme(
                MorselAppearance.scheme(for: MorselThemePreference(rawValue: themePreference) ?? .paper)
            )
        }
    }
}

struct MorselConfiguration {
    let supabaseURL: URL?
    let anonKey: String
    let mcpEndpoint: String

    init(bundle: Bundle) {
        let urlString = (bundle.object(forInfoDictionaryKey: "MorselSupabaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        supabaseURL = urlString.flatMap(URL.init(string:))
        anonKey = (bundle.object(forInfoDictionaryKey: "MorselSupabaseAnonKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mcpEndpoint = (bundle.object(forInfoDictionaryKey: "MORSEL_MCP_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func makeClient() -> SupabaseClient? {
        guard let supabaseURL, !anonKey.isEmpty else {
            return nil
        }
        let options = SupabaseClientOptions(
            auth: .init(autoRefreshToken: true)
        )
        return SupabaseClient(supabaseURL: supabaseURL, supabaseKey: anonKey, options: options)
    }
}

@MainActor
final class SessionStore: ObservableObject {
    /// Explicit app routes when no session exists. `initialSetup` presents
    /// onboarding; `setupDeferred` is the honest post-"Set up later" state:
    /// it never invents a session, only offers sign-in (which re-enters
    /// onboarding with the resulting real session).
    enum NoSessionRoute: Equatable, Sendable {
        case initialSetup
        case setupDeferred
    }

    @Published private(set) var session: AuthenticatedSession?
    @Published private(set) var pendingRoute: NoSessionRoute = .initialSetup

    /// True once "Set up later" deferred the initial onboarding (the honest
    /// no-session state that offers sign-in).
    var isSetupDeferred: Bool { pendingRoute == .setupDeferred }

    /// "Set up later" on the initial (unauthenticated) onboarding: leave the
    /// presentation and land in the explicit deferred state. No session is
    /// created and no authenticated repository/network call is made.
    func deferSetup() {
        pendingRoute = .setupDeferred
    }

    func authenticate(_ session: AuthenticatedSession) {
        self.session = session
        pendingRoute = .initialSetup
    }

    /// Signs out of Supabase (when configured) and returns to the sign-in
    /// route. The friendly no-session state never invents a session.
    func signOut(using auth: any SupabaseAuthenticating) async {
        try? await auth.signOut()
        session = nil
        pendingRoute = .setupDeferred
    }

    func restore(using auth: any SupabaseAuthenticating) async {
        guard session == nil else {
            return
        }
        session = try? await auth.restoreSession()
    }
}

private struct MorselRootView: View {
    @ObservedObject var sessionStore: SessionStore
    let auth: any SupabaseAuthenticating
    let repository: any DashboardRepository
    let supabaseClient: SupabaseClient?
    let mcpEndpoint: String
    @State private var pendingSession: AuthenticatedSession?

    var body: some View {
        Group {
            if let session = sessionStore.session {
                AuthenticatedDashboardView(
                    repository: repository,
                    userID: session.userID,
                    session: session,
                    weightImporter: supabaseClient.flatMap {
                        try? HealthKitWeightImporter(
                            store: SupabaseWeightLogStore(client: $0, userID: session.userID)
                        )
                    },
                    mcpEndpoint: mcpEndpoint,
                    auth: auth,
                    onSignOut: {
                        Task { await sessionStore.signOut(using: auth) }
                    }
                )
            } else if sessionStore.isSetupDeferred {
                SignInView(auth: auth) { session in
                    sessionStore.authenticate(session)
                }
            } else {
                OnboardingView(
                    userID: pendingSession?.userID ?? UUID(),
                    endpoint: mcpEndpoint,
                    auth: auth,
                    onAuthenticated: { pendingSession = $0 },
                    onFinished: {
                        if let pendingSession { sessionStore.authenticate(pendingSession) }
                    },
                    onSkip: { sessionStore.deferSetup() }
                )
            }
        }
        .task {
            await sessionStore.restore(using: auth)
        }
    }
}

// Issue #94: Today, History, and Goals are the THREE primary tabs (goals is
// not behind a secondary route anymore); Settings sits behind the toothed
// cog on the Today page.
enum JournalTab: String, CaseIterable, Hashable {
    case today
    case history
    case goals

    var title: String {
        switch self {
        case .today: return "Today"
        case .history: return "History"
        case .goals: return "Goals"
        }
    }
}

private struct AuthenticatedDashboardView: View {
    @StateObject private var viewModel: DashboardViewModel
    @State private var selectedTab: JournalTab = .today
    @State private var showingSettings = false
    @State private var showingOnboarding = false

    let mcpEndpoint: String
    let session: AuthenticatedSession
    let weightImporter: HealthKitWeightImporter?
    let auth: any SupabaseAuthenticating
    let onSignOut: () -> Void

    init(
        repository: any DashboardRepository,
        userID: UUID,
        session: AuthenticatedSession,
        weightImporter: HealthKitWeightImporter?,
        mcpEndpoint: String,
        auth: any SupabaseAuthenticating,
        onSignOut: @escaping () -> Void
    ) {
        self.mcpEndpoint = mcpEndpoint
        self.session = session
        self.weightImporter = weightImporter
        self.auth = auth
        self.onSignOut = onSignOut
        _viewModel = StateObject(
            wrappedValue: DashboardViewModel(
                repository: repository,
                userID: userID,
                weightImporter: weightImporter
            )
        )
    }

    var body: some View {
        ZStack {
            Color.morselBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                JournalTabBar(selection: $selectedTab)
            }
        }
        .task {
            await viewModel.importWeights()
            if !OnboardingStore().hasCompleted(for: viewModel.userID) {
                showingOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $showingSettings) {
            SettingsJournalView(
                themePreferenceKey: MorselAppearance.themePreferenceKey,
                mcpEndpoint: mcpEndpoint,
                replay: { showingSettings = false; showingOnboarding = true },
                onSignOut: {
                    showingSettings = false
                    onSignOut()
                },
                close: { showingSettings = false },
                weightImportError: viewModel.weightImportError
            )
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            MorselActionTint {
                OnboardingView(
                    userID: viewModel.userID,
                    endpoint: mcpEndpoint,
                    session: session,
                    onFinished: {
                        OnboardingStore().markCompleted(for: viewModel.userID)
                        showingOnboarding = false
                    },
                    onSkip: {
                        OnboardingStore().markCompleted(for: viewModel.userID)
                        showingOnboarding = false
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedTab {
        case .today:
            MorselActionTint {
                TodayView(
                    viewModel: viewModel,
                    showSettings: { showingSettings = true }
                )
            }
        case .history:
            MorselActionTint {
                HistoryView(repository: viewModel.repository, userID: viewModel.userID)
            }
        case .goals:
            MorselActionTint {
                GoalsView(
                    repository: viewModel.repository,
                    userID: viewModel.userID,
                    onSaved: { await viewModel.load() },
                    seeToday: { selectedTab = .today }
                )
            }
        }
    }
}

/// Scoped orange action tint for tab content: actions/links keep the V1
/// orange identity anchor; the journal tab bar draws its own forest active
/// word (never a green wash over descendants).
private struct MorselActionTint<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .tint(Color.morselAccent)
    }
}

/// V1 bottom navigation: three hand-lettered words on the paper ground with a
/// hairline rule above and a marker-stroke under the active tab. Native
/// SwiftUI behavior, no browser pill.
private struct JournalTabBar: View {
    @Binding var selection: JournalTab

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.morselInkLine.opacity(0.55))
                .frame(height: 1)
            HStack(spacing: 0) {
                ForEach(JournalTab.allCases, id: \.self) { tab in
                    Button {
                        selection = tab
                    } label: {
                        tabLabel(tab)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(height: 44)
        }
        .background(Color.morselBackground.ignoresSafeArea())
    }

    private func tabLabel(_ tab: JournalTab) -> some View {
        let active = selection == tab
        return VStack(spacing: 3) {
            Text(tab.title)
                .font(Font.morselHand(size: 20))
                .foregroundStyle(active ? Color.morselForest : Color.morselInkTwo)
            MarkerStroke(
                color: active ? Color.morselForest : .clear,
                width: 40,
                height: 4
            )
        }
        .padding(.vertical, 2)
    }
}

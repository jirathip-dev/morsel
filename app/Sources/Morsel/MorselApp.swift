import Combine
import Supabase
import SwiftUI

@main
struct MorselApp: App {
    @StateObject private var sessionStore = SessionStore()
    private let supabaseClient: SupabaseClient?
    private let mcpEndpoint: String

    init() {
        let configuration = MorselConfiguration(bundle: .main)
        supabaseClient = configuration.makeClient()
        mcpEndpoint = configuration.mcpEndpoint
    }

    var body: some Scene {
        WindowGroup {
            // v0.4 hotfix (#89): the app is LIGHT-ONLY until the night-ink
            // theme (#90) ships. MorselAppearance.scheme is the testable
            // seam for the root forced-light mechanism (asserted in
            // LightSchemeTests and pinned to this WindowGroup root by the
            // hosted contract probe). A plist-based UIUserInterfaceStyle
            // would need the fastlane template (the INFOPLIST_FILE carries
            // explicit $(INFOPLIST_KEY_*) entries), which is release
            // tooling — out of scope for this hotfix.
            MorselRootView(
                sessionStore: sessionStore,
                auth: SupabaseAuthClient(client: supabaseClient),
                repository: SupabaseDashboardRepository(client: supabaseClient),
                supabaseClient: supabaseClient,
                mcpEndpoint: mcpEndpoint
            )
            .preferredColorScheme(MorselAppearance.scheme)
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
                    mcpEndpoint: mcpEndpoint
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

private enum DashboardTab: Hashable {
    case today
    case settings
}

private struct AuthenticatedDashboardView: View {
    @StateObject private var viewModel: DashboardViewModel
    @State private var showingOnboarding = false
    @State private var selectedTab: DashboardTab = .today

    let mcpEndpoint: String
    let session: AuthenticatedSession
    let weightImporter: HealthKitWeightImporter?

    init(
        repository: any DashboardRepository,
        userID: UUID,
        session: AuthenticatedSession,
        weightImporter: HealthKitWeightImporter?,
        mcpEndpoint: String
    ) {
        self.mcpEndpoint = mcpEndpoint
        self.session = session
        self.weightImporter = weightImporter
        _viewModel = StateObject(
            wrappedValue: DashboardViewModel(
                repository: repository,
                userID: userID,
                weightImporter: weightImporter
            )
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            MorselActionTint {
                TodayView(viewModel: viewModel)
            }
            .tag(DashboardTab.today)
            .tabItem {
                Label("Today", systemImage: "chart.bar")
            }
            MorselActionTint {
                SettingsView(
                    mcpEndpoint: mcpEndpoint, repository: viewModel.repository,
                    userID: viewModel.userID, dashboardViewModel: viewModel,
                    showToday: { selectedTab = .today },
                    replay: { showingOnboarding = true }
                )
            }
            .tag(DashboardTab.settings)
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(Color.morselForest)
        .task {
            await viewModel.importWeights()
            if !OnboardingStore().hasCompleted(for: viewModel.userID) {
                showingOnboarding = true
            }
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
                })
            }
        }
    }
}

/// Scoped orange action tint for tab content: the TabView tint itself is V1
/// forest (active navigation reads forest), while every descendant action
/// control keeps the V1 orange identity/action anchor.
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

private struct SettingsView: View {
    let mcpEndpoint: String
    let repository: any DashboardRepository
    let userID: UUID
    @ObservedObject var dashboardViewModel: DashboardViewModel
    let showToday: () -> Void
    let replay: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Daily goals") {
                        GoalsEditorView(
                            repository: repository,
                            userID: userID,
                            onSaved: { await dashboardViewModel.load() },
                            onSeeToday: showToday
                        )
                    }
                    .foregroundStyle(Color.morselInk)
                } header: {
                    Text("Goals").morselSectionLabel()
                }
                Section {
                    Text(mcpEndpoint.isEmpty ? "MCP endpoint is not configured." : mcpEndpoint)
                        .font(.morselData)
                        .foregroundStyle(Color.morselInkTwo)
                    Button("Replay onboarding", action: replay)
                } header: {
                    Text("Agent").morselSectionLabel()
                }
            }
            // v0.4 hotfix (#89): never the stock system Form — paper ground
            // with the app's ink palette so Settings matches every screen.
            .scrollContentBackground(.hidden)
            .background(Color.morselBackground.ignoresSafeArea())
            .navigationTitle("Settings")
        }
    }
}

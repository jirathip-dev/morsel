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
            MorselRootView(
                sessionStore: sessionStore,
                auth: SupabaseAuthClient(client: supabaseClient),
                repository: SupabaseDashboardRepository(client: supabaseClient),
                supabaseClient: supabaseClient,
                mcpEndpoint: mcpEndpoint
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
            TodayView(viewModel: viewModel)
                .tag(DashboardTab.today)
                .tabItem {
                    Label("Today", systemImage: "chart.bar")
                }
            SettingsView(
                mcpEndpoint: mcpEndpoint, repository: viewModel.repository,
                userID: viewModel.userID, dashboardViewModel: viewModel,
                showToday: { selectedTab = .today },
                replay: { showingOnboarding = true }
            )
            .tag(DashboardTab.settings)
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(Color.morselAccent)
        .task {
            await viewModel.importWeights()
            if !OnboardingStore().hasCompleted(for: viewModel.userID) {
                showingOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
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
                Section("Goals") {
                    NavigationLink("Daily goals") {
                        GoalsEditorView(
                            repository: repository,
                            userID: userID,
                            onSaved: { await dashboardViewModel.load() },
                            onSeeToday: showToday
                        )
                    }
                }
                Section("Agent") {
                    Text(mcpEndpoint.isEmpty ? "MCP endpoint is not configured." : mcpEndpoint)
                        .font(.morselData)
                    Button("Replay onboarding", action: replay)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

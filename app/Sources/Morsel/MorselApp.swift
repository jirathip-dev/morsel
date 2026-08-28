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
        mcpEndpoint = (bundle.object(forInfoDictionaryKey: "MorselMCPURL") as? String)?
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
    @Published private(set) var session: AuthenticatedSession?

    func authenticate(_ session: AuthenticatedSession) {
        self.session = session
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
    let mcpEndpoint: String

    var body: some View {
        Group {
            if let session = sessionStore.session {
                AuthenticatedDashboardView(repository: repository, userID: session.userID, mcpEndpoint: mcpEndpoint)
            } else {
                SignInView(auth: auth) { session in
                    sessionStore.authenticate(session)
                }
            }
        }
        .task {
            await sessionStore.restore(using: auth)
        }
    }
}

private struct AuthenticatedDashboardView: View {
    @StateObject private var viewModel: DashboardViewModel
    @State private var showingOnboarding = false

    let mcpEndpoint: String

    init(repository: any DashboardRepository, userID: UUID, mcpEndpoint: String) {
        self.mcpEndpoint = mcpEndpoint
        _viewModel = StateObject(
            wrappedValue: DashboardViewModel(
                repository: repository,
                userID: userID
            )
        )
    }

    var body: some View {
        TabView {
            TodayView(viewModel: viewModel)
                .tabItem {
                    Label("Today", systemImage: "chart.bar")
                }
            SettingsView(mcpEndpoint: mcpEndpoint) {
                showingOnboarding = true
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(Color.morselAccent)
        .task {
            if !OnboardingStore().hasCompleted(for: viewModel.userID) {
                showingOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView(userID: viewModel.userID, endpoint: mcpEndpoint) {
                OnboardingStore().markCompleted(for: viewModel.userID)
                showingOnboarding = false
            } onSkip: {
                OnboardingStore().markCompleted(for: viewModel.userID)
                showingOnboarding = false
            }
        }
    }
}

private struct SettingsView: View {
    let mcpEndpoint: String
    let replay: () -> Void

    var body: some View {
        NavigationStack {
            Form {
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

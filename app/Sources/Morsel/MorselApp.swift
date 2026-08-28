import Combine
import Supabase
import SwiftUI

@main
struct MorselApp: App {
    @StateObject private var sessionStore = SessionStore()
    private let supabaseClient: SupabaseClient?

    init() {
        let configuration = MorselConfiguration(bundle: .main)
        supabaseClient = configuration.makeClient()
    }

    var body: some Scene {
        WindowGroup {
            MorselRootView(
                sessionStore: sessionStore,
                auth: SupabaseAuthClient(client: supabaseClient),
                repository: SupabaseDashboardRepository(client: supabaseClient)
            )
        }
    }
}

struct MorselConfiguration {
    let supabaseURL: URL?
    let anonKey: String

    init(bundle: Bundle) {
        let urlString = (bundle.object(forInfoDictionaryKey: "MorselSupabaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        supabaseURL = urlString.flatMap(URL.init(string:))
        anonKey = (bundle.object(forInfoDictionaryKey: "MorselSupabaseAnonKey") as? String)?
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

    var body: some View {
        Group {
            if let session = sessionStore.session {
                AuthenticatedDashboardView(repository: repository, userID: session.userID)
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

    init(repository: any DashboardRepository, userID: UUID) {
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
        }
        .tint(Color.morselAccent)
    }
}

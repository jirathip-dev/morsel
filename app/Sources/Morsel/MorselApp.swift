import Combine
import SwiftUI

@main
struct MorselApp: App {
    @StateObject private var sessionStore = SessionStore()
    private let configuration: MorselConfiguration

    init() {
        configuration = MorselConfiguration(bundle: .main)
    }

    var body: some Scene {
        WindowGroup {
            MorselRootView(
                sessionStore: sessionStore,
                auth: SupabaseAuthClient(
                    baseURL: configuration.supabaseURL,
                    anonKey: configuration.anonKey
                ),
                repository: SupabaseDashboardRepository(
                    baseURL: configuration.supabaseURL,
                    anonKey: configuration.anonKey
                )
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
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var session: AuthenticatedSession?

    func authenticate(_ session: AuthenticatedSession) {
        self.session = session
    }
}

private struct MorselRootView: View {
    @ObservedObject var sessionStore: SessionStore
    let auth: any SupabaseAuthenticating
    let repository: any DashboardRepository

    var body: some View {
        if let session = sessionStore.session {
            AuthenticatedDashboardView(repository: repository, session: session)
        } else {
            SignInView(auth: auth) { session in
                sessionStore.authenticate(session)
            }
        }
    }
}

private struct AuthenticatedDashboardView: View {
    @StateObject private var viewModel: DashboardViewModel

    init(repository: any DashboardRepository, session: AuthenticatedSession) {
        _viewModel = StateObject(
            wrappedValue: DashboardViewModel(
                repository: repository,
                userID: session.userID,
                accessToken: session.accessToken
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

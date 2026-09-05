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
            MorselRootView(
                sessionStore: sessionStore,
                auth: SupabaseAuthClient(client: supabaseClient),
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

private struct MorselRootView: View {
    @ObservedObject var sessionStore: SessionStore
    let auth: any SupabaseAuthenticating
    let supabaseClient: SupabaseClient?
    let mcpEndpoint: String
    @State private var pendingSession: AuthenticatedSession?

    var body: some View {
        Group {
            if let session = sessionStore.session {
                AuthenticatedDashboardView(
                    supabaseClient: supabaseClient,
                    session: session,
                    mcpEndpoint: mcpEndpoint,
                    auth: auth,
                    onSignOut: {
                        Task { await sessionStore.signOut(using: auth) }
                    }
                )
            } else if sessionStore.isSetupDeferred {
                                                                MorselActionTint {
                    SignInView(auth: auth) { session in
                        sessionStore.authenticate(session)
                    }
                }
            } else {
                MorselActionTint {
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
        }
        .task {
            await sessionStore.restore(using: auth)
        }
    }
}

// Three primary journal tabs (Settings stays behind the Today cog).
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
    @StateObject private var pager = JournalPagerModel()
    @StateObject private var routeModel = JournalRouteModel()
    @State private var showingSettings = false
    @State private var showingOnboarding = false
    @State private var tabReloadCounts: [JournalTab: Int] = [:]
    @AppStorage(MorselAppearance.themePreferenceKey)
    private var themePreferenceRaw = MorselAppearance.defaultThemePreference.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Issue #110 — a fullScreenCover is a separate UIKit presentation: it
    /// does not re-resolve the root preferredColorScheme while it is up.
    /// Re-assert the same preference-derived scheme on each presented cover
    /// root so a Paper/Night-ink switch made inside Settings re-inks the
    /// cover itself immediately, not only the window behind it.
    private var coverColorScheme: ColorScheme? {
        MorselAppearance.scheme(for: MorselThemePreference(rawValue: themePreferenceRaw) ?? .paper)
    }

    let mcpEndpoint: String
    let session: AuthenticatedSession
    let auth: any SupabaseAuthenticating
    let onSignOut: () -> Void
    /// Per-account local-first stack; remote-only fallback when unavailable.
    private let reliability: AccountReliabilityServices?
    private let fallbackImporter: HealthKitWeightImporter?

    init(
        supabaseClient: SupabaseClient?,
        session: AuthenticatedSession,
        mcpEndpoint: String,
        auth: any SupabaseAuthenticating,
        onSignOut: @escaping () -> Void
    ) {
        self.mcpEndpoint = mcpEndpoint
        self.session = session
        self.auth = auth
        self.onSignOut = onSignOut
        let services = AccountReliabilityServices(client: supabaseClient, userID: session.userID)
        reliability = services
        let fallback: HealthKitWeightImporter?
        if let services {
            fallback = nil
            _viewModel = StateObject(
                wrappedValue: DashboardViewModel(
                    repository: services.repository,
                    userID: session.userID,
                    weightImporter: services.importer,
                    healthStore: services.healthStore,
                    syncEngine: services.engine
                )
            )
        } else {
            let remote = SupabaseDashboardRepository(client: supabaseClient)
            let importer = supabaseClient.flatMap {
                try? HealthKitWeightImporter(store: SupabaseWeightLogStore(client: $0, userID: session.userID))
            }
            fallback = importer
            _viewModel = StateObject(
                wrappedValue: DashboardViewModel(
                    repository: remote,
                    userID: session.userID,
                    weightImporter: importer
                )
            )
        }
        fallbackImporter = fallback
    }

    var body: some View {
        ZStack {
            Color.morselBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                JournalTabBar(pager: pager)
            }
            if routeModel.isPresentingAddMeal {
                MorselActionTint {
                    AddMealView(viewModel: viewModel, onClose: closeAddMeal)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.3),
                   value: routeModel.isPresentingAddMeal)
        .task {
            async let health: Void = viewModel.importWeights()
            await viewModel.load()
            _ = await health
            reliability?.engine.onSyncCompleted = { [weak viewModel] in
                Task { @MainActor in
                    await viewModel?.load()
                    await viewModel?.refreshHealthCalmStatus()
                }
            }
            if !OnboardingStore().hasCompleted(for: viewModel.userID) {
                showingOnboarding = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                reliability?.engine.syncNow()
                Task { await viewModel.load() }
            }
        }
        .onDisappear {
            reliability?.shutdownAndClear()
        }
        .fullScreenCover(isPresented: $showingSettings) {
            SettingsJournalView(
                themePreferenceKey: MorselAppearance.themePreferenceKey,
                mcpEndpoint: mcpEndpoint,
                replay: { showingSettings = false; showingOnboarding = true },
                onSignOut: { showingSettings = false; onSignOut() },
                close: { showingSettings = false },
                weightImportError: viewModel.weightImportError,
                healthStatusCopy: viewModel.healthStatus.copy,
                onRetryHealthSync: {
                    Task { await viewModel.retryHealthSync() }
                }
            )
            .preferredColorScheme(coverColorScheme)
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            MorselActionTint {
                OnboardingView(
                    userID: viewModel.userID,
                    endpoint: mcpEndpoint,
                    session: session,
                    onFinished: { OnboardingStore().markCompleted(for: viewModel.userID); showingOnboarding = false },
                    onSkip: { OnboardingStore().markCompleted(for: viewModel.userID); showingOnboarding = false }
                )
            }
            .preferredColorScheme(coverColorScheme)
        }
        .onChange(of: pager.selection) { oldTab, newTab in
            if routeModel.isPresentingAddMeal {
                routeModel.closeAddMeal()
            }
            if oldTab != newTab {
                tabReloadCounts[newTab, default: 0] += 1
                if newTab == .today {
                    Task { await viewModel.load() }
                }
            }
        }
    }

    private func closeAddMeal() { routeModel.closeAddMeal() }
    private var selectionBinding: Binding<JournalTab> {
        Binding(get: { pager.selection }, set: { pager.select($0) })
    }
    /// Three primary pages in a native page-style TabView.
    @ViewBuilder
    private var pageContent: some View {
        if reduceMotion {
            journalPage(for: pager.selection)
        } else {
            TabView(selection: selectionBinding) {
                journalPage(for: .today).tag(JournalTab.today)
                journalPage(for: .history).tag(JournalTab.history)
                journalPage(for: .goals).tag(JournalTab.goals)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    @ViewBuilder
    private func journalPage(for tab: JournalTab) -> some View {
        switch tab {
        case .today:
            MorselActionTint {
                TodayView(viewModel: viewModel,
                          showSettings: { showingSettings = true },
                          addMeal: { routeModel.openAddMeal() })
            }
        case .history:
            MorselActionTint {
                HistoryView(repository: viewModel.repository,
                            userID: viewModel.userID,
                            reloadKey: tabReloadCounts[.history] ?? 0)
            }
        case .goals:
            MorselActionTint {
                GoalsView(repository: viewModel.repository,
                          userID: viewModel.userID,
                          onSaved: { await viewModel.load() },
                          seeToday: { pager.select(.today) })
            }
        }
    }
}

/// Scoped orange action tint — tab content keeps the V1 orange identity
/// anchor (never a green wash over descendants).
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

private struct JournalTabBar: View {
    @ObservedObject var pager: JournalPagerModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.morselInkLine.opacity(0.55))
                .frame(height: 1)
            HStack(spacing: 0) {
                ForEach(JournalTab.allCases, id: \.self) { tab in
                    Button {
                        pager.select(tab)
                        JournalKeyboardDismisser.resign()
                    } label: {
                        tabLabel(tab)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(pager.selection == tab ? .isSelected : [])
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(height: 44)
        }
        .background(Color.morselBackground.ignoresSafeArea())
    }

    private func tabLabel(_ tab: JournalTab) -> some View {
        let active = pager.selection == tab
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

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
    @StateObject private var menuLibrary: MenuLibraryModel
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
    /// Issue #121 — mirrors the device zone to profiles.timezone on launch
    /// and foreground when it changes (server day math uses the same zone).
    private let timezoneSync: DeviceTimezoneSync?

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
        timezoneSync = supabaseClient.map { DeviceTimezoneSync(client: $0, userID: session.userID) }
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
            _menuLibrary = StateObject(
                wrappedValue: MenuLibraryModel(repository: services.repository, userID: session.userID)
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
            _menuLibrary = StateObject(
                wrappedValue: MenuLibraryModel(repository: remote, userID: session.userID)
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
                    .animation(
                        reduceMotion ? .easeOut(duration: JournalTurnSeam.reducedDuration) : nil,
                        value: pager.selection
                    )
                JournalTabBar(pager: pager)
            }
            if routeModel.isPresentingAddMeal {
                MorselActionTint {
                    AddMealView(
                        viewModel: viewModel,
                        onClose: closeAddMeal,
                        menuLibrary: menuLibrary,
                        onOpenMenus: { routeModel.openMenus() }
                    )
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                .zIndex(1)
            }
            if routeModel.isPresentingMenus {
                MorselActionTint {
                    MenusScreen(model: menuLibrary, onClose: routeModel.closeMenus)
                }
                .zIndex(2)
            }
        }
        // Issue #153 — the Edit-item sheet (presented from the Today journal
        // pages) loads its photo surface through the shared view model.
        .environmentObject(viewModel)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.3),
                   value: routeModel.isPresentingAddMeal)
        .task {
            if let timezoneSync {
                Task { await timezoneSync.syncIfChanged() }
            }
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
                Task { await timezoneSync?.syncIfChanged() }
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
    /// Three primary journal pages: Reduce Motion swaps with a plain fade;
    /// the rich path turns each page in on the approved V1 hinge (#111).
    @ViewBuilder
    private var pageContent: some View {
        if reduceMotion {
            journalPage(for: pager.selection)
                .transition(.opacity)
        } else {
            JournalPageTurner(pager: pager) { tab in
                journalPage(for: tab)
            }
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

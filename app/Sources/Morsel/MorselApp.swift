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
        func string(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        supabaseURL = URL(string: string("MorselSupabaseURL"))
        anonKey = string("MorselSupabaseAnonKey")
        mcpEndpoint = string("MORSEL_MCP_URL")
    }

    func makeClient() -> SupabaseClient? {
        guard let supabaseURL, !anonKey.isEmpty else {
            return nil
        }
        return SupabaseClient(
            supabaseURL: supabaseURL, supabaseKey: anonKey,
            options: SupabaseClientOptions(auth: .init(autoRefreshToken: true))
        )
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
                    supabaseClient: supabaseClient, session: session, mcpEndpoint: mcpEndpoint,
                    auth: auth, onSignOut: { Task { await sessionStore.signOut(using: auth) } }
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
                        onFinished: { if let pendingSession { sessionStore.authenticate(pendingSession) } },
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
// see docs/NATIVE_JOURNAL_PROVENANCE.md
// MARK: - Journal page ownership (issue #175)
enum JournalPageLifecycleEvent { case created, released, activated }
typealias JournalPageObserver = (JournalPageLifecycleEvent, JournalTab, AnyObject?) -> Void
/// #175: one retained page/model/scroll per visited tab; only accepted navigation activates it.
struct JournalPageStage<Page: View>: View {
    @ObservedObject var pager: JournalPagerModel
    @EnvironmentObject private var machine: JournalTurnMachine
    let active: JournalTab
    /// The shell overlay owns interaction instead of the pages (#176).
    var overlayCoversPages = false
    let makePage: (JournalTab, Int) -> Page
    @State private var activations: [JournalTab: Int] = [.today: 1]

    var body: some View {
        ZStack {
            ForEach(JournalTab.allCases, id: \.self) { tab in
                if activations[tab] != nil { page(tab) }
            }
            if let turn = machine.turn, activations[turn.incoming] == nil {
                Color.morselBackground
                    .modifier(HingeTurnPose(direction: turn.direction, progress: turn.progress))
                    .allowsHitTesting(false) // Issue #176 — decoration owns no touch
                    .zIndex(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Opening the page")
            }
        }
        .onChange(of: pager.selection) { _, tab in
            activations[tab, default: 0] += 1 // the page's activation event
        }
    }

    /// Posed without changing the page's structural branch (#175).
    private func page(_ tab: JournalTab) -> some View {
        let incoming = machine.turn?.incoming == tab
        return makePage(tab, activations[tab] ?? 0)
            .modifier(HingeTurnPose(direction: machine.turn?.direction ?? .forward,
                                    progress: machine.turn?.progress ?? 0,
                                    isIncoming: incoming,
                                    isActive: tab == active))
            .allowsHitTesting(owns(tab))
            .disabled(!owns(tab))
            .accessibilityHidden(!owns(tab))
            .zIndex(incoming ? 1 : 0)
            .transition(.opacity) // Reduce Motion cross-fade (#111 AC2)
    }

    /// Issue #176 — the declared active page owns interaction unless an overlay covers it.
    private func owns(_ tab: JournalTab) -> Bool {
        !overlayCoversPages && tab == pager.selection
    }
}

private struct AuthenticatedDashboardView: View {
    @StateObject private var viewModel: DashboardViewModel
    @StateObject private var pager = JournalPagerModel()
    @StateObject private var routeModel = JournalRouteModel()
    @StateObject private var menuLibrary: MenuLibraryModel
    @StateObject private var diary: JournalCalendarModel
    @State private var showingCalendar = false
    /// Shell-owned presentations survive page turns (#176).
    @StateObject private var presentations = JournalPresentationModel()
    @State private var showingSettings = false
    @State private var showingOnboarding = false
    @StateObject private var pageTurnMachine = JournalTurnMachine()
    @AppStorage(MorselAppearance.themePreferenceKey)
    private var themePreferenceRaw = MorselAppearance.defaultThemePreference.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var coverColorScheme: ColorScheme? {
        MorselAppearance.scheme(for: MorselThemePreference(rawValue: themePreferenceRaw) ?? .paper)
    }

    let mcpEndpoint: String
    let session: AuthenticatedSession
    let auth: any SupabaseAuthenticating
    let onSignOut: () -> Void
    private let reliability: AccountReliabilityServices?
    private let fallbackImporter: HealthKitWeightImporter?
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
            _viewModel = StateObject(wrappedValue: DashboardViewModel(
                repository: services.repository, userID: session.userID,
                weightImporter: services.importer, healthStore: services.healthStore,
                syncEngine: services.engine))
            _menuLibrary = StateObject(wrappedValue: MenuLibraryModel(
                repository: services.repository, userID: session.userID))
            _diary = StateObject(wrappedValue: JournalCalendarModel(
                repository: services.repository, userID: session.userID))
        } else {
            let remote = SupabaseDashboardRepository(client: supabaseClient)
            let importer = supabaseClient.flatMap {
                try? HealthKitWeightImporter(store: SupabaseWeightLogStore(client: $0, userID: session.userID))
            }
            fallback = importer
            _viewModel = StateObject(wrappedValue: DashboardViewModel(
                repository: remote, userID: session.userID, weightImporter: importer))
            _menuLibrary = StateObject(wrappedValue: MenuLibraryModel(
                repository: remote, userID: session.userID))
            _diary = StateObject(wrappedValue: JournalCalendarModel(
                repository: remote, userID: session.userID))
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
                        onOpenMenus: { routeModel.openMenus() },
                        targetDate: viewModel.selectedDate
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
        // The shell owns presentations; the model environment wraps their anchors.
        .sheet(isPresented: $showingCalendar) {
            JournalCalendarSheet(model: diary, selectedDate: viewModel.selectedDate) { date in
                viewModel.selectDate(date)
                pager.select(.today)
            }
            .preferredColorScheme(coverColorScheme)
        }
        .journalPresentations(presentations, viewModel: viewModel)
        .environmentObject(viewModel).trainingFuel(viewModel: viewModel)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.3),
                   value: routeModel.isPresentingAddMeal)
        .task {
            if let timezoneSync { Task { await timezoneSync.syncIfChanged() } }
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
            // The stage owns activation; refresh Today's shared model on return.
            if oldTab != newTab, newTab == .today {
                Task { await viewModel.load() }
            }
        }
    }

    private func closeAddMeal() { routeModel.closeAddMeal() }
    @ViewBuilder
    private var pageContent: some View {
        if reduceMotion {
            journalPage(for: pager.selection)
                .transition(.opacity)
                .environmentObject(pageTurnMachine)
        } else {
            JournalPageTurner(pager: pager) { tab in
                journalPage(for: tab)
            }
        }
    }

    /// The stage retains pages; route overlays own interaction (#175/#176).
    private func journalPage(for tab: JournalTab) -> some View {
        JournalPageStage(pager: pager, active: tab,
                         overlayCoversPages: routeModel.route != .tabPages) { pageTab, activation in
            journalPrimaryPage(for: pageTab, activation: activation)
        }
    }
    @ViewBuilder
    private func journalPrimaryPage(for tab: JournalTab, activation: Int) -> some View {
        switch tab {
        case .today:
            MorselActionTint {
                JournalDiaryPage(model: viewModel, calendar: diary,
                                 isActive: pager.selection == .today && routeModel.route == .tabPages
                                    && !presentations.isPresenting && !showingCalendar && !showingSettings,
                                 openCalendar: { showingCalendar = true }, content: {
                    TodayView(viewModel: viewModel, presentations: presentations,
                              showSettings: { showingSettings = true },
                              addMeal: { routeModel.openAddMeal() })
                })
            }
        case .history:
            MorselActionTint {
                HistoryView(repository: viewModel.repository,
                            userID: viewModel.userID,
                            reloadKey: activation, diary: diary, selectedDate: viewModel.selectedDate) { date in
                    viewModel.selectDate(date)
                    pager.select(.today)
                }
            }
        case .goals:
            MorselActionTint {
                GoalsView(repository: viewModel.repository,
                          userID: viewModel.userID,
                          reloadKey: activation,
                          onSaved: { await viewModel.load() },
                          seeToday: { pager.select(.today) })
            }
        }
    }
}

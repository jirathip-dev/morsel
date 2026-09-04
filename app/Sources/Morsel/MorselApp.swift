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
                // Issue #54: every unauthenticated surface carries the V1
                // orange action tint so tint-dependent controls never fall
                // back to iOS system blue.
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
    @StateObject private var pager = JournalPagerModel()
    @StateObject private var routeModel = JournalRouteModel()
    @State private var showingSettings = false
    @State private var showingOnboarding = false
    @State private var tabReloadCounts: [JournalTab: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                JournalTabBar(pager: pager)
            }
            // Issue #105 AC3: Add Meal is a full journal page inside the flow
            // (route, never the primary .sheet). The cover turns in from the
            // trailing edge like the next journal leaf; Reduce Motion and
            // VoiceOver get the plain fade fallback.
            if routeModel.isPresentingAddMeal {
                MorselActionTint {
                    AddMealView(viewModel: viewModel, onClose: closeAddMeal)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.3),
            value: routeModel.isPresentingAddMeal
        )
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
        .onChange(of: pager.selection) { oldTab, newTab in
            // A tab change while the Add Meal cover is up returns to the
            // tabbed journal (defensive; the cover hides the bar).
            if routeModel.isPresentingAddMeal {
                routeModel.closeAddMeal()
            }
            // Page-turn revisit reloads the destination page (the #94 shell
            // recreated pages per tab visit; the persistent pager reloads
            // explicitly so History's today row and Goals stay fresh).
            if oldTab != newTab {
                tabReloadCounts[newTab, default: 0] += 1
                if newTab == .today {
                    Task { await viewModel.load() }
                }
            }
        }
    }

    private func closeAddMeal() {
        routeModel.closeAddMeal()
    }

    /// Single selection binding for the pager: bar taps, swipe settlements,
    /// and the Reduce-Motion content swap all funnel through the model so the
    /// page content and the active tab word update in one state pass (AC1).
    private var selectionBinding: Binding<JournalTab> {
        Binding(
            get: { pager.selection },
            set: { pager.select($0) }
        )
    }

    /// The journal page-turn pager (AC1/AC2): the three primary pages sit in
    /// a native page-style TabView so a horizontal swipe on page content
    /// moves to the adjacent tab with the same transition a tab tap
    /// animates. Content order equals `JournalTab.allCases` (pinned by
    /// AppearanceThemeTests), so page-turn direction and the tab bar always
    /// agree. Under Reduce Motion / VoiceOver the pager collapses to a plain
    /// content swap — no 3D or sliding page behavior.
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

    /// One pager page per primary tab (MorselActionTint keeps every tab's
    /// actions on the V1 orange anchor).
    @ViewBuilder
    private func journalPage(for tab: JournalTab) -> some View {
        switch tab {
        case .today:
            MorselActionTint {
                TodayView(
                    viewModel: viewModel,
                    showSettings: { showingSettings = true },
                    addMeal: { routeModel.openAddMeal() }
                )
            }
        case .history:
            MorselActionTint {
                HistoryView(
                    repository: viewModel.repository,
                    userID: viewModel.userID,
                    reloadKey: tabReloadCounts[.history] ?? 0
                )
            }
        case .goals:
            MorselActionTint {
                GoalsView(
                    repository: viewModel.repository,
                    userID: viewModel.userID,
                    onSaved: { await viewModel.load() },
                    seeToday: { pager.select(.today) }
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
/// SwiftUI behavior, no browser pill. Taps route through the shared pager
/// model (single selection source for content and indicator — AC1) and resign
/// any open keyboard (AC6: a tab tap clears focus).
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

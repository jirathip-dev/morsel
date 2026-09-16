import Supabase
import SwiftUI
import UIKit
import XCTest
@testable import Morsel

/// Issue #258 — rendered-state evidence for the two honest day-read states the
/// issue asks for: the day is CACHED after a failed refresh (labelled cached,
/// with the last successful load time and a retry), and the day read DEGRADED
/// (meals still render, one of them says its items could not be read).
///
/// Both fixtures compose `LocalFirstDashboardRepository` with the production
/// `SupabaseDashboardRepository` through controlled transport and temporary
/// account-scoped SQLite. Fictional meals, no network or production writes.
/// Captures are XCTest attachments; the committed PNGs are that run's
/// exported attachments (`258-<theme>-<state>`).

@MainActor
final class DayReadDegradeEvidenceTests: XCTestCase {
    private let account = UUID(uuidString: "47474747-4747-4747-8747-474747474747") ?? UUID()
    private let lunchID = "48484848-4848-4848-8848-484848484848"
    private let dinnerID = "49494949-4949-4949-8949-494949494949"
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-258-evidence-\(UUID().uuidString)", isDirectory: true)
    private let referenceInstant = ISO8601DateFormatter().date(from: "2026-09-05T04:00:00Z") ?? Date()

    override func setUp() {
        super.setUp()
        StubTransport.reset()
    }

    override func tearDown() async throws {
        // Drain the restored capture window before the next test (the pasteboard
        // deadlock #241 found when the mount work outlived the test).
        try await Task.sleep(for: .milliseconds(500))
        StubTransport.release()
        StubTransport.reset()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testCachedAndIncompleteDayReadStatesInPaperAndNight() async throws {
        MorselFontCatalog.register()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for (theme, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            for state in ["stale", "degraded"] {
                StubTransport.reset()
                let fixture = try await fixture(state)
                let page = AnyView(VStack(spacing: 0) {
                    TodayView(viewModel: fixture.viewModel, showSettings: {}, addMeal: {})
                    JournalTabBar(pager: JournalPagerModel())
                }
                .environmentObject(fixture.fuel)
                .environment(\.trainingFuelHosted, true))
                window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                window.rootViewController = UIHostingController(rootView: page.preferredColorScheme(scheme))
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(400))
                window.layoutIfNeeded()
                let name = "258-\(theme)-\(state)"
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                print("DAYREAD_CAPTURE_READY \(name)")
                // The state on screen is asserted, not assumed: a capture of
                // the wrong state would be a silent lie.
                switch state {
                case "stale":
                    XCTAssertTrue(fixture.viewModel.isShowingCachedDay)
                    XCTAssertEqual(fixture.viewModel.lastLoadedAt, referenceInstant)
                    XCTAssertEqual(fixture.viewModel.incompleteMealCount, 0)
                default:
                    XCTAssertFalse(fixture.viewModel.isShowingCachedDay)
                    XCTAssertEqual(fixture.viewModel.incompleteMealCount, 1)
                }
                XCTAssertEqual(fixture.viewModel.snapshot?.meals.count, 2)
            }
        }
    }

    // MARK: - Fixtures

    private func fixture(_ state: String) async throws -> (viewModel: DashboardViewModel, fuel: TrainingFuelModel) {
        StubTransport.respond("meal_logs", .init(body: mealLogsBody()))
        StubTransport.respond("meal_items", .init(body: itemRowsBody(corruptDinner: state == "degraded")))
        let database = LocalDataStore.storeURL(root: directory, accountID: UUID())
        let repository = LocalFirstDashboardRepository(
            remote: try await makeRepository(), store: try LocalDataStore(databaseURL: database),
            snapshotCache: try LocalSnapshotCache(databaseURL: database), dateProvider: { self.referenceInstant }
        )
        var now = referenceInstant
        let viewModel = DashboardViewModel(repository: repository, userID: account, dateProvider: { now })
        await viewModel.load()
        // The fuel model shares the fixture clock so the day is genuinely
        // "today" for the hero (a real clock would render every fixture day
        // as a past day whose target is unavailable).
        let fuel = TrainingFuelModel(now: { self.referenceInstant })
        if let snapshot = viewModel.snapshot {
            fuel.synchronize(snapshot)
        }
        if state == "stale" {
            // The refresh now fails outright (the day read itself): the day on
            // screen is the last good copy and must say so.
            StubTransport.respond("meal_logs", .init(status: 500, body: "{\"message\":\"permission denied\"}"))
            now = referenceInstant.addingTimeInterval(7_200)
            await viewModel.load()
        }
        return (viewModel, fuel)
    }

    private func mealLogsBody() -> String {
        """
        [{"id":"\(lunchID)","eaten_at":"2026-09-05T03:30:00Z","meal_type":"lunch",\
        "source":"manual","image_path":null},
        {"id":"\(dinnerID)","eaten_at":"2026-09-05T12:00:00Z","meal_type":"dinner",\
        "source":"manual","image_path":null}]
        """
    }

    /// Two meals with items; the dinner's row is corrupt when
    /// `corruptDinner` is set, so that ONE row degrades only its own meal.
    private func itemRowsBody(corruptDinner: Bool) -> String {
        let lunch = """
        {"id":"50505050-5050-4050-8050-505050505050","meal_log_id":"\(lunchID)","name":"Jasmine rice",\
        "quantity":1,"unit":"serving","calories_kcal":420,"protein_g":8,"carbs_g":82,"fat_g":3,\
        "fiber_g":4,"sugar_g":1,"confidence":0.9,"source_notes":null,"menu_group_id":null,\
        "menu_name":null,"artwork_id":null}
        """
        let dinner = """
        {"id":"51515151-5151-4151-8151-515151515151","meal_log_id":"\(dinnerID)","name":"Green curry",\
        "quantity":1,"unit":"\(corruptDinner ? "furlongs" : "serving")","calories_kcal":610,\
        "protein_g":28,"carbs_g":24,"fat_g":44,"fiber_g":6,"sugar_g":5,"confidence":0.8,\
        "source_notes":null,"menu_group_id":null,"menu_name":null,"artwork_id":null}
        """
        let salad = """
        {"id":"52525252-5252-4252-8252-525252525252","meal_log_id":"\(dinnerID)","name":"Som tam",\
        "quantity":1,"unit":"serving","calories_kcal":150,"protein_g":4,"carbs_g":18,"fat_g":7,\
        "fiber_g":3,"sugar_g":9,"confidence":0.7,"source_notes":null,"menu_group_id":null,\
        "menu_name":null,"artwork_id":null}
        """
        return "[\(lunch),\(dinner),\(salad)]"
    }

    private func makeRepository() async throws -> SupabaseDashboardRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        configuration.urlCache = nil
        let client = SupabaseClient(
            supabaseURL: try XCTUnwrap(URL(string: "https://day-read-evidence.supabase.test")),
            supabaseKey: "stub-anon-key",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: StubSessionStorage(userID: account, expiresAt: Date().addingTimeInterval(3_600)),
                    storageKey: "sb-stub-auth-token", autoRefreshToken: false
                ),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
        _ = try await client.auth.session
        return SupabaseDashboardRepository(client: client)
    }
}

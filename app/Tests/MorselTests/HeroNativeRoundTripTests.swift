import Supabase
import XCTest
@testable import Morsel

private struct HeroBridge: Decodable {
    let url: URL
    let userID: UUID
}

@MainActor
final class HeroNativeRoundTripTests: XCTestCase {
    func testNativeWriteTriggerReadAndRenderedHero() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ready = root.appendingPathComponent(".lane-logs/hero-native/ready.json")
        guard FileManager.default.fileExists(atPath: ready.path) else {
            throw XCTSkip("Opt-in real PostgreSQL bridge: npx vitest run --config db/hero-native.config.ts")
        }
        let bridge = try JSONDecoder().decode(HeroBridge.self, from: Data(contentsOf: ready))
        XCTAssertEqual(bridge.url.host, "127.0.0.1", "never contact a production service")
        guard bridge.url.host == "127.0.0.1" else { return }
        let repository = try await makeRepository(bridge)
        let pastGoal = DashboardGoal(calorieTargetKcal: 2_400, proteinG: 140, carbsG: 280, fatG: 90, source: .manual)
        // This is the existing native writer, not a fabricated target-history insert.
        try await repository.saveGoals(userID: bridge.userID, goal: pastGoal)
        let params = DatedTargetAdditionParams(userID: bridge.userID, date: "2026-09-16",
            timezone: Calendar.autoupdatingCurrent.timeZone.identifier, additionKcal: 120,
            mutationID: UUID(), expectedRevision: nil, historicalConfirmation: false, manualGoalAcknowledged: true)
        let saved = try await repository.saveDatedTargetAddition(params)
        XCTAssertEqual(saved.totalTargetKcal, 2_520)
        XCTAssertNotNil(saved.baseline?.revisionID)
        try await request("advance-day", bridge: bridge)
        try await repository.saveGoals(userID: bridge.userID, goal: HeroTargetFixture.currentGoal)
        // A new client reads committed SQL, not the writer's in-memory value.
        let restarted = try await makeRepository(bridge)
        let past = try await restarted.loadToday(userID: bridge.userID, date: HeroTargetFixture.past)
        XCTAssertEqual(DashboardMath.totals(for: past.meals).caloriesKcal, 1_953)
        XCTAssertEqual(past.datedTarget?.totalTargetKcal, 2_520)
        XCTAssertEqual(past.datedTarget?.baseline?.revisionID, saved.baseline?.revisionID)
        XCTAssertEqual(past.datedTarget?.baseline?.goal.proteinG, 140)
        XCTAssertEqual(past.goal?.calorieTargetKcal, 3_000, "current goal is deliberately different")
        let unavailable = try await restarted.loadToday(userID: bridge.userID,
                                                        date: HeroTargetFixture.past.addingTimeInterval(-86_400))
        XCTAssertNil(unavailable.datedTarget?.baseline)
        XCTAssertNil(unavailable.datedTarget?.totalTargetKcal)
        for (theme, scheme) in HeroTargetFixture.themes {
            let image = try await HeroTargetFixture.capture(past, scheme: scheme)
            let text = try WeightDeltaRendering.recognizedText(image)
            XCTAssertTrue(text.contains("2,520") && text.contains("140"), text)
            XCTAssertFalse(text.contains("3,000"), text)
            HeroTargetFixture.attach(image, name: "286-live-\(theme)-past-saved", to: self)
        }
        print("HERO-NATIVE: write 2400 + 120 -> new client read 2520; current 3000; pre-capture unavailable")
        try await request("finish", bridge: bridge)
    }

    private func makeRepository(_ bridge: HeroBridge) async throws -> SupabaseDashboardRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let client = SupabaseClient(supabaseURL: bridge.url, supabaseKey: "stub-anon-key",
            options: .init(auth: .init(
                storage: StubSessionStorage(userID: bridge.userID, expiresAt: Date().addingTimeInterval(3_600)),
                storageKey: "sb-stub-auth-token", autoRefreshToken: false),
                global: .init(session: URLSession(configuration: configuration))))
        _ = try await client.auth.session
        return SupabaseDashboardRepository(client: client)
    }

    private func request(_ path: String, bridge: HeroBridge) async throws {
        var request = URLRequest(url: bridge.url.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer stub-access-token", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}

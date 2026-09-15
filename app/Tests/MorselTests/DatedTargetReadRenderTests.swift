import Supabase
import SwiftUI
import XCTest
@testable import Morsel

private struct Readback: Decodable {
    let userID: UUID
    let timezone: String
    let today: String
    let days: [ServerDay]
    enum CodingKeys: String, CodingKey { case userID = "user_id", timezone, today, days }
}
private struct ServerDay: Decodable {
    let date: String
    let totals: Calories
    let datedTarget: DatedTarget?
    enum CodingKeys: String, CodingKey { case date, totals, datedTarget = "dated_target" }
}
private struct Calories: Decodable {
    let calories: Double
    enum CodingKeys: String, CodingKey { case calories = "calories_kcal" }
}
private struct Bridge: Decodable { let url: URL }

/// Normal gates replay genuine SQL readback through URLSession; the dedicated
/// evidence run points the SAME production repository at a running local DB.
@MainActor
final class DatedTargetReadRenderTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testRealReadContractReachesNativeAdapterAndPaperNightChart() async throws {
        let data = try Data(contentsOf: root.appendingPathComponent("docs/evidence/issue-253/local-db-readback.json"))
        let readback = try JSONDecoder().decode(Readback.self, from: data)
        let ready = root.appendingPathComponent(".lane-logs/dated-native/ready.json")
        let bridge = FileManager.default.fileExists(atPath: ready.path)
            ? try JSONDecoder().decode(Bridge.self, from: Data(contentsOf: ready)) : nil
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: readback.timezone))
        let today = try XCTUnwrap(MorselDate.date(readback.today))
        let repository = try await repository(readback: data, userID: readback.userID, bridge: bridge)
        defer { StubTransport.reset() }
        let overview = try await repository.loadHistory(userID: readback.userID, end: today, days: 5,
                                                        calendar: calendar)
        let expected = try await serverDays(bridge: bridge, fallback: readback.days)
        try assertContract(overview: overview, expected: expected, calendar: calendar)
        let days = overview.days.map { WeightDeltaDay(day: $0, calendar: calendar) }
        try capture(overview: overview, days: days, today: today, live: bridge != nil)
        if bridge != nil {
            try Data("native read and Paper/Night render passed\n".utf8)
                .write(to: root.appendingPathComponent(".lane-logs/dated-native/done"))
        }
        let mode = bridge == nil ? "SQL-readback replay" : "LIVE local PostgreSQL"
        print("ISSUE253-PATH \(mode) -> server contract -> native repository -> adapter -> Paper/Night")
    }

    func testRejectsCurrentOrMisattributedSnapshots() throws {
        let bytes = try Data(contentsOf: root.appendingPathComponent("docs/evidence/issue-253/local-db-readback.json"))
        let readback = try JSONDecoder().decode(Readback.self, from: bytes)
        let target = try XCTUnwrap(readback.days[1].datedTarget)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: readback.timezone))
        let day = try XCTUnwrap(MorselDate.date("2026-03-07T12:00:00Z"))
        XCTAssertEqual(target.attributableTotal(on: day, calendar: calendar), 2_250)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any])
        for (key, value) in [("recorded_at", "2026-03-10T12:00:00Z"), ("source_version", "unknown"),
                             ("effective_date", "2020-01-01")] {
            var altered = original
            var baseline = try XCTUnwrap(original["baseline"] as? [String: Any])
            baseline[key] = value
            altered["baseline"] = baseline
            let decoded = try JSONDecoder().decode(DatedTarget.self,
                from: JSONSerialization.data(withJSONObject: altered))
            XCTAssertNil(decoded.attributableTotal(on: day, calendar: calendar), key)
        }
        var foreignCalendar = calendar
        foreignCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        XCTAssertNil(target.attributableTotal(on: day, calendar: foreignCalendar))
    }

    private func assertContract(overview: HistoryOverview, expected: [ServerDay], calendar: Calendar) throws {
        XCTAssertEqual(overview.days.count, 5)
        XCTAssertEqual(expected.count, 5)
        for (day, server) in zip(overview.days, expected) {
            XCTAssertEqual(DatedTarget.label(day.date, calendar: calendar), server.date)
            XCTAssertEqual(day.eatenKcal, server.totals.calories)
            XCTAssertEqual(day.datedTarget, server.datedTarget)
            let adapter = WeightDeltaDay(day: day, calendar: calendar)
            if let target = server.datedTarget?.totalTargetKcal, day.logged {
                XCTAssertEqual(adapter.deltaKcal, day.eatenKcal - target)
            } else {
                XCTAssertNil(adapter.deltaKcal)
            }
        }
        XCTAssertNil(WeightDeltaDay(day: overview.days[0], calendar: calendar).deltaKcal,
                     "an unrelated current goal must never make missing historical provenance usable")
        XCTAssertEqual(WeightDeltaDay(day: overview.days[1], calendar: calendar).deltaKcal, -2_250)
        XCTAssertEqual(WeightDeltaDay(day: overview.days[2], calendar: calendar).deltaKcal, 0)
        XCTAssertFalse(overview.days[3].logged)
        XCTAssertEqual(overview.days[4].datedTarget?.confirmedAdditionKcal, 200)
        XCTAssertNotEqual(overview.goal?.calorieTargetKcal, overview.days[1].datedTarget?.totalTargetKcal)
        // A legacy cached HistoryDay without the additive key still decodes.
        let legacyData = Data("{\"date\":0,\"eatenKcal\":0,\"logged\":true}".utf8)
        let legacy = try JSONDecoder().decode(HistoryDay.self, from: legacyData)
        XCTAssertNil(WeightDeltaDay(day: legacy).deltaKcal)
    }

    private func repository(readback: Data, userID: UUID, bridge: Bridge?) async throws
        -> SupabaseDashboardRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        if bridge == nil {
            StubTransport.reset()
            configuration.protocolClasses = [StubTransport.self]
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: readback) as? [String: Any])
            let native = try XCTUnwrap(object["native"] as? [String: Any])
            for endpoint in ["profiles", "goals", "weight_logs", "meal_logs", "meal_items", "get_dated_targets"] {
                let value = try XCTUnwrap(native[endpoint])
                let rows: Any = value is [String: Any] ? [value] : value
                let bytes = try JSONSerialization.data(withJSONObject: rows)
                StubTransport.respond(endpoint, .init(body: try XCTUnwrap(String(data: bytes, encoding: .utf8))))
            }
        }
        let client = SupabaseClient(
            supabaseURL: try XCTUnwrap(bridge?.url ?? URL(string: "https://stub.supabase.test")),
            supabaseKey: "stub-anon-key",
            options: .init(auth: .init(
                storage: StubSessionStorage(userID: userID, expiresAt: Date().addingTimeInterval(3600)),
                storageKey: "sb-stub-auth-token", autoRefreshToken: false),
                global: .init(session: URLSession(configuration: configuration)))
        )
        _ = try await client.auth.session
        return SupabaseDashboardRepository(client: client)
    }

    private func serverDays(bridge: Bridge?, fallback: [ServerDay]) async throws -> [ServerDay] {
        guard let bridge else { return fallback }
        var request = URLRequest(url: bridge.url.appendingPathComponent("server-readback"))
        request.setValue("Bearer stub-access-token", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode([ServerDay].self, from: data)
    }

    private func capture(overview: HistoryOverview, days: [WeightDeltaDay], today: Date, live: Bool) throws {
        let directory = root.appendingPathComponent(".lane-logs/dated-native/captures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            let content = VStack(alignment: .leading, spacing: 16) {
                Text(live ? "LOCAL POSTGRES · SYNTHETIC ACCOUNT" : "REAL SQL READBACK · REPLAY")
                    .font(Font.morselMono(size: 10))
                Text("History").font(Font.morselHand(size: 32))
                V1WeightTrendView(points: overview.weightTrend, delta: nil, isThirtyDay: false,
                                  today: today, foodDays: days)
                Spacer(minLength: 0)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(Color.morselInk).background(Color.morselBackground)
            let image = try WeightDeltaRendering.render(content, size: CGSize(width: 393, height: 852), scheme: scheme)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
            let text = try WeightDeltaRendering.recognizedText(image).lowercased()
            XCTAssertTrue(text.contains("dated baseline"))
            XCTAssertTrue(text.contains("confirmed addition"))
            XCTAssertTrue(text.contains("partial day"))
            XCTAssertTrue(text.contains("explain weight changes"))
            XCTAssertTrue(text.contains("200"), "the confirmed addition must paint, not just decode")
            print("ISSUE253-CAPTURE \(name) \(text.replacingOccurrences(of: "\n", with: " | "))")
        }
    }
}

import Foundation
import Supabase
import XCTest
@testable import Morsel

// Issue #193 — shared support for the narrow ledger read lane. The stub speaks
// just enough PostgREST to be honest about the two things the ACs measure: the
// `select` projection each production request asks for, and the payload bytes
// that projection produces on identical fixture rows. It projects the SAME
// rows through the request's own `select`, so the delivered body — and its
// byte count — belongs to the real request; the baseline receipt is the same
// rows through the base pin's selects.

/// One fixture row as ordered raw JSON fragments: a dictionary would not give
/// a deterministic byte count, ordered fragments do.
struct LedgerFixtureRow {
    let fields: [(String, String)]

    init(_ fields: [(String, String)]) {
        self.fields = fields
    }

    func json(selecting columns: [String]?) -> String {
        let visible = columns.map { wanted in fields.filter { field in wanted.contains(field.0) } } ?? fields
        return "{" + visible.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }
}

/// A PostgREST-shaped stub at the URLSession seam.
final class LedgerStubTransport: URLProtocol {
    struct Recorded {
        let table: String
        let select: [String]
        let url: String
        let body: String

        var bytes: Int { body.utf8.count }
    }

    private static let lock = NSLock()
    private static var rowsByTable: [String: [LedgerFixtureRow]] = [:]
    private static var bodiesByTable: [String: String] = [:]
    private static var recorded: [Recorded] = []

    static func configure(_ fixture: LedgerFixture) {
        lock.lock()
        defer { lock.unlock() }
        rowsByTable = ["meal_logs": fixture.mealRows, "meal_items": fixture.itemRows]
        bodiesByTable = [
            "goals": fixture.goalsBody, "profiles": fixture.profilesBody,
            "weight_logs": fixture.weightRowsBody
        ]
        recorded = []
    }

    static func records(_ table: String) -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0.table == table }
    }

    /// The identical rows projected through `columns` — the baseline receipt.
    static func projectedBody(_ table: String, selecting columns: [String]) -> String {
        lock.lock()
        defer { lock.unlock() }
        return payload(table: table, columns: columns)
    }

    static override func canInit(with request: URLRequest) -> Bool { true }

    static override func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.deliver(table: Self.tableName(url.path), columns: Self.selectColumns(url), url: url)
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func deliver(table: String, columns: [String]?, url: URL) -> String {
        lock.lock()
        defer { lock.unlock() }
        let body = payload(table: table, columns: columns)
        recorded.append(Recorded(table: table, select: columns ?? [], url: url.absoluteString, body: body))
        return body
    }

    /// Table requests answer the projected rows; every other path (the
    /// dated-target RPC) answers the configured fallback.
    private static func payload(table: String, columns: [String]?) -> String {
        if let rows = rowsByTable[table] {
            return "[" + rows.map { $0.json(selecting: columns) }.joined(separator: ",") + "]"
        }
        return bodiesByTable[table] ?? "[]"
    }

    private static func tableName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func selectColumns(_ url: URL) -> [String]? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let select = items.first(where: { $0.name == "select" })?.value else { return nil }
        return select.split(separator: ",").map(String.init)
    }
}

struct LedgerMealFixture {
    let id: String
    let eatenAt: String
    let imagePath: String?
}

struct LedgerItemFixture {
    let id: String
    let mealLogID: String
    /// `nil` is a logged row with no calorie value (PostgREST `null`).
    let caloriesKcal: Double?
    var menuName: String?
    var menuGroupID: String?
    var artworkID: String?

    /// The numeric column as PostgREST renders it (no trailing `.0`).
    var caloriesFragment: String {
        guard let caloriesKcal else { return "null" }
        return caloriesKcal == caloriesKcal.rounded() ? String(Int(caloriesKcal)) : String(caloriesKcal)
    }
}

/// One synthetic ledger fixture: the meal and item rows the stub serves, plus
/// the goal/profile/weight bodies the History read graph also touches.
struct LedgerFixture {
    let name: String
    let meals: [LedgerMealFixture]
    let items: [LedgerItemFixture]

    var goalsBody: String {
        "[{\"calorie_target_kcal\": 2000, \"protein_g\": 150, \"carbs_g\": 200, \"fat_g\": 60, "
            + "\"source\": \"manual\", \"updated_at\": \"2026-09-04T00:00:00.000Z\"}]"
    }

    /// No profile row: the stored complete manual goal is the effective goal —
    /// the same value the base pin produced on these fixtures.
    var profilesBody: String { "[]" }

    /// Two samples inside one whole second (whole-second dedupe keeps the later).
    var weightRowsBody: String {
        "[{\"measured_at\": \"2026-09-04T04:00:00.100Z\", \"kg\": 81.4}, "
            + "{\"measured_at\": \"2026-09-04T04:00:00.400Z\", \"kg\": 81.2}]"
    }

    /// The full meal-log row the base pin transferred (rich projection).
    var mealRows: [LedgerFixtureRow] {
        meals.map { meal in
            LedgerFixtureRow([
                ("id", "\"\(meal.id)\""),
                ("eaten_at", "\"\(meal.eatenAt)\""),
                ("meal_type", "\"lunch\""),
                ("source", "\"manual\""),
                ("image_path", meal.imagePath.map { "\"\($0)\"" } ?? "null")
            ])
        }
    }

    /// The full item row the base pin transferred (the shared rich projection).
    var itemRows: [LedgerFixtureRow] {
        items.map { item in
            LedgerFixtureRow([
                ("id", "\"\(item.id)\""),
                ("meal_log_id", "\"\(item.mealLogID)\""),
                ("name", "\"Synthetic bowl \(item.id.prefix(8))\""),
                ("quantity", "1.5"),
                ("unit", "\"serving\""),
                ("calories_kcal", item.caloriesFragment),
                ("protein_g", "42"),
                ("carbs_g", "31"),
                ("fat_g", "12"),
                ("fiber_g", "4"),
                ("sugar_g", "6"),
                ("confidence", "0.9"),
                ("source_notes", "\"synthetic note\""),
                ("menu_group_id", item.menuGroupID.map { "\"\($0)\"" } ?? "null"),
                ("menu_name", item.menuName.map { "\"\($0)\"" } ?? "null"),
                ("artwork_id", item.artworkID.map { "\"\($0)\"" } ?? "null")
            ])
        }
    }
}

extension LedgerFixture {
    static func mealID(_ number: Int) -> String { "1111111\(number)-1111-4111-8111-111111111111" }

    static func itemID(_ number: Int) -> String { "2222222\(number)-2222-4222-8222-222222222222" }

    static func meal(_ number: Int, at eatenAt: String, image: String? = nil) -> LedgerMealFixture {
        LedgerMealFixture(id: mealID(number), eatenAt: eatenAt, imagePath: image)
    }

    static func item(
        _ number: Int, meal: Int, kcal: Double?, menuName: String? = nil,
        menuGroupID: String? = nil, artworkID: String? = nil
    ) -> LedgerItemFixture {
        LedgerItemFixture(
            id: itemID(number), mealLogID: mealID(meal), caloriesKcal: kcal,
            menuName: menuName, menuGroupID: menuGroupID, artworkID: artworkID
        )
    }

    static let emptyDays = LedgerFixture(name: "empty days", meals: [], items: [])

    /// A meal whose only calorie value is `null` next to one with calories.
    static let nullCalories = LedgerFixture(
        name: "null calories",
        meals: [meal(1, at: "2026-09-02T02:00:00.000Z")],
        items: [
            item(1, meal: 1, kcal: nil),
            item(2, meal: 1, kcal: 120)
        ]
    )

    static let multipleMeals = LedgerFixture(
        name: "multiple meals",
        meals: [
            meal(1, at: "2026-09-01T20:00:00.000Z"),
            meal(2, at: "2026-09-02T02:00:00.000Z"),
            meal(3, at: "2026-09-02T03:00:00.000Z"),
            meal(4, at: "2026-09-03T06:00:00.000Z")
        ],
        items: [
            item(1, meal: 1, kcal: 420),
            item(2, meal: 2, kcal: nil),
            item(3, meal: 2, kcal: 180),
            item(4, meal: 3, kcal: 95.5),
            item(5, meal: 4, kcal: 300)
        ]
    )

    static let menuSnapshot = LedgerFixture(
        name: "named-menu snapshot",
        meals: [meal(1, at: "2026-09-02T02:00:00.000Z")],
        items: [
            item(1, meal: 1, kcal: 640, menuName: "Chipotle bowl",
                 menuGroupID: "33333333-3333-4333-8333-333333333333",
                 artworkID: "44444444-4444-4444-8444-444444444444"),
            item(2, meal: 1, kcal: 160, menuName: "Chipotle bowl",
                 menuGroupID: "33333333-3333-4333-8333-333333333333",
                 artworkID: "44444444-4444-4444-8444-444444444444")
        ]
    )

    /// Two logged days whose calorie totals are zero (a null row, a 0 row).
    static let loggedAndZero = LedgerFixture(
        name: "logged-empty and zero-calorie",
        meals: [meal(1, at: "2026-09-01T20:00:00.000Z"), meal(2, at: "2026-09-02T20:00:00.000Z")],
        items: [item(1, meal: 1, kcal: nil), item(2, meal: 2, kcal: 0)]
    )

    /// 2026-03-08 spring forward in America/New_York: 01:30 EST and 03:30 EDT
    /// are the same (23-hour) local day.
    static let dstSpringForward = LedgerFixture(
        name: "DST spring forward",
        meals: [
            meal(1, at: "2026-03-07T06:30:00.000Z"),
            meal(2, at: "2026-03-08T06:30:00.000Z"),
            meal(3, at: "2026-03-08T07:30:00.000Z")
        ],
        items: [item(1, meal: 1, kcal: 300), item(2, meal: 2, kcal: 420), item(3, meal: 3, kcal: 120)]
    )

    /// 2026-11-01 fall back: 01:30 EDT and 01:30 EST are the same (25-hour)
    /// local day.
    static let dstFallBack = LedgerFixture(
        name: "DST fall back",
        meals: [
            meal(1, at: "2026-10-31T05:30:00.000Z"),
            meal(2, at: "2026-11-01T05:30:00.000Z"),
            meal(3, at: "2026-11-01T06:30:00.000Z")
        ],
        items: [item(1, meal: 1, kcal: 210), item(2, meal: 2, kcal: 330), item(3, meal: 3, kcal: 60)]
    )

    /// Fixture instants stay well inside the 7-day window for any host zone,
    /// so the parity cases never depend on the machine's timezone.
    static let aggregationCases = [emptyDays, nullCalories, multipleMeals, menuSnapshot, loggedAndZero]
}

/// The base-pin aggregation, computed from the identical fixture rows: every
/// item's `calories_kcal` summed per meal in `created_at` order (the fixture
/// order), then bucketed into LOCAL days (base `HistoryRepository` lines 47-70).
enum LedgerBaseline {
    struct Day: Equatable {
        let date: Date
        let kcal: Double
        let logged: Bool
    }

    static func days(_ fixture: LedgerFixture, end: Date, count: Int, calendar: Calendar) -> [Day] {
        let endStart = calendar.startOfDay(for: end)
        let clamped = min(max(count, 1), 31)
        guard let start = calendar.date(byAdding: .day, value: -(clamped - 1), to: endStart),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: endStart) else {
            return []
        }
        var kcalByMealID: [String: Double] = [:]
        for item in fixture.items {
            kcalByMealID[item.mealLogID, default: 0] += item.caloriesKcal ?? 0
        }
        var mealCountByDay: [Date: Int] = [:]
        var kcalByDay: [Date: Double] = [:]
        for meal in fixture.meals {
            guard let eatenAt = MorselDate.date(meal.eatenAt) else { continue }
            let day = calendar.startOfDay(for: eatenAt)
            mealCountByDay[day, default: 0] += 1
            kcalByDay[day, default: 0] += kcalByMealID[meal.id] ?? 0
        }
        var days: [Day] = []
        var day = start
        while day < nextDay {
            let logged = (mealCountByDay[day] ?? 0) > 0
            days.append(Day(date: day, kcal: logged ? (kcalByDay[day] ?? 0) : 0, logged: logged))
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = following
        }
        return days
    }
}

/// The comparable shape of one ledger day, from either side of the parity
/// comparison (production `HistoryDay` or the baseline).
struct LedgerDayValue: Equatable {
    let date: Date
    let kcal: Double
    let logged: Bool

    init(_ day: HistoryDay) {
        date = day.date
        kcal = day.eatenKcal
        logged = day.logged
    }

    init(_ day: LedgerBaseline.Day) {
        date = day.date
        kcal = day.kcal
        logged = day.logged
    }
}

/// Shared setup: the synthetic account, the repo's local-day fixture instant,
/// and the repository built on the projecting transport.
class LedgerNarrowTestCase: XCTestCase {
    let account = UUID()
    /// 2026-09-05 04:00Z — the repo's local-day fixture instant (11:00 +07).
    let referenceInstant = MorselDate.date("2026-09-05T04:00:00Z") ?? Date()

    override func setUp() {
        super.setUp()
        LedgerStubTransport.configure(.emptyDays)
    }

    func instant(_ value: String) -> Date {
        MorselDate.date(value) ?? Date()
    }

    func repository() async throws -> SupabaseDashboardRepository {
        guard let baseURL = URL(string: "https://stub.supabase.test") else {
            throw MorselError.invalidData("stub base URL must be valid")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LedgerStubTransport.self]
        configuration.urlCache = nil
        let client = SupabaseClient(
            supabaseURL: baseURL, supabaseKey: "stub-anon-key",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: StubSessionStorage(userID: account, expiresAt: Date().addingTimeInterval(3600)),
                    storageKey: "sb-stub-auth-token", autoRefreshToken: false
                ),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
        // Exercise the real session seam before the read (as the #178 suite does).
        _ = try await client.auth.session
        return SupabaseDashboardRepository(client: client)
    }
}

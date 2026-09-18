import Foundation
import Supabase
import XCTest
@testable import Morsel

// Issue #194 — shared support for the bounded-paging lane: a PostgREST-shaped
// transport that ENFORCES a small row cap per response, exactly like a
// deployment whose `db-max-rows` is small. A read that asks for "everything"
// (or asks for more rows than the cap) therefore sees only the prefix the cap
// allows; a read that pages to completion sees the whole collection. Ranged
// responses report the span they covered in `Content-Range`, which is how
// PostgREST signals a partial response. Every request is recorded with the
// parameters the ACs measure (select, order, offset, limit, an `in.(...)`
// chunk's ids and the rows the server actually delivered).

/// The capped transport at the real URLSession seam.
final class CappedReadTransport: URLProtocol {
    enum Phase { case started, finished, cancelled }

    struct Event {
        let sequence: Int
        let table: String
        let phase: Phase
    }

    struct Recorded {
        let table: String
        let url: String
        let select: [String]
        let order: String?
        let offset: Int?
        let limit: Int?
        let ids: [String]
        let delivered: [String]
        let bytes: Int
        let status: Int
    }

    /// A table's rows plus the plans a test can arm on it.
    struct Table {
        var rows: [CappedRow] = []
        /// Every request at or after this offset fails with 500.
        var failFrom: Int?
        /// Every request at or after this offset parks until `release()`.
        var holdFrom: Int?
        /// Rows repeated at the start of every page after the first — the
        /// boundary row a concurrent update moved later in the order.
        var overlap = 0
    }

    struct Snapshot {
        let events: [Event]

        func count(_ phase: Phase, _ table: String) -> Int {
            events.filter { $0.phase == phase && $0.table == table }.count
        }

        /// The highest number of concurrent requests seen for one table.
        func peak(_ table: String) -> Int {
            var live = 0
            var highest = 0
            for event in events where event.table == table {
                live += event.phase == .started ? 1 : -1
                highest = max(highest, live)
            }
            return highest
        }

        var peakInFlight: Int {
            var live = 0
            var highest = 0
            for event in events {
                live += event.phase == .started ? 1 : -1
                highest = max(highest, live)
            }
            return highest
        }

        var inFlight: Int {
            events.reduce(0) { $0 + ($1.phase == .started ? 1 : -1) }
        }
    }

    private struct Served {
        let body: String
        let delivered: [String]
        let status: Int
        let contentRange: String?
    }

    private struct Handled {
        let record: Recorded
        let served: Served
        let park: Bool
    }

    private static let lock = NSLock()
    private static var tables: [String: Table] = [:]
    private static var bodies: [String: String] = [:]
    private static var cap = 3
    private static var recorded: [Recorded] = []
    private static var events: [Event] = []
    private static var live: [Int: String] = [:]
    private static var parked: [Int: CappedReadTransport] = [:]
    private static var sequence = 0

    private var requestID: Int?
    private var url: URL?
    private var table = ""

    /// Installs `fixture` and its row cap, clearing every recorded request.
    static func reset(_ fixture: CappedFixture, cap rowsPerResponse: Int) {
        lock.lock()
        defer { lock.unlock() }
        tables = [
            "meal_logs": Table(rows: fixture.meals), "meal_items": Table(rows: fixture.items),
            "weight_logs": Table(rows: fixture.weights), "meal_menus": Table(rows: fixture.menus),
            "menu_items": Table(rows: fixture.menuItems)
        ]
        bodies = fixture.bodies
        cap = rowsPerResponse
        recorded = []; events = []; live = [:]; parked = [:]
        sequence = 0
    }

    /// Arms a plan on one table.
    static func plan(_ table: String, failFrom: Int? = nil, holdFrom: Int? = nil, overlap: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        tables[table]?.failFrom = failFrom
        tables[table]?.holdFrom = holdFrom
        tables[table]?.overlap = overlap
    }

    /// Releases every parked request (optionally only one table's).
    static func release(_ table: String = "") {
        lock.lock()
        let targets = parked.filter { table.isEmpty || $0.value.table == table }
        for id in targets.keys {
            parked[id] = nil
        }
        lock.unlock()
        for (id, transport) in targets {
            guard let url = transport.url else { continue }
            deliver(id: id, transport: transport, handled: handle(table: transport.table, url: url, ignoringHold: true))
        }
    }

    static func records(_ table: String) -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0.table == table }
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(events: events)
    }

    static override func canInit(with request: URLRequest) -> Bool { true }

    static override func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        self.url = url
        table = Self.tableName(url.path)
        let id = Self.begin(table: table)
        requestID = id
        let handled = Self.handle(table: table, url: url, ignoringHold: false)
        guard !handled.park else {
            Self.lock.lock()
            Self.parked[id] = self
            Self.lock.unlock()
            return
        }
        Self.deliver(id: id, transport: self, handled: handled)
    }

    override func stopLoading() {
        if let requestID {
            Self.end(requestID, phase: .cancelled)
        }
    }

    private static func handle(table: String, url: URL, ignoringHold: Bool) -> Handled {
        lock.lock()
        defer { lock.unlock() }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let select = queryItems.first { $0.name == "select" }?.value?.split(separator: ",").map(String.init) ?? []
        let order = queryItems.first { $0.name == "order" }?.value
        let offset = queryItems.first { $0.name == "offset" }?.value.flatMap(Int.init)
        let limit = queryItems.first { $0.name == "limit" }?.value.flatMap(Int.init)
        let ids = chunkIDs(queryItems)
        let served = serve(table: table, ids: ids, offset: offset, limit: limit)
        let record = Recorded(
            table: table, url: url.absoluteString, select: select, order: order, offset: offset, limit: limit,
            ids: ids, delivered: served.delivered, bytes: served.body.utf8.count, status: served.status
        )
        let hold = !ignoringHold && (tables[table]?.holdFrom.map { (offset ?? 0) >= $0 } ?? false)
        return Handled(record: record, served: served, park: hold)
    }

    private static func serve(table: String, ids: [String], offset: Int?, limit: Int?) -> Served {
        guard let planned = tables[table] else {
            let body = bodies[table] ?? "[]"
            return Served(body: body, delivered: [], status: 200, contentRange: nil)
        }
        if let failFrom = planned.failFrom, (offset ?? 0) >= failFrom {
            return Served(body: "{\"message\":\"upstream refused\",\"code\":\"XX000\"}",
                          delivered: [], status: 500, contentRange: nil)
        }
        var rows = planned.rows
        if !ids.isEmpty {
            let wanted = Set(ids)
            rows = rows.filter { $0.parent.map(wanted.contains) ?? false }
        }
        let requested = offset ?? 0
        let start = requested > 0 ? max(0, requested - planned.overlap) : 0
        let allowed = min(limit ?? cap, cap)
        let slice = start < rows.count ? Array(rows[start..<min(start + allowed, rows.count)]) : []
        let body = "[" + slice.map(\.json).joined(separator: ",") + "]"
        let range = (offset != nil || limit != nil) && !slice.isEmpty
            ? "\(start)-\(start + slice.count - 1)/*" : nil
        return Served(body: body, delivered: slice.map(\.id), status: 200, contentRange: range)
    }

    private static func deliver(id: Int, transport: CappedReadTransport, handled: Handled) {
        lock.lock()
        let alive = live[id] != nil
        if alive {
            recorded.append(handled.record)
        }
        lock.unlock()
        var headers = ["Content-Type": "application/json"]
        if let contentRange = handled.served.contentRange {
            headers["Content-Range"] = contentRange
        }
        guard alive, let url = transport.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: handled.served.status, httpVersion: "HTTP/1.1", headerFields: headers
              ) else { return }
        transport.client?.urlProtocol(transport, didReceive: response, cacheStoragePolicy: .notAllowed)
        transport.client?.urlProtocol(transport, didLoad: Data(handled.served.body.utf8))
        transport.client?.urlProtocolDidFinishLoading(transport)
        end(id, phase: .finished)
    }

    private static func begin(table: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        live[sequence] = table
        events.append(Event(sequence: sequence, table: table, phase: .started))
        return sequence
    }

    private static func end(_ id: Int, phase: Phase) {
        lock.lock()
        defer { lock.unlock() }
        guard let table = live.removeValue(forKey: id) else { return }
        parked[id] = nil
        events.append(Event(sequence: sequence, table: table, phase: phase))
    }

    private static func tableName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The ids of an `in.(a,b,c)` filter, whichever parent column carries it.
    private static func chunkIDs(_ queryItems: [URLQueryItem]) -> [String] {
        guard let value = queryItems.first(where: { $0.value?.hasPrefix("in.(") == true })?.value else {
            return []
        }
        let inner = value.dropFirst("in.(".count).dropLast(value.hasSuffix(")") ? 1 : 0)
        return inner.split(separator: ",").map { part in
            part.hasPrefix("\"") && part.hasSuffix("\"") ? String(part.dropFirst().dropLast()) : String(part)
        }
    }
}

/// Shared setup: the synthetic account, the repo's local-day fixture instant,
/// and the repository built on the capped transport.
class CappedPagingTestCase: XCTestCase {
    let account = UUID()
    /// 2026-09-05 04:00Z — the repo's local-day fixture instant (11:00 +07).
    let referenceInstant = MorselDate.date("2026-09-05T04:00:00Z") ?? Date()

    func instant(_ value: String) -> Date {
        MorselDate.date(value) ?? Date()
    }

    func client() throws -> SupabaseClient {
        guard let baseURL = URL(string: "https://stub.supabase.test") else {
            throw MorselError.invalidData("stub base URL must be valid")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CappedReadTransport.self]
        configuration.urlCache = nil
        return SupabaseClient(
            supabaseURL: baseURL, supabaseKey: "stub-anon-key",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: StubSessionStorage(userID: account, expiresAt: Date().addingTimeInterval(3600)),
                    storageKey: "sb-stub-auth-token", autoRefreshToken: false
                ),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
    }

    func repository() async throws -> SupabaseDashboardRepository {
        let client = try client()
        _ = try await client.auth.session
        return SupabaseDashboardRepository(client: client)
    }

    /// Bounded wait for a REAL request event; no ordering claim rests on it.
    func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}

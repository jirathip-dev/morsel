import Foundation
import Supabase

// Issue #178 shared test support (read-graph lane): the controlled transport
// that the ParallelReadsTests suite drives the production Today/History/goals
// methods through. Split out of ParallelReadsTests.swift because a single file
// carrying both would exceed the repo's 400-line SwiftLint file_length budget.

/// The terminal phases a stub request can reach (see `StubTransport.Event`).
enum TransportPhase: String { case started, finished, cancelled }

/// A controllable transport at the real URLSession seam: each path's plan
/// decides status, body, deterministic delay and whether the request parks
/// until the test releases it. Every start/finish/cancel is recorded with a
/// global sequence number, so ordering, in-flight counts and termination are
/// asserted on real request events — never on sleeps or wall-clock guesses.
final class StubTransport: URLProtocol {
    /// The repository read graph's table seams.
    static let readPaths = ["goals", "profiles", "weight_logs", "energy_burned_logs", "meal_logs", "meal_items"]

    struct Plan { var status = 200; var body = "[]"; var hold = false; var delay: TimeInterval = 0 }

    struct Event: Equatable {
        let sequence: Int
        let path: String
        let url: String
        let phase: TransportPhase
    }

    struct Snapshot {
        let events: [Event]
        let peakInFlight: Int
        let inFlight: Int

        func count(_ phase: TransportPhase, _ path: String, prefix: Bool = false) -> Int {
            events.filter { $0.phase == phase && (prefix ? $0.path.hasPrefix(path) : $0.path.hasSuffix(path)) }.count
        }

        func sequence(_ phase: TransportPhase, _ suffix: String) -> Int? {
            events.first { $0.phase == phase && $0.path.hasSuffix(suffix) }?.sequence
        }

        /// Every value sent for a PostgREST query parameter (range filters are
        /// named after their column: `eaten_at=gte.<instant>`).
        func queryValues(_ suffix: String, _ name: String) -> [String] {
            guard let event = events.first(where: { $0.phase == .started && $0.path.hasSuffix(suffix) }),
                  let items = URLComponents(string: event.url)?.queryItems else { return [] }
            return items.filter { $0.name == name }.compactMap(\.value)
        }
    }

    private static let lock = NSLock()
    private static var plans: [(String, Plan)] = StubFixture.plans()
    private static var recorded: [Event] = []
    private static var live: [Int: String] = [:]
    private static var parked: [Int: StubTransport] = [:]
    private static var sequence = 0
    private static var inFlight = 0
    private static var peak = 0

    private var requestID: Int?
    private var plan = Plan()
    private var url: URL?

    /// Installs the populated fixture plans, optionally parking or delaying
    /// the endpoints a test wants to control.
    static func reset(holding held: [String] = [], delay: TimeInterval = 0) {
        lock.lock()
        defer { lock.unlock() }
        plans = StubFixture.plans(holding: held, delay: delay)
        recorded = []; live = [:]; parked = [:]
        sequence = 0; inFlight = 0; peak = 0
    }

    /// Registers a plan for every request path with this suffix; the LAST
    /// registration wins, so a test can override a single endpoint.
    static func respond(_ suffix: String, _ plan: Plan) {
        lock.lock()
        defer { lock.unlock() }
        plans.append((suffix, plan))
    }

    /// Releases every parked request whose path has `suffix` (default: all).
    static func release(_ suffix: String = "") {
        lock.lock()
        let targets = parked.filter { ($0.value.url?.path ?? "").hasSuffix(suffix) }
        for id in targets.keys {
            parked[id] = nil
        }
        lock.unlock()
        for (id, transport) in targets {
            deliver(id: id, transport: transport)
        }
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(events: recorded, peakInFlight: peak, inFlight: inFlight)
    }

    static override func canInit(with request: URLRequest) -> Bool { true }

    static override func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        self.url = url
        plan = Self.plan(for: url.path)
        let id = Self.begin(path: url.path, url: url)
        requestID = id
        guard plan.hold else {
            Self.deliver(id: id, transport: self)
            return
        }
        Self.lock.lock()
        Self.parked[id] = self
        Self.lock.unlock()
    }

    override func stopLoading() {
        if let requestID {
            Self.end(requestID, phase: .cancelled)
        }
    }

    private static func plan(for path: String) -> Plan {
        lock.lock()
        defer { lock.unlock() }
        return plans.last { path.hasSuffix($0.0) }?.1 ?? Plan()
    }

    private static func begin(path: String, url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        live[sequence] = path
        inFlight += 1
        peak = max(peak, inFlight)
        recorded.append(Event(sequence: sequence, path: path, url: url.absoluteString, phase: .started))
        return sequence
    }

    private static func deliver(id: Int, transport: StubTransport) {
        let work = {
            guard let client = transport.client, isLive(id), let url = transport.url else { return }
            let plan = transport.plan
            guard let response = HTTPURLResponse(
                url: url, statusCode: plan.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                return
            }
            client.urlProtocol(transport, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(transport, didLoad: Data(plan.body.utf8))
            client.urlProtocolDidFinishLoading(transport)
            end(id, phase: .finished)
        }
        guard transport.plan.delay > 0 else {
            work()
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + transport.plan.delay, execute: work)
    }

    private static func isLive(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return live[id] != nil
    }

    private static func end(_ id: Int, phase: TransportPhase) {
        lock.lock()
        defer { lock.unlock() }
        guard let path = live.removeValue(forKey: id) else { return }
        inFlight -= 1
        recorded.append(Event(sequence: sequence, path: path, url: "", phase: phase))
    }
}

/// The populated-day responses every test starts from (per-table bodies).
private enum StubFixture {
    static let mealID = "11111111-1111-4111-8111-111111111111"
    static let itemID = "22222222-2222-4222-8222-222222222222"
    static let manualWriteTime = "2026-09-05T01:00:00.000Z"
    static let mealLogs = """
    [{"id": "\(mealID)", "eaten_at": "2026-09-05T03:30:00.000Z", "meal_type": "lunch", \
    "source": "manual", "image_path": null}]
    """
    static let items = """
    [{"id": "\(itemID)", "meal_log_id": "\(mealID)", "name": "jasmine rice", "quantity": 1.5, "unit": "serving", \
    "calories_kcal": 300, "protein_g": 6, "confidence": 0.9}]
    """
    static let profile = """
    [{"sex": "male", "age_years": 34, "height_cm": 178, "weight_kg": 81.5, "activity_level": "moderate", \
    "diet_goal": "maintain", "goal_weight_kg": 78, "updated_at": "2026-09-05T00:00:00.000Z"}]
    """
    /// Two samples inside one whole second (dedupe keeps the later one).
    static let weights = """
    [{"measured_at": "2026-09-04T04:00:00.100Z", "kg": 81.4}, \
    {"measured_at": "2026-09-04T04:00:00.400Z", "kg": 81.2}]
    """
    static let energy = "[{\"burned_at\": \"2026-09-05T03:00:00.000Z\", \"active_kcal\": 320}]"

    static func goals(updatedAt: String) -> String {
        """
        [{"calorie_target_kcal": 2000, "protein_g": 150, "carbs_g": 200, "fat_g": 60, \
        "source": "manual", "updated_at": "\(updatedAt)"}]
        """
    }

    static func plans(holding held: [String] = [], delay: TimeInterval = 0) -> [(String, StubTransport.Plan)] {
        func plan(_ body: String, _ suffix: String) -> StubTransport.Plan {
            StubTransport.Plan(body: body, hold: held.contains(suffix), delay: delay)
        }
        return [
            ("goals", plan(goals(updatedAt: manualWriteTime), "goals")),
            ("profiles", plan(profile, "profiles")),
            ("weight_logs", plan(weights, "weight_logs")),
            ("energy_burned_logs", plan(energy, "energy_burned_logs")),
            ("meal_logs", plan(mealLogs, "meal_logs")),
            ("meal_items", plan(items, "meal_items"))
        ]
    }
}

/// A KEY-SCOPED in-memory session storage seeded with a real `Session` value,
/// so the production `requireSession` seam answers with no network round trip
/// (an expired one still forces the real refresh path). Key scoping matters:
/// supabase-swift's storage migrations look up other keys and must not see
/// this session under them.
final class StubSessionStorage: AuthLocalStorage {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    init(userID: UUID, expiresAt: Date) {
        let user = User(
            id: userID, appMetadata: [:], userMetadata: [:], aud: "authenticated",
            createdAt: Date(), updatedAt: Date()
        )
        values["sb-stub-auth-token"] = try? JSONEncoder().encode(Session(
            accessToken: "stub-access-token", tokenType: "bearer",
            expiresIn: expiresAt.timeIntervalSinceNow, expiresAt: expiresAt.timeIntervalSince1970,
            refreshToken: "stub-refresh-token", user: user
        ))
    }

    func store(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func remove(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }
}

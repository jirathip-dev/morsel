import Foundation
import Supabase
import XCTest
@testable import Morsel

/// Offline PostgREST fixture: UPDATE keeps updated_at unless the actual payload
/// supplies it (the database default applies only to INSERT). No live requests.
final class GoalsRestoreTransport: URLProtocol {
    private static let lock = NSLock()
    private static var row: [String: Any] = [:]
    private static var writes: [[String: Any]] = []
    private static var writeStatus = 200
    static let oldStamp = "2026-09-05T01:00:00.000Z"
    static let profileStamp = "2026-09-06T01:00:00.000Z"
    static let values: [String: Double] = [
        "calorie_target_kcal": 2000.5, "protein_g": 104.2, "carbs_g": 255.7, "fat_g": 60.1
    ]

    static func reset(source: String = "manual", stamp: String = oldStamp, protein: Double = 104.2) {
        lock.lock()
        defer { lock.unlock() }
        row = values.mapValues { $0 as Any }
        row["source"] = source
        row["updated_at"] = stamp
        row["protein_g"] = protein
        writes = []
        writeStatus = 200
    }

    static func failWrites() {
        lock.lock()
        defer { lock.unlock() }
        writeStatus = 503
    }

    static func savedPayloads() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    static override func canInit(with request: URLRequest) -> Bool { true }
    static override func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let (status, body) = try Self.respond(request)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        switch request.url?.lastPathComponent {
        case "goals":
            if request.httpMethod == "POST" {
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body(request)) as? [String: Any])
                writes.append(payload)
                guard writeStatus == 200 else {
                    return (writeStatus, Data("{\"message\":\"offline fixture failure\"}".utf8))
                }
                row.merge(payload) { _, new in new }
                return (200, try JSONSerialization.data(withJSONObject: row))
            }
            return (200, try JSONSerialization.data(withJSONObject: [row]))
        case "profiles":
            return (200, Data("""
            [{"sex":"male","age_years":30,"height_cm":167,"weight_kg":63,
            "activity_level":"active","diet_goal":"lose","updated_at":"\(profileStamp)"}]
            """.utf8))
        case "weight_logs": return (200, Data("[]".utf8))
        default: throw MorselError.invalidData("Unexpected restore fixture request: \(request.url?.path ?? "nil")")
        }
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    @MainActor
    static func repository(userID: UUID) throws -> SupabaseDashboardRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoalsRestoreTransport.self]
        configuration.urlCache = nil
        let client = SupabaseClient(
            supabaseURL: try XCTUnwrap(URL(string: "https://restore.supabase.test")), supabaseKey: "stub-anon-key",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: StubSessionStorage(userID: userID, expiresAt: Date().addingTimeInterval(3600)),
                    storageKey: "sb-stub-auth-token", autoRefreshToken: false
                ),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
        return SupabaseDashboardRepository(client: client)
    }
}

import Foundation
import Supabase

struct WeightLog: Equatable, Sendable {
    let measuredAt: Date
    let kilograms: Double
}

struct EnergyBurnedLog: Equatable, Sendable {
    let burnedAt: Date
    let activeKilocalories: Double
}

protocol WeightLogStore: AnyObject {
    func upsert(_ logs: [WeightLog]) async throws
    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws
}

final class MockWeightLogStore: WeightLogStore {
    private(set) var logs: [WeightLog] = []
    private(set) var energyBurnedLogs: [EnergyBurnedLog] = []
    func upsert(_ newLogs: [WeightLog]) async throws {
        var byDate = Dictionary(uniqueKeysWithValues: logs.map { ($0.measuredAt, $0) })
        for log in newLogs where log.kilograms > 0 && log.kilograms.isFinite {
            byDate[log.measuredAt] = log
        }
        logs = byDate.values.sorted { $0.measuredAt < $1.measuredAt }
    }
    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws {
        energyBurnedLogs = logs.sorted { $0.burnedAt < $1.burnedAt }
    }
}

final class SupabaseWeightLogStore: WeightLogStore {
    private let client: SupabaseClient
    private let userID: UUID

    init(client: SupabaseClient, userID: UUID) {
        self.client = client
        self.userID = userID
    }
    func upsert(_ logs: [WeightLog]) async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = logs.map {
            WeightLogRow(
                userID: userID,
                measuredAt: formatter.string(from: $0.measuredAt),
                kilograms: $0.kilograms,
                source: "apple_health"
            )
        }
        guard !rows.isEmpty else { return }
        try await client.from("weight_logs")
            .upsert(rows, onConflict: "user_id,measured_at")
            .execute()
    }
    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = logs.map {
            EnergyBurnedRow(userID: userID, burnedAt: formatter.string(from: $0.burnedAt),
                            activeKilocalories: $0.activeKilocalories, source: "apple_health")
        }
        guard !rows.isEmpty else { return }
        try await client.from("energy_burned_logs").upsert(rows, onConflict: "user_id,burned_at").execute()
    }
}

private struct WeightLogRow: Encodable {
    let userID: UUID
    let measuredAt: String
    let kilograms: Double
    let source: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case measuredAt = "measured_at"
        case kilograms = "kg"
        case source
    }
}

private struct EnergyBurnedRow: Encodable {
    let userID: UUID
    let burnedAt: String
    let activeKilocalories: Double
    let source: String
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case burnedAt = "burned_at"
        case activeKilocalories = "active_kcal"
        case source
    }
}

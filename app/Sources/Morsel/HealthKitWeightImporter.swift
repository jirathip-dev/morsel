import Foundation
import Supabase

struct WeightLog: Equatable, Sendable {
    let measuredAt: Date
    let kilograms: Double
}

protocol WeightLogStore: AnyObject {
    func upsert(_ logs: [WeightLog]) async throws
}

final class MockWeightLogStore: WeightLogStore {
    private(set) var logs: [WeightLog] = []

    func upsert(_ newLogs: [WeightLog]) async throws {
        var byDate = Dictionary(uniqueKeysWithValues: logs.map { ($0.measuredAt, $0) })
        for log in newLogs where log.kilograms > 0 && log.kilograms.isFinite {
            byDate[log.measuredAt] = log
        }
        logs = byDate.values.sorted { $0.measuredAt < $1.measuredAt }
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
        try await client.from("weight_logs").upsert(rows, onConflict: "user_id,measured_at").execute()
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

#if canImport(HealthKit)
import HealthKit

final class HealthKitWeightImporter {
    private let healthStore: HKHealthStore
    private let store: WeightLogStore

    init(healthStore: HKHealthStore = HKHealthStore(), store: WeightLogStore) {
        self.healthStore = healthStore
        self.store = store
    }

    func importBodyMass(since: Date? = nil) async throws {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: .bodyMass) else { return }
        try await healthStore.requestAuthorization(toShare: [], read: [type])
        let predicate = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate) }
        let samples: [WeightLog] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                let unit = HKUnit.gramUnit(with: .kilo)
                let logs = (results as? [HKQuantitySample] ?? []).map {
                    WeightLog(measuredAt: $0.startDate, kilograms: $0.quantity.doubleValue(for: unit))
                }
                continuation.resume(returning: logs)
            }
            healthStore.execute(query)
        }
        try await store.upsert(samples)
    }
}
#endif

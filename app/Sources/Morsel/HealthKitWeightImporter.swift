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
        try await client.from("weight_logs")
            .upsert(rows, onConflict: "user_id,measured_at")
            .execute()
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

protocol WeightSampleReading: AnyObject {
    func requestAuthorization() async throws
    func samples(since: Date?) async throws -> [WeightLog]
}

final class HealthKitWeightReader: WeightSampleReading {
    private let healthStore: HKHealthStore
    private let bodyMassType: HKQuantityType

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        bodyMassType = HKObjectType.quantityType(forIdentifier: .bodyMass)!
    }

    func requestAuthorization() async throws {
        try await healthStore.requestAuthorization(toShare: [], read: [bodyMassType])
    }

    func samples(since: Date?) async throws -> [WeightLog] {
        let predicate = since.map {
            HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: bodyMassType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let unit = HKUnit.gramUnit(with: .kilo)
                let logs = (results as? [HKQuantitySample] ?? []).map {
                    WeightLog(
                        measuredAt: $0.startDate,
                        kilograms: $0.quantity.doubleValue(for: unit)
                    )
                }
                continuation.resume(returning: logs)
            }
            self.healthStore.execute(query)
        }
    }

    func observeBodyMass(_ handler: @escaping () -> Void) {
        let query = HKObserverQuery(sampleType: bodyMassType, predicate: nil) { _, completion, _ in
            handler()
            completion()
        }
        healthStore.execute(query)
        healthStore.enableBackgroundDelivery(for: bodyMassType, frequency: .daily) { _, _ in }
    }
}

final class HealthKitWeightImporter {
    private let reader: WeightSampleReading
    private let store: WeightLogStore

    init(
        reader: WeightSampleReading = HealthKitWeightReader(),
        store: WeightLogStore
    ) {
        self.reader = reader
        self.store = store
    }

    func importBodyMass(since: Date? = nil) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await reader.requestAuthorization()
        try await store.upsert(reader.samples(since: since))
    }

    func startObserving() {
        (reader as? HealthKitWeightReader)?.observeBodyMass { [weak self] in
            Task {
                try? await self?.importBodyMass()
            }
        }
    }
}
#endif

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

    func upsert(_ newLogs: [WeightLog]) async throws {
        var byDate = Dictionary(uniqueKeysWithValues: logs.map { ($0.measuredAt, $0) })
        for log in newLogs where log.kilograms > 0 && log.kilograms.isFinite {
            byDate[log.measuredAt] = log
        }
        logs = byDate.values.sorted { $0.measuredAt < $1.measuredAt }
    }
    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws {}
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

#if canImport(HealthKit)
import HealthKit

protocol WeightSampleReading: AnyObject {
    func requestAuthorization() async throws
    func samples(since: Date?) async throws -> [WeightLog]
    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog]
    func startObserving(_ handler: @escaping () async -> Result<Void, Error>, onError: @escaping (Error) -> Void)
    func stopObserving()
}

enum HealthKitWeightImporterError: LocalizedError {
    case bodyMassTypeUnavailable

    var errorDescription: String? { "Apple Health body-mass data is unavailable." }
}

final class HealthKitWeightReader: WeightSampleReading {
    private let healthStore: HKHealthStore
    private let bodyMassType: HKQuantityType
    private let activeEnergyType: HKQuantityType

    init(healthStore: HKHealthStore = HKHealthStore()) throws {
        self.healthStore = healthStore
        guard let bodyMassType = HKObjectType.quantityType(forIdentifier: .bodyMass) else {
            throw HealthKitWeightImporterError.bodyMassTypeUnavailable
        }
        self.bodyMassType = bodyMassType
        guard let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) else {
            throw HealthKitWeightImporterError.bodyMassTypeUnavailable
        }
        self.activeEnergyType = activeEnergyType
    }

    func requestAuthorization() async throws {
        try await healthStore.requestAuthorization(toShare: [], read: [bodyMassType, activeEnergyType])
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

    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] {
        let predicate = since.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate) }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: activeEnergyType, predicate: predicate, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                let unit = HKUnit.kilocalorie()
                continuation.resume(returning: (results as? [HKQuantitySample] ?? []).map {
                    EnergyBurnedLog(burnedAt: $0.startDate, activeKilocalories: $0.quantity.doubleValue(for: unit))
                })
            }
            self.healthStore.execute(query)
        }
    }

    func startObserving(
        _ handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {
        guard observerQuery == nil else { return }
        let query = HKObserverQuery(sampleType: bodyMassType, predicate: nil) { _, completion, error in
            Task {
                if let error {
                    onError(error)
                } else if case let .failure(error) = await handler() {
                    onError(error)
                }
                completion()
            }
        }
        observerQuery = query
        healthStore.execute(query)
        healthStore.enableBackgroundDelivery(for: bodyMassType, frequency: .daily) { _, error in
            if let error { onError(error) }
        }
    }

    func stopObserving() {
        if let observerQuery { healthStore.stop(observerQuery) }
        observerQuery = nil
    }

    private var observerQuery: HKObserverQuery?
}

final class HealthKitWeightImporter {
    private let reader: WeightSampleReading
    private let store: WeightLogStore
    private var isObserving = false

    init(
        reader: WeightSampleReading? = nil,
        store: WeightLogStore
    ) throws {
        self.reader = try reader ?? HealthKitWeightReader()
        self.store = store
    }

    func importBodyMass(since: Date? = nil) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await reader.requestAuthorization()
        let samples = try await reader.samples(since: since)
        try await store.upsert(samples.filter { $0.kilograms > 0 && $0.kilograms.isFinite })
    }

    func importActiveEnergy(since: Date? = nil) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let samples = try await reader.activeEnergyBurned(since: since)
        var byDate: [Date: EnergyBurnedLog] = [:]
        for sample in samples where sample.activeKilocalories >= 0 && sample.activeKilocalories.isFinite {
            byDate[sample.burnedAt] = sample
        }
        try await store.upsertEnergyBurned(Array(byDate.values))
    }

    func startObserving(onError: @escaping (Error) -> Void) {
        guard !isObserving else { return }
        isObserving = true
        reader.startObserving({ [weak self] in
            do {
                try await self?.importBodyMass()
                try await self?.importActiveEnergy()
                return .success(())
            } catch {
                return .failure(error)
            }
        }, onError: onError)
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        reader.stopObserving()
    }

    deinit { stopObserving() }
}
#endif

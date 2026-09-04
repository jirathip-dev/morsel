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

#if canImport(HealthKit)
import HealthKit

enum HealthKitObserverKind: Equatable {
    case bodyMass
    case activeEnergyBurned
}

protocol WeightSampleReading: AnyObject {
    func requestAuthorization() async throws
    func samples(since: Date?) async throws -> [WeightLog]
    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog]
    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    )
    func stopObserving()
}

enum HealthKitWeightImporterError: LocalizedError {
    case bodyMassTypeUnavailable

    var errorDescription: String? { "Apple Health body-mass data is unavailable." }
}

/// User-facing copy table for the weight-import surface (v0.4 hotfix #89).
/// Raw system error text — entitlement strings, HealthKit domain
/// descriptions, any `localizedDescription` passthrough — must NEVER reach
/// the UI. The only app-authored importer error keeps its own human copy;
/// every foreign/system error maps to one honest background-sync notice.
enum HealthSyncUserMessage {
    static let backgroundSyncUnavailable =
        "Background Health sync is unavailable — open the app to refresh."

    static func userMessage(for error: Error) -> String {
        (error as? HealthKitWeightImporterError)?.errorDescription
            ?? backgroundSyncUnavailable
    }
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
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {
        let sampleType: HKSampleType
        switch kind {
        case .bodyMass:
            guard observerQueries[.bodyMass] == nil else { return }
            sampleType = bodyMassType
        case .activeEnergyBurned:
            guard observerQueries[.activeEnergyBurned] == nil else { return }
            sampleType = activeEnergyType
        }
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completion, error in
            Task {
                if let error {
                    onError(error)
                } else if case let .failure(error) = await handler() {
                    onError(error)
                }
                completion()
            }
        }
        observerQueries[kind] = query
        healthStore.execute(query)
        healthStore.enableBackgroundDelivery(for: sampleType, frequency: .daily) { _, error in
            if let error { onError(error) }
        }
    }

    func stopObserving() {
        observerQueries.values.forEach(healthStore.stop)
        observerQueries = [:]
    }

    private var observerQueries: [HealthKitObserverKind: HKObserverQuery] = [:]
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
        var byDate: [Date: (total: Double, samples: Set<String>)] = [:]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        for sample in samples where sample.activeKilocalories > 0 && sample.activeKilocalories.isFinite {
            let day = calendar.startOfDay(for: sample.burnedAt)
            let key = "\(sample.burnedAt.timeIntervalSince1970):\(sample.activeKilocalories)"
            guard byDate[day]?.samples.contains(key) != true else { continue }
            byDate[day, default: (0, [])].samples.insert(key)
            byDate[day]?.total += sample.activeKilocalories
        }
        let dailyLogs = byDate.map {
            EnergyBurnedLog(burnedAt: $0.key, activeKilocalories: $0.value.total)
        }
        try await store.upsertEnergyBurned(dailyLogs)
    }

    func startObserving(onSuccess: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        guard !isObserving else { return }
        isObserving = true
        let handler: () async -> Result<Void, Error> = { [weak self] in
            do {
                try await self?.importBodyMass()
                try await self?.importActiveEnergy()
                onSuccess()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        reader.startObserving(.bodyMass, handler: handler, onError: onError)
        reader.startObserving(.activeEnergyBurned, handler: handler, onError: onError)
    }

    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        reader.stopObserving()
    }

    deinit { stopObserving() }
}
#endif

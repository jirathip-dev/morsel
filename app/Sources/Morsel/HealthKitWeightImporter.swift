import Foundation

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
    /// True when the user has authorized reads for the type. Mocks default
    /// to authorized so existing seams keep working unchanged.
    func authorizationStatus(for kind: HealthKitObserverKind) -> Bool
}

extension WeightSampleReading {
    func authorizationStatus(for kind: HealthKitObserverKind) -> Bool { true }
}

enum HealthKitWeightImporterError: LocalizedError {
    case bodyMassTypeUnavailable
    var errorDescription: String? { "Apple Health body-mass data is unavailable." }
}

/// User-facing copy table for the weight-import surface (v0.4 hotfix #89).
/// Raw system error text — entitlement strings, HealthKit domain

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

    /// Per-type authorization (permission-required status is derived from
    /// this, never from raw entitlement/HK text).
    func authorizationStatus(for kind: HealthKitObserverKind) -> Bool {
        switch kind {
        case .bodyMass:
            return healthStore.authorizationStatus(for: bodyMassType) == .sharingAuthorized
        case .activeEnergyBurned:
            return healthStore.authorizationStatus(for: activeEnergyType) == .sharingAuthorized
        }
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
    /// Per-kind single-flight gates: overlapping callbacks coalesce into one
    /// import pass per type; one type's activity never suppresses the other.
    private let importGate = NSLock()
    private var bodyInFlight = false
    private var bodyAgain = false
    private var energyInFlight = false
    private var energyAgain = false

    init(
        reader: WeightSampleReading? = nil,
        store: WeightLogStore
    ) throws {
        self.reader = try reader ?? HealthKitWeightReader()
        self.store = store
    }

    /// Independent body-mass import; returns durably stored samples.
    @discardableResult
    func importBodyMass(since: Date? = nil) async throws -> [WeightLog] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        return try await withBodyGate { [self] in
            try await reader.requestAuthorization()
            let samples = try await reader.samples(since: since)
            let valid = samples.filter { $0.kilograms > 0 && $0.kilograms.isFinite }
            try await store.upsert(valid)
            return valid
        } ?? []
    }

    @discardableResult
    func importActiveEnergy(since: Date? = nil) async throws -> [EnergyBurnedLog] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        return try await withEnergyGate { [self] in
            try await reader.requestAuthorization()
            let samples = try await reader.activeEnergyBurned(since: since)
            var byDate: [Date: (total: Double, samples: Set<String>)] = [:]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            for sample in samples
                where sample.activeKilocalories > 0 && sample.activeKilocalories.isFinite {
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
            return dailyLogs
        } ?? []
    }

    /// Per-type authorization state for calm status derivation.
    func authorizationStatus(for kind: HealthKitObserverKind) -> Bool {
        reader.authorizationStatus(for: kind)
    }

    /// Registers both observers immediately; each handler imports own type.
    func startObserving(onSuccess: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        guard !isObserving else { return }
        isObserving = true
        reader.startObserving(
            .bodyMass,
            handler: observerHandler(kind: .bodyMass, onSuccess: onSuccess, onError: onError),
            onError: onError
        )
        reader.startObserving(
            .activeEnergyBurned,
            handler: observerHandler(kind: .activeEnergyBurned, onSuccess: onSuccess, onError: onError),
            onError: onError
        )
    }
    func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        reader.stopObserving()
    }

    deinit { stopObserving() }
    private func observerHandler(
        kind: HealthKitObserverKind,
        onSuccess: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) -> () async -> Result<Void, Error> {
        { [weak self] in
            guard let self else { return .success(()) }
            do {
                switch kind {
                case .bodyMass:
                    _ = try await self.importBodyMass()
                case .activeEnergyBurned:
                    _ = try await self.importActiveEnergy()
                }
                onSuccess()
                return .success(())
            } catch is CancellationError {
                return .failure(CancellationError())
            } catch {
                onError(error)
                return .failure(error)
            }
        }
    }

    /// Body-mass single-flight gate (concurrent requests queue one rerun).
    private func withBodyGate<T>(_ body: () async throws -> T) async throws -> T? {
        try await withGate(
            inFlight: &bodyInFlight, again: &bodyAgain,
            rerun: { [weak self] in _ = try? await self?.importBodyMass() },
            body: body
        )
    }

    /// Energy single-flight gate, independent of the body-mass gate.
    private func withEnergyGate<T>(_ body: () async throws -> T) async throws -> T? {
        try await withGate(
            inFlight: &energyInFlight, again: &energyAgain,
            rerun: { [weak self] in _ = try? await self?.importActiveEnergy() },
            body: body
        )
    }
    private func withGate<T>(
        inFlight: inout Bool,
        again: inout Bool,
        rerun: @escaping () async -> Void,
        body: () async throws -> T
    ) async throws -> T? {
        importGate.lock()
        if inFlight {
            again = true
            importGate.unlock()
            return nil
        }
        inFlight = true
        importGate.unlock()
        defer {
            importGate.lock()
            inFlight = false
            let followUp = again
            again = false
            importGate.unlock()
            if followUp {
                Task { await rerun() }
            }
        }
        return try await body()
    }
}
#endif

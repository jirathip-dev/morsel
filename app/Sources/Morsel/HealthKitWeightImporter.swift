import Foundation

#if canImport(HealthKit)
import HealthKit

enum HealthKitObserverKind: Equatable {
    case bodyMass
    case activeEnergyBurned
}

protocol WeightSampleReading: AnyObject {
    func requestAuthorization() async throws
    /// Issue #192 — one incremental read: every sample HealthKit reports as
    /// added or removed since `anchor` (nil = the complete history), plus the
    /// anchor that may only be persisted together with the applied window.
    /// A backdated sample is reported whenever it arrives, however old its
    /// start date — a bounded `since:` window cannot see those.
    func bodyMassWindow(after anchor: Data?) async throws -> HealthSampleWindow<WeightLog>
    func activeEnergyWindow(after anchor: Data?) async throws -> HealthSampleWindow<EnergyBurnedLog>
    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    )
    func stopObserving()
    /// True when the user has ANSWERED the read prompt for the type
    /// (getRequestStatusForAuthorization == .unnecessary). Issue #112: this
    /// is the read-side truth — authorizationStatus(for:) reports SHARE
    /// status, which never becomes .sharingAuthorized for the toShare: []
    /// request this app makes. HealthKit deliberately hides grant-vs-deny
    /// for reads; decided-but-empty is the explicit no-data state. Mocks
    /// default to decided so existing seams keep working unchanged.
    /// Issue #173: resolved ASYNC end to end — an unanswered/errored status
    /// query (`false`) can never be upgraded to granted, denied or synced.
    func authorizationStatus(for kind: HealthKitObserverKind) async -> Bool
}

extension WeightSampleReading {
    func authorizationStatus(for kind: HealthKitObserverKind) async -> Bool { true }
}

enum HealthKitWeightImporterError: LocalizedError {
    case bodyMassTypeUnavailable
    /// Issue #192 — HealthKit answered a window without an anchor to persist;
    /// the window is refused rather than silently re-read next pass.
    case anchorUnavailable

    var errorDescription: String? {
        switch self {
        case .bodyMassTypeUnavailable:
            return "Apple Health body-mass data is unavailable."
        case .anchorUnavailable:
            return "Apple Health sync could not be advanced."
        }
    }
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

    /// Read-side authorization (permission-required status is derived from
    /// this, never from raw entitlement/HK text). HealthKit reports SHARE
    /// status from authorizationStatus(for:); with toShare: [] the truthful
    /// read signal is getRequestStatusForAuthorization — .unnecessary means
    /// the user answered the read prompt (grant OR deny, which HealthKit
    /// deliberately hides), .shouldRequest means read access is not granted.
    /// Issue #173 keeps the caller off a semaphore/thread wait. Issue #209
    /// bounds a missing completion to two seconds, returning false (unknown).
    /// Only .unnecessary means answered; neither answer proves grant or denial.
    func authorizationStatus(for kind: HealthKitObserverKind) async -> Bool {
        let type: HKObjectType
        switch kind {
        case .bodyMass:
            type = bodyMassType
        case .activeEnergyBurned:
            type = activeEnergyType
        }
        return await withCheckedContinuation { continuation in
            let answer = HealthStatusAnswer(continuation)
            // Unstructured: cancellation must not remove the deadline while
            // HealthKit still owns a completion. Never join a silent callback.
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                answer.resolve(false)
            }
            healthStore.getRequestStatusForAuthorization(toShare: [], read: [type]) { status, _ in
                answer.resolve(status == .unnecessary)
                timeout.cancel()
            }
        }
    }
    /// Issue #192 — anchored reads: HealthKit reports what changed since the
    /// persisted anchor, so a no-change notification returns an empty window
    /// (plus the advanced anchor) and a backdated sample is still delivered.
    func bodyMassWindow(after anchor: Data?) async throws -> HealthSampleWindow<WeightLog> {
        let unit = HKUnit.gramUnit(with: .kilo)
        return try await anchoredWindow(type: bodyMassType, anchor: anchor) { sample in
            WeightLog(
                measuredAt: sample.startDate,
                kilograms: sample.quantity.doubleValue(for: unit),
                sampleID: sample.uuid
            )
        }
    }
    func activeEnergyWindow(after anchor: Data?) async throws -> HealthSampleWindow<EnergyBurnedLog> {
        let unit = HKUnit.kilocalorie()
        return try await anchoredWindow(type: activeEnergyType, anchor: anchor) { sample in
            EnergyBurnedLog(
                burnedAt: sample.startDate,
                activeKilocalories: sample.quantity.doubleValue(for: unit),
                sampleID: sample.uuid
            )
        }
    }

    /// One HKAnchoredObjectQuery pass: the samples added since the anchor, the
    /// identities deleted since it, and the anchor that supersedes it. The
    /// caller persists the new anchor only with the applied window.
    private func anchoredWindow<Sample: Sendable>(
        type: HKQuantityType,
        anchor: Data?,
        map: @escaping (HKQuantitySample) -> Sample
    ) async throws -> HealthSampleWindow<Sample> {
        let queryAnchor = anchor.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type, predicate: nil, anchor: queryAnchor, limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let newAnchor,
                      let encoded = try? NSKeyedArchiver.archivedData(
                          withRootObject: newAnchor, requiringSecureCoding: true
                      ) else {
                    continuation.resume(throwing: HealthKitWeightImporterError.anchorUnavailable)
                    return
                }
                continuation.resume(returning: HealthSampleWindow(
                    samples: (samples as? [HKQuantitySample] ?? []).map(map),
                    removedSampleIDs: (deleted ?? []).map(\.uuid),
                    anchor: encoded
                ))
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

/// The lock atomically consumes the continuation before resuming outside it.
/// Callback and deadline may race on any executor; only the winner can resume.
/// A late callback sees nil, so it cannot resume again or reach publication.
private final class HealthStatusAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ decided: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: decided)
    }
}

final class HealthKitWeightImporter {
    private let reader: WeightSampleReading
    private let store: any HealthDeltaStore
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
        store: any HealthDeltaStore
    ) throws {
        self.reader = try reader ?? HealthKitWeightReader()
        self.store = store
    }

    /// Independent body-mass delta pass: the durable cursor bounds the read
    /// and advances only with the window the store persisted (issue #192).
    @discardableResult
    func importBodyMassDelta() async throws -> [WeightLog] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        return try await withBodyGate { [self] in
            try await reader.requestAuthorization()
            let window = try await reader.bodyMassWindow(after: try store.bodyMassAnchor())
            return try await store.applyBodyMassWindow(window)
        } ?? []
    }

    /// Independent active-energy delta pass; the returned rows are the touched
    /// LOCAL day totals, recomputed from every contribution the day keeps.
    @discardableResult
    func importActiveEnergyDelta() async throws -> [EnergyBurnedLog] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        return try await withEnergyGate { [self] in
            try await reader.requestAuthorization()
            let window = try await reader.activeEnergyWindow(after: try store.energyAnchor())
            return try await store.applyEnergyWindow(window)
        } ?? []
    }

    /// Per-type read state for calm status derivation (issue #112: READ
    /// prompt answered — see WeightSampleReading.authorizationStatus).
    /// Async since #173: the status derivation awaits HealthKit instead of
    /// blocking the MainActor on a semaphore.
    func authorizationStatus(for kind: HealthKitObserverKind) async -> Bool {
        await reader.authorizationStatus(for: kind)
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
                    _ = try await self.importBodyMassDelta()
                case .activeEnergyBurned:
                    _ = try await self.importActiveEnergyDelta()
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
            rerun: { [weak self] in _ = try? await self?.importBodyMassDelta() },
            body: body
        )
    }

    /// Energy single-flight gate, independent of the body-mass gate.
    private func withEnergyGate<T>(_ body: () async throws -> T) async throws -> T? {
        try await withGate(
            inFlight: &energyInFlight, again: &energyAgain,
            rerun: { [weak self] in _ = try? await self?.importActiveEnergyDelta() },
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

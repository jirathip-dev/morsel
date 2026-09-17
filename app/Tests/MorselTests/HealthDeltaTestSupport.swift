import XCTest
@testable import Morsel
import HealthKit

#if canImport(HealthKit)
// MARK: - Scripted anchored readers

/// Serves an explicit per-type script of windows in order (the last one
/// repeats), recording every anchor and processed-row count.
final class ScriptedDeltaReader: WeightSampleReading {
    struct Window {
        var samples: [WeightLog] = []
        var energySamples: [EnergyBurnedLog] = []
        var removed: [UUID] = []
        var removedEnergy: [UUID] = []
        var failure: Error?
    }

    var bodyScript: [Window] = []
    var energyScript: [Window] = []
    private(set) var bodyAnchors: [Data?] = []
    private(set) var energyAnchors: [Data?] = []
    private(set) var bodyRows: [Int] = []
    private(set) var energyRows: [Int] = []
    private(set) var handlers: [HealthKitObserverKind: () async -> Result<Void, Error>] = [:]
    private(set) var authorizationRequests = 0
    private var anchorCounter = 0
    private var bodyIndex = 0
    private var energyIndex = 0

    func requestAuthorization() async throws { authorizationRequests += 1 }

    func bodyMassWindow(after anchor: Data?) async throws -> HealthSampleWindow<WeightLog> {
        bodyAnchors.append(anchor)
        let step = Self.step(bodyScript, bodyIndex)
        bodyIndex += 1
        if let failure = step.failure { throw failure }
        bodyRows.append(step.samples.count)
        return HealthSampleWindow(
            samples: step.samples, removedSampleIDs: step.removed, anchor: nextAnchor()
        )
    }

    func activeEnergyWindow(after anchor: Data?) async throws -> HealthSampleWindow<EnergyBurnedLog> {
        energyAnchors.append(anchor)
        let step = Self.step(energyScript, energyIndex)
        energyIndex += 1
        if let failure = step.failure { throw failure }
        energyRows.append(step.energySamples.count)
        return HealthSampleWindow(
            samples: step.energySamples, removedSampleIDs: step.removedEnergy, anchor: nextAnchor()
        )
    }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {
        handlers[kind] = handler
    }

    func stopObserving() {}

    private static func step(_ script: [Window], _ index: Int) -> Window {
        script.isEmpty ? Window() : script[min(index, script.count - 1)]
    }

    private func nextAnchor() -> Data {
        anchorCounter += 1
        return Data("delta-anchor-\(anchorCounter)".utf8)
    }
}

/// Body-mass reads park until released (single-flight probe); energy reads
/// answer immediately (per-type independence probe).
final class GatedDeltaReader: WeightSampleReading {
    private let energySamples: [EnergyBurnedLog]
    private(set) var bodyReads = 0
    private(set) var energyReads = 0
    private(set) var handlers: [HealthKitObserverKind: () async -> Result<Void, Error>] = [:]
    private var gate: CheckedContinuation<Void, Never>?

    init(energySamples: [EnergyBurnedLog]) { self.energySamples = energySamples }

    func requestAuthorization() async throws {}

    func bodyMassWindow(after anchor: Data?) async throws -> HealthSampleWindow<WeightLog> {
        bodyReads += 1
        await withCheckedContinuation { gate = $0 }
        return HealthSampleWindow(samples: [], removedSampleIDs: [], anchor: Data("gated-body".utf8))
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func activeEnergyWindow(after anchor: Data?) async throws -> HealthSampleWindow<EnergyBurnedLog> {
        energyReads += 1
        return HealthSampleWindow(
            samples: energySamples, removedSampleIDs: [], anchor: Data("gated-energy".utf8)
        )
    }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {
        handlers[kind] = handler
    }

    func stopObserving() {}
}

/// First body-mass read parks on a cancellable sleep, then serves the samples.
final class CancellingDeltaReader: WeightSampleReading {
    private let samples: [WeightLog]
    private var reads = 0

    init(samples: [WeightLog]) { self.samples = samples }

    func requestAuthorization() async throws {}

    func bodyMassWindow(after anchor: Data?) async throws -> HealthSampleWindow<WeightLog> {
        reads += 1
        if reads == 1 { try await Task.sleep(nanoseconds: 5_000_000_000) }
        return HealthSampleWindow(
            samples: samples, removedSampleIDs: [], anchor: Data("cancelling-\(reads)".utf8)
        )
    }

    func activeEnergyWindow(after anchor: Data?) async throws -> HealthSampleWindow<EnergyBurnedLog> {
        HealthSampleWindow(samples: [], removedSampleIDs: [], anchor: Data("cancelling-energy".utf8))
    }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {}

    func stopObserving() {}
}

/// Store whose window application fails BEFORE anything is written (the
/// persistence-failure shape): the cursor must stay put and the window must
/// replay once persistence succeeds.
final class FailingDeltaStore: HealthDeltaStore {
    private var bodyCursor: Data?
    private var energyCursorData: Data?
    private(set) var appliedWeightRows: [WeightLog] = []
    private(set) var appliedDayTotals: [EnergyBurnedLog] = []
    var failWindowWrites = true

    func upsert(_ logs: [WeightLog]) async throws { appliedWeightRows = logs }
    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws { appliedDayTotals = logs }
    func bodyMassAnchor() throws -> Data? { bodyCursor }
    func setBodyMassAnchor(_ anchor: Data) throws { bodyCursor = anchor }
    func energyAnchor() throws -> Data? { energyCursorData }
    func setEnergyAnchor(_ anchor: Data) throws { energyCursorData = anchor }

    func applyBodyMassWindow(_ window: HealthSampleWindow<WeightLog>) async throws -> [WeightLog] {
        if failWindowWrites { throw URLError(.cannotWriteToFile) }
        let valid = window.samples.filter { $0.kilograms > 0 && $0.kilograms.isFinite }
        appliedWeightRows = valid
        bodyCursor = window.anchor
        return valid
    }

    func applyEnergyWindow(_ window: HealthSampleWindow<EnergyBurnedLog>) async throws -> [EnergyBurnedLog] {
        if failWindowWrites { throw URLError(.cannotWriteToFile) }
        let days = energyDayTotals(samples: window.samples)
        appliedDayTotals = days
        energyCursorData = window.anchor
        return days
    }
}
#endif

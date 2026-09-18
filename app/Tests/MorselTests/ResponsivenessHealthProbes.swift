import Foundation
import XCTest
@testable import Morsel

// Issue #196 — the independent Health delay and the synthetic photo
// fixture, split out so every harness file stays inside the 400-line
// repo budget.

/// A Health reader whose windows park on demand: the independent Health delay.
/// Scripts are empty (no samples) — only the read/callback timing is measured.
final class ParkedHealthReader: WeightSampleReading {
    private(set) var bodyReads = 0
    private(set) var energyReads = 0
    private(set) var handlers: [HealthKitObserverKind: () async -> Result<Void, Error>] = [:]
    var parked = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func requestAuthorization() async throws {}

    func bodyMassWindow(after anchor: Data?) async throws -> HealthSampleWindow<WeightLog> {
        bodyReads += 1
        await waitIfParked()
        return HealthSampleWindow(samples: [], removedSampleIDs: [], anchor: Data([1]))
    }

    func activeEnergyWindow(after anchor: Data?) async throws -> HealthSampleWindow<EnergyBurnedLog> {
        energyReads += 1
        await waitIfParked()
        return HealthSampleWindow(samples: [], removedSampleIDs: [], anchor: Data([1]))
    }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {
        handlers[kind] = handler
    }

    func stopObserving() {}

    func release() {
        parked = false
        let all = waiting
        waiting = []
        for continuation in all { continuation.resume() }
    }

    private func waitIfParked() async {
        guard parked else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

extension ResponsivenessFixture {
    /// One synthetic photo: a solid JPEG is enough for preparation timing and
    /// carries no user content.
    static var mealPhotoBytes: Data {
        (try? MealThumbnailFixture.solidJPEG(width: 320, height: 240, color: .orange)) ?? Data()
    }
}

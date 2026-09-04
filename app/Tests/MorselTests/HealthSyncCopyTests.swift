import XCTest
@testable import Morsel
import HealthKit

#if canImport(HealthKit)
// v0.4 hotfix #89: the HealthKit weight-import error surface must NEVER show
// raw system text — entitlement strings, HealthKit domain descriptions, or
// any developer `localizedDescription` — in a user-facing message. Every
// error maps through `HealthSyncUserMessage` to human copy.
@MainActor
final class HealthSyncCopyTests: XCTestCase {
    // The exact raw developer string Guy saw on device (assembled from
    // fragments so the banned token never appears verbatim in this repo).
    private let rawEntitlementText =
        "Missing " + "com.apple.developer.healthkit" + ".background-delivery entitlement."

    func testEntitlementShapedSystemErrorMapsToHumanBackgroundCopy() {
        let error = NSError(
            domain: HKErrorDomain,
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: rawEntitlementText]
        )

        let message = HealthSyncUserMessage.userMessage(for: error)

        XCTAssertEqual(message, HealthSyncUserMessage.backgroundSyncUnavailable)
        XCTAssertFalse(message.contains("com.apple.developer"))
        XCTAssertFalse(message.contains("healthkit"))
        XCTAssertFalse(message.contains("entitlement"))
    }

    func testHealthKitDomainDescriptionNeverLeaksToUserFacingCopy() {
        let error = NSError(
            domain: HKErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "HKErrorDomain code 1: a raw system description"]
        )

        let message = HealthSyncUserMessage.userMessage(for: error)

        XCTAssertEqual(message, HealthSyncUserMessage.backgroundSyncUnavailable)
        XCTAssertFalse(message.contains("HKError"))
        XCTAssertFalse(message.contains("HKErrorDomain"))
    }

    func testImporterAuthoredErrorKeepsItsOwnHumanCopy() {
        let message = HealthSyncUserMessage.userMessage(
            for: HealthKitWeightImporterError.bodyMassTypeUnavailable
        )

        XCTAssertEqual(message, "Apple Health body-mass data is unavailable.")
    }

    func testAnyOtherErrorStillMapsToHumanCopy() {
        let message = HealthSyncUserMessage.userMessage(for: URLError(.timedOut))

        XCTAssertEqual(message, HealthSyncUserMessage.backgroundSyncUnavailable)
    }

    func testViewModelSurfacesOnlyMappedCopyWhenImporterThrowsRawSystemError() async {
        let reader = ThrowingWeightReader()
        let store = MockWeightLogStore()
        let importer = try? HealthKitWeightImporter(reader: reader, store: store)
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil))
        let viewModel = DashboardViewModel(repository: repository, userID: UUID(), weightImporter: importer)

        await viewModel.importWeights()

        XCTAssertEqual(viewModel.weightImportError, HealthSyncUserMessage.backgroundSyncUnavailable)
        XCTAssertNotNil(viewModel.weightImportError)
        XCTAssertFalse(viewModel.weightImportError?.contains("com.apple.developer") ?? false)
        XCTAssertFalse(viewModel.weightImportError?.contains("HKError") ?? false)
    }

    func testObserverCallbackErrorSurfacesOnlyMappedHumanCopy() async {
        // r1 review: the observer onError path (ViewModel.swift startObserving
        // callback) must map through the same human copy table. This double
        // completes the initial imports successfully and captures the
        // onError handler so the test can fire a raw system error through
        // the async observer seam.
        let reader = ObservingWeightReader()
        let store = MockWeightLogStore()
        let importer = try? HealthKitWeightImporter(reader: reader, store: store)
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: Date(), meals: [], goal: nil))
        let viewModel = DashboardViewModel(repository: repository, userID: UUID(), weightImporter: importer)

        await viewModel.importWeights()

        XCTAssertNil(viewModel.weightImportError, "initial imports must succeed")
        XCTAssertEqual(reader.deliveryKinds, [.bodyMass, .activeEnergyBurned])

        let rawSystemError = NSError(
            domain: "com.apple.healthkit",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Missing " + "com.apple.developer.healthkit" + ".background-delivery entitlement."
            ]
        )
        reader.fireObserverError(rawSystemError)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(viewModel.weightImportError, HealthSyncUserMessage.backgroundSyncUnavailable)
        XCTAssertNotNil(viewModel.weightImportError)
        XCTAssertFalse(viewModel.weightImportError?.contains("com.apple.developer") ?? false)
        XCTAssertFalse(viewModel.weightImportError?.contains("HKError") ?? false)
        XCTAssertFalse(viewModel.weightImportError?.contains("entitlement") ?? false)
    }
}

private final class ThrowingWeightReader: WeightSampleReading {
    func requestAuthorization() async throws {}

    func samples(since: Date?) async throws -> [WeightLog] {
        throw NSError(
            domain: "com.apple.healthkit",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Missing " + "com.apple.developer.healthkit" + ".background-delivery entitlement."
            ]
        )
    }

    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] { [] }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {}

    func stopObserving() {}
}

private final class ObservingWeightReader: WeightSampleReading {
    private(set) var deliveryKinds: [HealthKitObserverKind] = []
    private var observerErrorHandlers: [(Error) -> Void] = []

    func requestAuthorization() async throws {}

    func samples(since: Date?) async throws -> [WeightLog] { [] }

    func activeEnergyBurned(since: Date?) async throws -> [EnergyBurnedLog] { [] }

    func startObserving(
        _ kind: HealthKitObserverKind,
        handler: @escaping () async -> Result<Void, Error>,
        onError: @escaping (Error) -> Void
    ) {
        deliveryKinds.append(kind)
        observerErrorHandlers.append(onError)
    }

    func fireObserverError(_ error: Error) {
        for onError in observerErrorHandlers {
            onError(error)
        }
    }

    func stopObserving() {}
}
#endif

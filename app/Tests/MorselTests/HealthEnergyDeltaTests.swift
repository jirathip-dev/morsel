import XCTest
@testable import Morsel
import HealthKit

#if canImport(HealthKit)
/// Issue #192 — the energy ledger: local-day totals keep every prior
/// contribution, late/backdated samples land on their own day, repeated or
/// corrected samples replace their contribution, and removals drop exactly one.
@MainActor
final class HealthEnergyDeltaTests: XCTestCase {
    private let account = UUID()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("morsel-health-ledger-\\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeHealthStore(calendar: Calendar = .autoupdatingCurrent) throws -> LocalHealthStore {
        try LocalHealthStore(
            databaseURL: LocalDataStore.storeURL(root: directory, accountID: account),
            calendar: calendar
        )
    }

    func testBackdatedAndRepeatedEnergySamplesPreservePriorDayContributions() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 40_000))
        let priorDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        let backdated = EnergyBurnedLog(
            burnedAt: day.addingTimeInterval(60), activeKilocalories: 300, sampleID: UUID()
        )
        let reader = ScriptedDeltaReader()
        // The first pass establishes the durable cursor with an earlier day;
        // the backdated sample then arrives as a delta and is re-reported by
        // the next window (a replay, or a delete+add of the sample).
        reader.energyScript = [
            .init(energySamples: [
                EnergyBurnedLog(burnedAt: priorDay.addingTimeInterval(3_600),
                                activeKilocalories: 100, sampleID: UUID())
            ]),
            .init(energySamples: [backdated]),
            .init(energySamples: [backdated])
        ]
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)
        _ = try await importer.importActiveEnergyDelta()
        XCTAssertNotNil(try health.energyAnchor())
        // A day total that predates the ledger (written by the pre-#192 path,
        // its samples no longer reported by Health) keeps its contribution.
        try await health.upsertEnergyBurned([
            EnergyBurnedLog(burnedAt: day.addingTimeInterval(3_600), activeKilocalories: 320)
        ])

        _ = try await importer.importActiveEnergyDelta()
        XCTAssertEqual(dayTotal(day, try health.dirtyEnergyDays()), 620,
                       "prior contributions are preserved, not overwritten by the delta total")

        _ = try await importer.importActiveEnergyDelta()
        XCTAssertEqual(dayTotal(day, try health.dirtyEnergyDays()), 620,
                       "a repeated delivery of one sample is not double-counted")
        XCTAssertEqual(dayTotal(priorDay, try health.dirtyEnergyDays()), 100,
                       "the backdated sample lands on its own LOCAL day, not the prior one")
    }

    private func dayTotal(_ day: Date, _ rows: [EnergyBurnedLog]) -> Double? {
        rows.first { $0.burnedAt == day }?.activeKilocalories
    }

    func testDistinctSamplesAtOneInstantStayTwoContributions() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let day = Calendar.autoupdatingCurrent.startOfDay(for: Date(timeIntervalSince1970: 41_000))
        let instant = day.addingTimeInterval(600)
        let reader = ScriptedDeltaReader()
        reader.energyScript = [.init(energySamples: [
            EnergyBurnedLog(burnedAt: instant, activeKilocalories: 300, sampleID: UUID()),
            EnergyBurnedLog(burnedAt: instant, activeKilocalories: 420, sampleID: UUID())
        ])]
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)

        _ = try await importer.importActiveEnergyDelta()

        // The pre-#192 in-pass rule (same instant, different value = two
        // samples) is preserved durably: identity, not the timestamp, dedupes.
        XCTAssertEqual(try health.dirtyEnergyDays().first?.activeKilocalories, 720)
    }

    func testRemovalAndCorrectionAdjustExactlyOneContribution() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let day = Calendar.autoupdatingCurrent.startOfDay(for: Date(timeIntervalSince1970: 42_000))
        let firstID = UUID()
        let secondID = UUID()
        let first = EnergyBurnedLog(burnedAt: day.addingTimeInterval(60), activeKilocalories: 300, sampleID: firstID)
        let second = EnergyBurnedLog(burnedAt: day.addingTimeInterval(120), activeKilocalories: 200, sampleID: secondID)
        let reader = ScriptedDeltaReader()
        reader.energyScript = [
            .init(energySamples: [first, second]),
            .init(removedEnergy: [firstID]),
            .init(energySamples: [
                EnergyBurnedLog(burnedAt: second.burnedAt, activeKilocalories: 250, sampleID: secondID)
            ])
        ]
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)

        _ = try await importer.importActiveEnergyDelta()
        XCTAssertEqual(try health.dirtyEnergyDays().first?.activeKilocalories, 500)

        _ = try await importer.importActiveEnergyDelta()
        XCTAssertEqual(try health.dirtyEnergyDays().first?.activeKilocalories, 200,
                       "a removal drops exactly its own contribution")

        _ = try await importer.importActiveEnergyDelta()
        XCTAssertEqual(try health.dirtyEnergyDays().first?.activeKilocalories, 250,
                       "a corrected value replaces its sample's contribution")
    }

    func testLocalDayBucketingAcrossADSTFallBack() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        // 2026-11-01 is the US fall-back day: 01:30 EDT and 01:30 EST are the
        // same wall clock two instants apart; the next boundary is 00:00 EST.
        let foldEarly = try XCTUnwrap(formatter.date(from: "2026-11-01T05:30:00Z"))
        let foldLate = try XCTUnwrap(formatter.date(from: "2026-11-01T06:30:00Z"))
        let beforeMidnight = try XCTUnwrap(formatter.date(from: "2026-11-02T04:59:00Z"))
        let afterMidnight = try XCTUnwrap(formatter.date(from: "2026-11-02T05:01:00Z"))
        let reader = ScriptedDeltaReader()
        reader.energyScript = [.init(energySamples: [
            EnergyBurnedLog(burnedAt: foldEarly, activeKilocalories: 100, sampleID: UUID()),
            EnergyBurnedLog(burnedAt: foldLate, activeKilocalories: 150, sampleID: UUID()),
            EnergyBurnedLog(burnedAt: beforeMidnight, activeKilocalories: 10, sampleID: UUID()),
            EnergyBurnedLog(burnedAt: afterMidnight, activeKilocalories: 20, sampleID: UUID())
        ])]
        let health = try makeHealthStore(calendar: calendar)
        let importer = try HealthKitWeightImporter(reader: reader, store: health)

        _ = try await importer.importActiveEnergyDelta()

        let dayRows = try health.dirtyEnergyDays()
        XCTAssertEqual(dayRows.count, 2, "the fold hour is one local day; the boundary starts the next")
        XCTAssertEqual(dayRows.first?.burnedAt, calendar.startOfDay(for: foldEarly))
        XCTAssertEqual(dayRows.first?.activeKilocalories, 260)
        XCTAssertEqual(dayRows.last?.burnedAt, calendar.startOfDay(for: afterMidnight))
        XCTAssertEqual(dayRows.last?.activeKilocalories, 20)
    }

    func testWarmRestartKeepsCursorsAndContributionLedger() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let day = Calendar.autoupdatingCurrent.startOfDay(for: Date(timeIntervalSince1970: 43_000))
        let reader = ScriptedDeltaReader()
        reader.energyScript = [.init(energySamples: [
            EnergyBurnedLog(burnedAt: day.addingTimeInterval(60), activeKilocalories: 180, sampleID: UUID())
        ])]
        let url = LocalDataStore.storeURL(root: directory, accountID: account)
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)
        _ = try await importer.importActiveEnergyDelta()
        let anchor = try XCTUnwrap(try health.energyAnchor())

        // Warm restart: a new connection over the same account file.
        let reopened = try LocalHealthStore(databaseURL: url)
        XCTAssertEqual(try reopened.energyAnchor(), anchor, "the cursor survives a restart")
        XCTAssertEqual(try reopened.dirtyEnergyDays().first?.activeKilocalories, 180)
        let secondReader = ScriptedDeltaReader()
        secondReader.energyScript = [.init(energySamples: [
            EnergyBurnedLog(burnedAt: day.addingTimeInterval(120), activeKilocalories: 20, sampleID: UUID())
        ])]
        let secondImporter = try HealthKitWeightImporter(reader: secondReader, store: reopened)

        _ = try await secondImporter.importActiveEnergyDelta()

        XCTAssertEqual(secondReader.energyAnchors, [anchor],
                       "the restarted store reads with the persisted cursor, not from scratch")
        XCTAssertEqual(try reopened.dirtyEnergyDays().first?.activeKilocalories, 200,
                       "the ledger and its prior contributions survive the restart")
    }

    func testRemovedWeightSampleDropsItsLocalRow() async throws {
        try XCTSkipUnless(HKHealthStore.isHealthDataAvailable())
        let measuredAt = Date(timeIntervalSince1970: 44_000)
        let sampleID = UUID()
        let reader = ScriptedDeltaReader()
        reader.bodyScript = [
            .init(samples: [WeightLog(measuredAt: measuredAt, kilograms: 71, sampleID: sampleID)]),
            .init(removed: [sampleID])
        ]
        let health = try makeHealthStore()
        let importer = try HealthKitWeightImporter(reader: reader, store: health)

        _ = try await importer.importBodyMassDelta()
        try health.markWeightSynced(measuredAt: measuredAt)
        XCTAssertTrue(try health.hasWeightSamples())

        _ = try await importer.importBodyMassDelta()

        // The local row (uploaded or not) follows the Health sample; the
        // already-pushed remote row is upsert-only and is NOT deleted here.
        XCTAssertFalse(try health.hasWeightSamples())
        XCTAssertTrue(try health.unsyncedWeightSamples().isEmpty)
    }
}

private extension Result where Success == Void {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
#endif

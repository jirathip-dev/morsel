import Foundation
import Supabase

struct WeightLog: Equatable, Sendable {
    let measuredAt: Date
    let kilograms: Double
    /// Issue #192 — HealthKit's identity for the sample this row came from.
    /// Nil for values that are not one sample (day aggregates, legacy rows).
    var sampleID: UUID?

    init(measuredAt: Date, kilograms: Double, sampleID: UUID? = nil) {
        self.measuredAt = measuredAt
        self.kilograms = kilograms
        self.sampleID = sampleID
    }
}

struct EnergyBurnedLog: Equatable, Sendable {
    let burnedAt: Date
    let activeKilocalories: Double
    /// Issue #192 — the sample identity behind a per-sample contribution.
    /// Nil for day aggregates and legacy rows.
    var sampleID: UUID?

    init(burnedAt: Date, activeKilocalories: Double, sampleID: UUID? = nil) {
        self.burnedAt = burnedAt
        self.activeKilocalories = activeKilocalories
        self.sampleID = sampleID
    }
}

/// Issue #192 — one incremental HealthKit read window: the samples to apply,
/// the identities HealthKit reports as removed, and the opaque query anchor
/// that must be persisted ONLY together with the applied window.
struct HealthSampleWindow<Sample: Sendable>: Sendable {
    var samples: [Sample]
    var removedSampleIDs: [UUID]
    var anchor: Data
}

protocol WeightLogStore: AnyObject {
    func upsert(_ logs: [WeightLog]) async throws
    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws
}

/// Issue #192 — the local-first store that owns the durable per-type read
/// cursors (opaque HealthKit anchors) and applies one read window atomically:
/// the cursor advances only with the window it produced. A store with no
/// durable storage of its own (the remote-only fallback) reports no cursor,
/// which keeps every read a full-history read whose day totals are recomputed
/// from the complete sample set — never a delta-total overwrite.
protocol HealthDeltaStore: WeightLogStore {
    func bodyMassAnchor() throws -> Data?
    func setBodyMassAnchor(_ anchor: Data) throws
    func energyAnchor() throws -> Data?
    func setEnergyAnchor(_ anchor: Data) throws
    func applyBodyMassWindow(_ window: HealthSampleWindow<WeightLog>) async throws -> [WeightLog]
    func applyEnergyWindow(_ window: HealthSampleWindow<EnergyBurnedLog>) async throws -> [EnergyBurnedLog]
}

/// Contribution identity: HealthKit's sample UUID when the sample carries one,
/// otherwise the pre-#192 (start instant, kcal) pair. Either form collapses a
/// repeated delivery onto the same contribution instead of double-counting it.
func energyContributionKey(_ log: EnergyBurnedLog) -> String {
    if let sampleID = log.sampleID { return sampleID.uuidString }
    return "t:\(log.burnedAt.timeIntervalSince1970):\(log.activeKilocalories)"
}

/// Local-day totals from a window's samples (validation, identity dedupe and
/// local-day bucketing) for stores without a durable contribution ledger.
func energyDayTotals(
    samples: [EnergyBurnedLog], calendar: Calendar = .autoupdatingCurrent
) -> [EnergyBurnedLog] {
    var byDay: [Date: (total: Double, keys: Set<String>)] = [:]
    for sample in samples
        where sample.activeKilocalories > 0 && sample.activeKilocalories.isFinite {
        let day = calendar.startOfDay(for: sample.burnedAt)
        let key = energyContributionKey(sample)
        guard byDay[day]?.keys.contains(key) != true else { continue }
        byDay[day, default: (0, [])].keys.insert(key)
        byDay[day]?.total += sample.activeKilocalories
    }
    return byDay.map { EnergyBurnedLog(burnedAt: $0.key, activeKilocalories: $0.value.total) }
}

final class MockWeightLogStore: HealthDeltaStore {
    private(set) var logs: [WeightLog] = []
    private(set) var energyBurnedLogs: [EnergyBurnedLog] = []
    private var bodyAnchor: Data?
    private var energyAnchorData: Data?
    /// In-memory twin of the durable contribution ledger (issue #192).
    private var contributions: [String: (day: Date, kcal: Double)] = [:]
    /// Day totals written without ledger rows (the legacy/drain path).
    private var baselines: [Date: Double] = [:]
    private let calendar = Calendar.autoupdatingCurrent

    func upsert(_ newLogs: [WeightLog]) async throws {
        var byDate = Dictionary(uniqueKeysWithValues: logs.map { ($0.measuredAt, $0) })
        for log in newLogs where log.kilograms > 0 && log.kilograms.isFinite {
            byDate[log.measuredAt] = log
        }
        logs = byDate.values.sorted { $0.measuredAt < $1.measuredAt }
    }
    func upsertEnergyBurned(_ logs: [EnergyBurnedLog]) async throws {
        for log in logs where log.activeKilocalories > 0 && log.activeKilocalories.isFinite {
            baselines[calendar.startOfDay(for: log.burnedAt)] = log.activeKilocalories
        }
        rebuildEnergyRows()
    }

    func bodyMassAnchor() throws -> Data? { bodyAnchor }
    func setBodyMassAnchor(_ anchor: Data) throws { bodyAnchor = anchor }
    func energyAnchor() throws -> Data? { energyAnchorData }
    func setEnergyAnchor(_ anchor: Data) throws { energyAnchorData = anchor }

    func applyBodyMassWindow(_ window: HealthSampleWindow<WeightLog>) async throws -> [WeightLog] {
        let valid = window.samples.filter { $0.kilograms > 0 && $0.kilograms.isFinite }
        let removed = Set(window.removedSampleIDs.map(\.uuidString))
        var byDate = Dictionary(uniqueKeysWithValues: logs.map { ($0.measuredAt, $0) })
        for log in valid { byDate[log.measuredAt] = log }
        byDate = byDate.filter { _, log in
            !(log.sampleID.map { removed.contains($0.uuidString) } ?? false)
        }
        logs = byDate.values.sorted { $0.measuredAt < $1.measuredAt }
        bodyAnchor = window.anchor
        return valid
    }

    func applyEnergyWindow(_ window: HealthSampleWindow<EnergyBurnedLog>) async throws -> [EnergyBurnedLog] {
        let fullHistory = energyAnchorData == nil
        let valid = window.samples.filter {
            $0.activeKilocalories > 0 && $0.activeKilocalories.isFinite
        }
        var affected = Set(valid.map { calendar.startOfDay(for: $0.burnedAt) })
        for id in window.removedSampleIDs {
            if let old = contributions[id.uuidString] { affected.insert(old.day) }
        }
        if fullHistory {
            for day in affected { baselines[day] = nil }
        } else {
            for day in affected where !contributions.values.contains(where: { $0.day == day }) {
                guard let baseline = baselines[day] else { continue }
                contributions["baseline:\(day.timeIntervalSince1970)"] = (day, baseline)
                baselines[day] = nil
            }
        }
        for log in valid {
            contributions[energyContributionKey(log)] =
                (calendar.startOfDay(for: log.burnedAt), log.activeKilocalories)
        }
        for id in window.removedSampleIDs { contributions[id.uuidString] = nil }
        energyAnchorData = window.anchor
        rebuildEnergyRows()
        return energyBurnedLogs
    }

    private func rebuildEnergyRows() {
        var totals = baselines
        for value in contributions.values { totals[value.day, default: 0] += value.kcal }
        energyBurnedLogs = totals.map {
            EnergyBurnedLog(burnedAt: $0.key, activeKilocalories: $0.value)
        }.sorted { $0.burnedAt < $1.burnedAt }
    }
}

final class SupabaseWeightLogStore: HealthDeltaStore {
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

    // Issue #192 — this store exists only when no local store could be opened,
    // so there is nowhere durable to keep a cursor: it reports none, every read
    // stays a full-history read, and the day totals it writes are therefore
    // always derived from the complete sample set (never a delta overwrite).
    func bodyMassAnchor() throws -> Data? { nil }
    func setBodyMassAnchor(_ anchor: Data) throws {}
    func energyAnchor() throws -> Data? { nil }
    func setEnergyAnchor(_ anchor: Data) throws {}

    func applyBodyMassWindow(_ window: HealthSampleWindow<WeightLog>) async throws -> [WeightLog] {
        let valid = window.samples.filter { $0.kilograms > 0 && $0.kilograms.isFinite }
        try await upsert(valid)
        return valid
    }

    func applyEnergyWindow(_ window: HealthSampleWindow<EnergyBurnedLog>) async throws -> [EnergyBurnedLog] {
        let days = energyDayTotals(samples: window.samples)
        try await upsertEnergyBurned(days)
        return days
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

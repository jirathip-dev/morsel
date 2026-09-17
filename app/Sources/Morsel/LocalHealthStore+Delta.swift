import Foundation

// Issue #192 — the durable per-type read cursors and the incremental window
// application they advance with. Split from LocalHealthStore.swift to stay
// inside the strict lint budgets.

/// One sample's place in the local-day contribution ledger.
struct EnergyLedgerContribution {
    let key: String
    let day: Date
    let kcal: Double

    init?(log: EnergyBurnedLog, calendar: Calendar) {
        guard log.activeKilocalories > 0, log.activeKilocalories.isFinite else { return nil }
        key = energyContributionKey(log)
        day = calendar.startOfDay(for: log.burnedAt)
        kcal = log.activeKilocalories
    }
}

extension LocalHealthStore: HealthDeltaStore {
    /// Meta keys holding the opaque HealthKit query anchor (base64) per type.
    /// A legacy Date watermark stored under the same key does not decode as an
    /// anchor, so the first pass after the upgrade reads the full history once
    /// and rebuilds the contribution ledger — never a loss, never a duplicate.
    static let bodyMassAnchorKey = "health.anchor.bodyMass"
    static let energyAnchorKey = "health.anchor.activeEnergyBurned"

    func bodyMassAnchor() throws -> Data? { try readAnchor(Self.bodyMassAnchorKey) }
    func setBodyMassAnchor(_ anchor: Data) throws { try writeAnchor(anchor, Self.bodyMassAnchorKey) }
    func energyAnchor() throws -> Data? { try readAnchor(Self.energyAnchorKey) }
    func setEnergyAnchor(_ anchor: Data) throws { try writeAnchor(anchor, Self.energyAnchorKey) }

    /// Apply one body-mass window and advance its cursor atomically: rows land
    /// (or drop) first, the cursor second — a failure anywhere leaves the
    /// window unapplied and the cursor unchanged, so the next pass replays it.
    func applyBodyMassWindow(_ window: HealthSampleWindow<WeightLog>) async throws -> [WeightLog] {
        let valid = window.samples.filter { $0.kilograms > 0 && $0.kilograms.isFinite }
        try lock.lock(); defer { lock.unlock() }
        try inTransaction {
            try upsertWeightRowsLocked(valid)
            for id in window.removedSampleIDs {
                try runUnsafe(
                    "DELETE FROM weight_samples WHERE sample_id = ?", .text(id.uuidString)
                )
            }
            try writeAnchor(window.anchor, Self.bodyMassAnchorKey)
        }
        return valid
    }

    /// Apply one energy window: every sample becomes a contribution in its own
    /// LOCAL day (keyed by sample identity), removals drop exactly one
    /// contribution, and each touched day's total is recomputed as the sum of
    /// its contributions — prior contributions are never overwritten by a
    /// delta total. The cursor advances with the same transaction.
    func applyEnergyWindow(_ window: HealthSampleWindow<EnergyBurnedLog>) async throws -> [EnergyBurnedLog] {
        try lock.lock(); defer { lock.unlock() }
        let fullHistory = try readAnchor(Self.energyAnchorKey) == nil
        let contributions = window.samples.compactMap {
            EnergyLedgerContribution(log: $0, calendar: calendar)
        }
        var affected = Set(contributions.map(\.day))
        var dayLogs: [EnergyBurnedLog] = []
        try inTransaction {
            for id in window.removedSampleIDs {
                if let day = try ledgerDay(of: id.uuidString) { affected.insert(day) }
            }
            try prepareEnergyLedger(affected: affected, fullHistory: fullHistory)
            try applyEnergyContributions(contributions, removedSampleIDs: window.removedSampleIDs)
            dayLogs = try reconcileEnergyDays(affected)
            try writeAnchor(window.anchor, Self.energyAnchorKey)
        }
        return dayLogs
    }

    // MARK: - Window application helpers (caller holds the lock)

    /// A full-history window carries the complete sample set for the days it
    /// touches, so their ledger is rebuilt from it. A delta window instead
    /// keeps a day's pre-ledger total as a baseline contribution before the
    /// delta lands beside it.
    private func prepareEnergyLedger(affected: Set<Date>, fullHistory: Bool) throws {
        for day in affected {
            if fullHistory {
                try runUnsafe(
                    "DELETE FROM energy_sample_ledger WHERE day_key = ?", .text(Self.dayKey(day))
                )
                continue
            }
            guard try ledgerIsEmpty(day), let prior = try storedEnergyTotal(day) else { continue }
            try insertContribution(key: "baseline:\(Self.dayKey(day))", day: day, kcal: prior)
        }
    }

    private func applyEnergyContributions(
        _ contributions: [EnergyLedgerContribution], removedSampleIDs: [UUID]
    ) throws {
        for contribution in contributions {
            try insertContribution(
                key: contribution.key, day: contribution.day, kcal: contribution.kcal
            )
        }
        for id in removedSampleIDs {
            try runUnsafe(
                "DELETE FROM energy_sample_ledger WHERE sample_key = ?", .text(id.uuidString)
            )
        }
    }

    /// Each touched day's total becomes the sum of its contributions. A day
    /// whose contributions are all gone drops its outbox row (the uploaded
    /// remote row is NOT deleted: energy_burned_logs is upsert-only).
    private func reconcileEnergyDays(_ affected: Set<Date>) throws -> [EnergyBurnedLog] {
        var dayLogs: [EnergyBurnedLog] = []
        for day in affected.sorted() {
            guard let total = try ledgerTotal(day) else {
                try runUnsafe(
                    "DELETE FROM energy_days WHERE day_key = ?", .text(Self.dayKey(day))
                )
                continue
            }
            try upsertEnergyDayLocked(day, total: total)
            dayLogs.append(EnergyBurnedLog(burnedAt: day, activeKilocalories: total))
        }
        return dayLogs
    }

    private func insertContribution(key: String, day: Date, kcal: Double) throws {
        try runUnsafe("""
        INSERT OR REPLACE INTO energy_sample_ledger(sample_key, day_key, kcal)
        VALUES (?, ?, ?)
        """, .text(key), .text(Self.dayKey(day)), .double(kcal))
    }

    private func inTransaction(_ body: () throws -> Void) throws {
        try runUnsafe("BEGIN IMMEDIATE")
        do {
            try body()
            try runUnsafe("COMMIT")
        } catch {
            try? runUnsafe("ROLLBACK")
            throw error
        }
    }

    private func ledgerDay(of sampleKey: String) throws -> Date? {
        try query(
            "SELECT day_key FROM energy_sample_ledger WHERE sample_key = ?", [.text(sampleKey)]
        ).first?.string("day_key").flatMap(Self.date(dayKey:))
    }

    private func ledgerIsEmpty(_ day: Date) throws -> Bool {
        try query(
            "SELECT sample_key FROM energy_sample_ledger WHERE day_key = ? LIMIT 1",
            [.text(Self.dayKey(day))]
        ).isEmpty
    }

    private func ledgerTotal(_ day: Date) throws -> Double? {
        try query(
            "SELECT SUM(kcal) AS total FROM energy_sample_ledger WHERE day_key = ?",
            [.text(Self.dayKey(day))]
        ).first?.double("total")
    }

    private func storedEnergyTotal(_ day: Date) throws -> Double? {
        try query(
            "SELECT total FROM energy_days WHERE day_key = ?", [.text(Self.dayKey(day))]
        ).first?.double("total")
    }

    private func readAnchor(_ key: String) throws -> Data? {
        guard let text = try firstString("SELECT value FROM meta WHERE key = ?", .text(key)) else {
            return nil
        }
        return Data(base64Encoded: text)
    }

    private func writeAnchor(_ anchor: Data, _ key: String) throws {
        try runUnsafe("""
        INSERT INTO meta(key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, .text(key), .text(anchor.base64EncodedString()))
    }
}

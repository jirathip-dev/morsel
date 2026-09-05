import Foundation

// Issue #121 — ONE-TIME local-day re-bucket. Before this change the app
// keyed every cached day row (dashboard snapshots, history windows, local
// active-energy day rows) by the UTC day start. After the switch to device
// LOCAL day keys those rows would be invisible to lookups and, worse, the
// next local-keyed energy aggregate would land beside the legacy row and
// count the same samples twice. This migrator re-keys each stored row to the
// LOCAL day that contains the instant it already stores (the snapshot's own
// date for dashboard payloads, the day-key instant for history/energy rows)
// so NOTHING is dropped and nothing is duplicated. A per-account-file flag
// (health-store meta) makes it run exactly once; failures leave the flag
// unset so the next launch retries.
enum LocalDayMigration {
    /// Runs the cache + energy re-bucket when it has not run yet for this
    /// account file. Best effort by callers: a failure here must never take
    /// the local-first stack down — the flag simply stays unset.
    static func runIfNeeded(cache: LocalSnapshotCache, health: LocalHealthStore) throws {
        guard !health.hasLocalDayKeyMigrationRun() else { return }
        try migrateDashboardCache(cache)
        try migrateHistoryCache(cache)
        try health.migrateEnergyDayKeysToLocalDays()
        health.markLocalDayKeyMigrationRun()
    }

    /// Dashboard snapshots: the payload's own `date` (the day-start instant
    /// the snapshot was fetched for) re-keys the row. Rows whose payload
    /// cannot be decoded are left on their old key — they were unreadable
    /// before the migration too, and dropping them would lose data.
    static func migrateDashboardCache(_ cache: LocalSnapshotCache) throws {
        for row in try cache.allDashboardCacheRows() {
            guard let snapshot = try? JSONDecoder().decode(DashboardSnapshot.self, from: row.payload) else {
                continue
            }
            let newKey = LocalFirstDashboardRepository.dayKey(snapshot.date)
            guard newKey != row.key else { continue }
            try cache.saveDashboardCache(dayKey: newKey, payload: row.payload, savedAt: row.savedAt)
            try cache.removeDashboardCache(dayKey: row.key)
        }
    }

    /// History windows: cache keys are "<dayKey(end)>-<days>"; re-derive the
    /// end instant from the key's stored day-start value.
    static func migrateHistoryCache(_ cache: LocalSnapshotCache) throws {
        for row in try cache.allHistoryCacheRows() {
            guard let split = row.key.lastIndex(of: "-") else { continue }
            let dayKey = String(row.key[..<split])
            let days = String(row.key[row.key.index(after: split)...])
            guard let end = TimeInterval(dayKey) else { continue }
            let newKey = "\(LocalFirstDashboardRepository.dayKey(Date(timeIntervalSince1970: end)))-\(days)"
            guard newKey != row.key else { continue }
            try cache.saveHistoryCache(cacheKey: newKey, payload: row.payload, savedAt: row.savedAt)
            try cache.removeHistoryCache(cacheKey: row.key)
        }
    }
}

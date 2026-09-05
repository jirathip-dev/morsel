import Foundation

// Issue #113 — Goals page context. The Goals tab needs the stored goals
// row, the profile row (with write times) and the newest synced body-mass
// sample in ONE read so it can apply the same recency mirror the server's
// get_goals uses (manual effective iff manual row >= profile row), surface
// the superseded-manual note, and render the read-only profile line with
// the exact weight the computed path uses (amendment A weight_used analog).

struct SyncedWeightSample: Equatable, Sendable {
    let kilograms: Double
    let measuredAt: Date

    init(weightLog: WeightLog) {
        kilograms = weightLog.kilograms
        measuredAt = weightLog.measuredAt
    }

    init(kilograms: Double, measuredAt: Date) {
        self.kilograms = kilograms
        self.measuredAt = measuredAt
    }
}

struct GoalsPageContext: Equatable, Sendable {
    let stored: StoredDashboardGoal?
    let profile: DashboardProfile?
    /// Newest synced sample (remote weight_logs, or the newer local
    /// weight_samples overlay) — nil when only the typed profile weight
    /// exists.
    let latestWeight: SyncedWeightSample?
    /// False when the read came from cache without touching the profiles
    /// table — the UI must not claim "no profile yet" on that path.
    let profileRowRead: Bool

    /// A copy with a newer local sample as the latest weight (issue #113).
    func withLatestWeight(_ sample: SyncedWeightSample) -> GoalsPageContext {
        GoalsPageContext(
            stored: stored, profile: profile,
            latestWeight: sample, profileRowRead: profileRowRead
        )
    }
}

extension DashboardRepository {
    func cachedToday(userID: UUID, date: Date) async throws -> DashboardSnapshot? { nil }

    func cachedHistory(userID: UUID, end: Date, days: Int) async throws -> HistoryOverview? { nil }

    func localMealRecord(userID: UUID, localMealID: UUID) async throws -> MealRecord? { nil }

    /// Issue #123 — no goals cache by default (plain remote repositories);
    /// the local-first facade overrides with the real snapshot cache.
    func cachedGoals(userID: UUID) async throws -> StoredDashboardGoal? { nil }

    /// Default Goals-page context: the stored row only — no profile or
    /// weight read (test doubles). Supabase and local-first repositories
    /// override with the full recency + profile read.
    func loadGoalsContext(userID: UUID) async throws -> GoalsPageContext {
        GoalsPageContext(
            stored: try await loadGoals(userID: userID),
            profile: nil,
            latestWeight: nil,
            profileRowRead: false
        )
    }
}

extension SupabaseDashboardRepository {
    /// Goals page context (mirrors the server's get_goals inputs): the
    /// goals row, the profile row and the newest weight_logs sample —
    /// newest measured_at anywhere, exactly like compute_targets reads.
    func loadGoalsContext(userID: UUID) async throws -> GoalsPageContext {
        guard let client else { throw MorselError.configurationMissing }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        let goalRows: [GoalResponse] = try await client.from("goals")
            .select("calorie_target_kcal,protein_g,carbs_g,fat_g,source,updated_at")
            .eq("user_id", value: authenticatedUserID.uuidString)
            .limit(1)
            .execute()
            .value
        let profileRows: [ProfileResponse] = try await client.from("profiles")
            .select("sex,age_years,height_cm,weight_kg,activity_level,diet_goal,goal_weight_kg,updated_at")
            .eq("user_id", value: authenticatedUserID.uuidString)
            .limit(1)
            .execute()
            .value
        let weightRows: [WeightResponse] = try await client.from("weight_logs")
            .select("measured_at,kg")
            .eq("user_id", value: authenticatedUserID.uuidString)
            .order("measured_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return GoalsPageContext(
            stored: try goalRows.first.map(parseStoredGoal),
            profile: try profileRows.first.map(parseProfile),
            latestWeight: weightRows.compactMap(parseWeight).first.map {
                SyncedWeightSample(kilograms: $0.kilograms, measuredAt: $0.date)
            },
            profileRowRead: true
        )
    }
}

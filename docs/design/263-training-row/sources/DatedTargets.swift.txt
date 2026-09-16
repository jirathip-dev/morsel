import Foundation
import Supabase

/// The shared RPC value. Missing baseline is unavailable, not today's goal.
struct DatedTarget: Codable, Equatable, Sendable {
    let date: String
    let timezone: String
    let baseline: DatedBaseline?
    let confirmedAdditionKcal: Double
    let additionRevision: DatedAdditionRevision?
    let totalTargetKcal: Double?

    enum CodingKeys: String, CodingKey {
        case date, timezone, baseline
        case confirmedAdditionKcal = "confirmed_addition_kcal"
        case additionRevision = "addition_revision"
        case totalTargetKcal = "total_target_kcal"
    }

    func attributableTotal(on day: Date, calendar: Calendar) -> Double? {
        guard date == Self.label(day, calendar: calendar), timezone == calendar.timeZone.identifier,
              let baseline, baseline.sourceVersion == "targets-v1",
              UUID(uuidString: baseline.revisionID) != nil,
              let observed = MorselDate.date(baseline.recordedAt),
              let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)),
              observed < next, baseline.hasValidSourceDate,
              hasValidAddition,
              baseline.goal.calorieTargetKcal.isFinite, baseline.goal.calorieTargetKcal >= 0,
              confirmedAdditionKcal.isFinite, confirmedAdditionKcal >= 0,
              let totalTargetKcal, totalTargetKcal.isFinite,
              abs(totalTargetKcal - (baseline.goal.calorieTargetKcal + confirmedAdditionKcal))
                <= max(1, abs(totalTargetKcal)) * 1e-12 else { return nil }
        return totalTargetKcal
    }

    private var hasValidAddition: Bool {
        guard let additionRevision else { return confirmedAdditionKcal == 0 }
        return UUID(uuidString: additionRevision.revisionID) != nil
            && MorselDate.date(additionRevision.recordedAt) != nil
            && TimeZone(identifier: additionRevision.timezone) != nil
    }

    static func label(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct DatedBaseline: Codable, Equatable, Sendable {
    let revisionID: String
    let recordedAt: String
    let effectiveDate: String
    let timezone: String
    let sourceVersion: String
    let goal: DatedGoal
    let profileUpdatedAt: String?
    let goalsUpdatedAt: String?
    let weightMeasuredAt: String?

    var hasValidSourceDate: Bool {
        guard let zone = TimeZone(identifier: timezone),
              let observed = MorselDate.date(recordedAt) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return effectiveDate == DatedTarget.label(observed, calendar: calendar)
    }

    enum CodingKeys: String, CodingKey {
        case timezone, goal
        case revisionID = "revision_id"
        case recordedAt = "recorded_at"
        case effectiveDate = "effective_date"
        case sourceVersion = "source_version"
        case profileUpdatedAt = "profile_updated_at"
        case goalsUpdatedAt = "goals_updated_at"
        case weightMeasuredAt = "weight_measured_at"
    }
}

struct DatedGoal: Codable, Equatable, Sendable {
    let calorieTargetKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let source: GoalSource

    enum CodingKeys: String, CodingKey {
        case source
        case calorieTargetKcal = "calorie_target_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }
}

struct DatedAdditionRevision: Codable, Equatable, Sendable {
    let revisionID: String
    let recordedAt: String
    let timezone: String
    let previousRevisionID: String?
    let historicalConfirmation: Bool
    let manualGoalAcknowledged: Bool

    enum CodingKeys: String, CodingKey {
        case timezone
        case revisionID = "revision_id"
        case recordedAt = "recorded_at"
        case previousRevisionID = "previous_revision_id"
        case historicalConfirmation = "historical_confirmation"
        case manualGoalAcknowledged = "manual_goal_acknowledged"
    }
}

struct DatedTargetReadParams: Encodable {
    let userID: UUID
    let startDate: String
    let endDate: String
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case userID = "p_user_id"
        case startDate = "p_start_date"
        case endDate = "p_end_date"
        case timezone = "p_timezone"
    }
}

/// Shared #254 write seam: no UI-local persistence and no baseline input.
struct DatedTargetAdditionParams: Encodable {
    let userID: UUID
    let date: String
    let timezone: String
    let additionKcal: Double
    let mutationID: UUID
    let expectedRevision: UUID?
    let historicalConfirmation: Bool
    let manualGoalAcknowledged: Bool

    enum CodingKeys: String, CodingKey {
        case userID = "p_user_id"
        case date = "p_date"
        case timezone = "p_timezone"
        case additionKcal = "p_addition_kcal"
        case mutationID = "p_mutation_id"
        case expectedRevision = "p_expected_revision"
        case historicalConfirmation = "p_historical_confirmation"
        case manualGoalAcknowledged = "p_manual_goal_acknowledged"
    }
}

extension SupabaseDashboardRepository {
    func loadDatedTargets(userID: UUID, start: Date, end: Date,
                          calendar: Calendar = .autoupdatingCurrent) async throws -> [DatedTarget] {
        guard let client else { throw MorselError.configurationMissing }
        let authenticatedUserID = try await requireSession(client, userID: userID)
        return try await client.rpc("get_dated_targets", params: DatedTargetReadParams(
            userID: authenticatedUserID, startDate: DatedTarget.label(start, calendar: calendar),
            endDate: DatedTarget.label(end, calendar: calendar), timezone: calendar.timeZone.identifier
        )).execute().value
    }

    func saveDatedTargetAddition(_ params: DatedTargetAdditionParams) async throws -> DatedTarget {
        guard let client else { throw MorselError.configurationMissing }
        _ = try await requireSession(client, userID: params.userID)
        return try await client.rpc("set_dated_target_addition", params: params).execute().value
    }
}

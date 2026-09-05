import Foundation

// Issue #113 — app-side mirror of the server's "latest update wins" goal
// rule (server/service.ts resolveEffectiveGoal + toGoalSummary): a stored
// manual goal is effective only while it is at least as new as the profile
// row; otherwise the freshly computed target is effective and a COMPLETE
// stale manual row rides along as the superseded payload the Goals page
// turns into the one-line calm note. Amendment A: the computed path uses
// the latest synced weight (newest weight_samples/weight_logs measured_at)
// with the profile value as fallback, exactly like the server's
// compute_targets weight_used.

struct SupersededManualGoal: Equatable, Sendable {
    let calorieTargetKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let updatedAt: Date
}

extension DashboardMath {
    /// Server recency test (mirror): a stored manual row is current only
    /// when its write time exists and is >= the profile's write time.
    /// Missing profile row -> manual stays (legacy, nothing newer exists);
    /// missing manual write time -> computed (the manual cannot prove it is
    /// newer than the profile).
    static func manualIsCurrent(stored: StoredDashboardGoal?, profile: DashboardProfile?) -> Bool {
        guard let stored, stored.source == .manual else { return false }
        guard let profile else { return true }
        guard let storedUpdatedAt = stored.updatedAt else { return false }
        guard let profileUpdatedAt = profile.updatedAt else { return true }
        return storedUpdatedAt >= profileUpdatedAt
    }

    static func effectiveGoal(
        stored: StoredDashboardGoal?,
        profile: DashboardProfile?,
        latestWeightKg: Double? = nil
    ) -> DashboardGoal? {
        guard let profile else {
            // Legacy no-profile read: only a COMPLETE manual row can be the
            // goal (there is no profile to compute from).
            guard let stored, stored.source == .manual,
                  let calorieTargetKcal = stored.calorieTargetKcal,
                  let proteinG = stored.proteinG,
                  let carbsG = stored.carbsG,
                  let fatG = stored.fatG else {
                return nil
            }
            return DashboardGoal(
                calorieTargetKcal: calorieTargetKcal,
                proteinG: proteinG,
                carbsG: carbsG,
                fatG: fatG,
                source: .manual
            )
        }
        let computed = computedGoal(for: profile, latestWeightKg: latestWeightKg)
        guard manualIsCurrent(stored: stored, profile: profile) else {
            return computed
        }
        // Current manual row wins; missing fields fall back to the computed
        // values (toGoalSummary semantics — the DB row may be partial).
        return DashboardGoal(
            calorieTargetKcal: stored?.calorieTargetKcal ?? computed.calorieTargetKcal,
            proteinG: stored?.proteinG ?? computed.proteinG,
            carbsG: stored?.carbsG ?? computed.carbsG,
            fatG: stored?.fatG ?? computed.fatG,
            source: .manual
        )
    }

    static func computedGoal(
        for profile: DashboardProfile,
        latestWeightKg: Double? = nil
    ) -> DashboardGoal {
        let sexOffset: Double = profile.sex == .male ? 5 : -161
        let weightTerm = 10 * (latestWeightKg ?? profile.weightKg)
        let heightTerm = 6.25 * profile.heightCm
        let ageTerm = 5 * Double(profile.ageYears)
        let bmr = weightTerm + heightTerm - ageTerm + sexOffset
        let activityFactor: Double = switch profile.activityLevel {
        case .sedentary:
            1.2
        case .light:
            1.375
        case .moderate:
            1.55
        case .active:
            1.725
        case .veryActive:
            1.9
        }
        let tdee = (bmr * activityFactor).rounded()
        let calorieTarget: Double = switch profile.dietGoal {
        case .lose:
            max(1_200, tdee - 500)
        case .maintain:
            tdee
        case .gain:
            tdee + 300
        }
        return DashboardGoal(
            calorieTargetKcal: calorieTarget,
            proteinG: (calorieTarget * 0.3 / 4).rounded(),
            carbsG: (calorieTarget * 0.45 / 4).rounded(),
            fatG: (calorieTarget * 0.25 / 9).rounded(),
            source: .computed
        )
    }

    /// The superseded payload for the Goals page note: only a COMPLETE
    /// manual row with a write time that lost the recency race is reported
    /// (server superseded_manual emission rule).
    static func supersededManual(
        stored: StoredDashboardGoal?,
        profile: DashboardProfile?
    ) -> SupersededManualGoal? {
        guard let stored, stored.source == .manual,
              let calorieTargetKcal = stored.calorieTargetKcal,
              let proteinG = stored.proteinG,
              let carbsG = stored.carbsG,
              let fatG = stored.fatG,
              let updatedAt = stored.updatedAt,
              !manualIsCurrent(stored: stored, profile: profile) else {
            return nil
        }
        return SupersededManualGoal(
            calorieTargetKcal: calorieTargetKcal,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            updatedAt: updatedAt
        )
    }
}

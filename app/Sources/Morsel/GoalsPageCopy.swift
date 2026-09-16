import Foundation

// Issue #113 — calm page copy (superseded note + read-only profile line).
enum GoalsPageCopy {
    static func profileLine(context: GoalsPageContext) -> String? {
        guard let profile = context.profile else {
            return context.profileRowRead
                ? "no profile yet — tell your agent your height, weight, age and activity"
                : nil
        }
        let sample = context.latestWeight
        var text = "computed from \(trimmed(sample?.kilograms ?? profile.weightKg)) kg"
        if let sample {
            text += " (Health · \(MorselStamp.dayMonth(sample.measuredAt)))"
        } else {
            text += " (profile)"
        }
        text += " · \(trimmed(profile.heightCm)) cm · \(profile.ageYears) y"
            + " · \(activityWord(profile.activityLevel)) · \(dietWord(profile.dietGoal))"
        if let updatedAt = profile.updatedAt {
            text += " — set via your agent \(MorselStamp.dayMonth(updatedAt))"
        }
        return text
    }

    /// One-line calm note for the stale-manual state: the profile changed
    /// after the manual row, so the fields now hold the new computed
    /// targets and the note names the manual numbers they replaced.
    static func supersededLine(stored: StoredDashboardGoal?, profile: DashboardProfile?) -> String? {
        guard let superseded = DashboardMath.supersededManual(stored: stored, profile: profile) else {
            return nil
        }
        let prefix = profile?.updatedAt.map { "your profile changed on \(MorselStamp.dayMonth($0));" }
            ?? "your profile changed;"
        return "\(prefix) these are the new computed targets — your earlier manual numbers were "
            + "\(MorselFormat.number(superseded.calorieTargetKcal)) / \(MorselFormat.number(superseded.proteinG))"
            + " / \(MorselFormat.number(superseded.carbsG)) / \(MorselFormat.number(superseded.fatG))"
    }

    private static func activityWord(_ level: ProfileActivityLevel) -> String {
        switch level {
        case .sedentary: return "sedentary"
        case .light: return "light"
        case .moderate: return "moderate"
        case .active: return "active"
        case .veryActive: return "very active"
        }
    }

    private static func dietWord(_ goal: ProfileDietGoal) -> String {
        switch goal {
        case .lose: return "lose"
        case .maintain: return "maintain"
        case .gain: return "gain"
        }
    }

    /// 63 → "63", 61.5 → "61.5", 167 → "167" (fixed POSIX decimal).
    private static func trimmed(_ value: Double) -> String {
        trimmedFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let trimmedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

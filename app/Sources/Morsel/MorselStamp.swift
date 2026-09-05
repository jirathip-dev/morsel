import Foundation

// Issue #113 — deterministic calendar stamps for the calm notes. Fixed
// en_US_POSIX spellings keep the copy stable across device locales and
// match the approved examples ("5 Sep", "07:32").

enum MorselStamp {
    static func dayMonth(_ date: Date) -> String {
        dayMonthFormatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private static let dayMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// Issue #113 amendment C — the Today margin note becomes "moved 412 kcal ·
// Apple Health · 07:32": the day total is the snapshot's active-energy
// value (energy_days-derived), and the time is the SAME #112 calm-status
// stamp (lastSuccessfulUpload) — never a second clock. The note stays
// hidden while the total is 0 and remains context-only (V1 locked: it never
// feeds the eaten readout).
enum ActiveEnergyMarginNote {
    static func line(totalKcal: Double, lastImport: Date?) -> String? {
        guard totalKcal.isFinite, totalKcal > 0 else {
            return nil
        }
        let base = "moved \(MorselFormat.number(totalKcal)) kcal"
        guard let lastImport else {
            return "\(base) today"
        }
        return "\(base) · Apple Health · \(MorselStamp.time(lastImport))"
    }
}

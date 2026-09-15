import Foundation

/// Presentation values only; not a stored/API dated-target contract.
struct WeightDeltaDay: Identifiable, Equatable {
    let date: Date
    let logged: Bool?
    let eatenKcal: Double?
    var foodTargetKcal: Double?
    var targetSource: String?
    var id: Date { date }

    init(date: Date, logged: Bool?, eatenKcal: Double?,
         foodTargetKcal: Double? = nil, targetSource: String? = nil) {
        self.date = date
        self.logged = logged
        self.eatenKcal = logged == true ? eatenKcal : nil
        self.foodTargetKcal = foodTargetKcal
        self.targetSource = targetSource
    }

    /// The payload's single current goal proves no dated target, even on a
    /// cached read. In particular, do not promote it into today's snapshot.
    init(day: HistoryDay) {
        self.init(date: day.date, logged: day.logged, eatenKcal: day.eatenKcal)
    }

    var deltaKcal: Double? {
        guard logged == true, let eatenKcal, eatenKcal.isFinite,
              let foodTargetKcal, foodTargetKcal.isFinite, foodTargetKcal > 0,
              let targetSource, !targetSource.isEmpty else { return nil }
        return eatenKcal - foodTargetKcal
    }

    var status: String {
        if logged == false { return "no food log" }
        if logged == nil { return "food log unavailable" }
        guard let deltaKcal else { return "food target unavailable" }
        return "\(deltaKcal > 0 ? "+" : "")\(MorselFormat.number(deltaKcal)) kcal"
    }

    var symbol: String {
        if logged == false { return "×" }
        if logged == nil { return "·" }
        guard let deltaKcal else { return "?" }
        return deltaKcal == 0 ? "○" : (deltaKcal > 0 ? "+" : "−")
    }
}

/// Weight keeps its full existing window (30 days even in the 7-day ledger).
/// Unknown food dates outside the loaded ledger are not classified as unlogged.
struct WeightDeltaTimeline {
    let days: [WeightDeltaDay]
    let domain: ClosedRange<Date>

    init(days: [WeightDeltaDay], points: [WeightTrendPoint], today: Date,
         calendar: Calendar = .autoupdatingCurrent) {
        let dates = days.map(\.date) + points.map(\.date)
        let first = calendar.startOfDay(for: dates.min() ?? today)
        let last = calendar.startOfDay(for: dates.max() ?? today)
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86_400)
        domain = first...end
        let byDate = Dictionary(days.map { (calendar.startOfDay(for: $0.date), $0) },
                                uniquingKeysWith: { _, latest in latest })
        var rows: [WeightDeltaDay] = []
        var cursor = first
        while cursor < end {
            rows.append(byDate[cursor] ?? WeightDeltaDay(date: cursor, logged: nil, eatenKcal: nil))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        self.days = rows
    }

    var axisDates: [Date] {
        let step = max(1, days.count / 4)
        return days.enumerated().filter { $0.offset % step == 0 || $0.offset == days.count - 1 }.map(\.element.date)
    }

    var deltaLimit: Double {
        max(1_000, days.compactMap(\.deltaKcal).map(abs).max() ?? 0)
    }
}

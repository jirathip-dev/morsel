import Foundation

struct TrainingFuelReading: Equatable {
    let value: String
    let sampleDate: Date
    let source: String
    let checkedAt: Date

    func detail(for day: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let freshness = calendar.isDate(sampleDate, inSameDayAs: day)
            ? "Recorded" : "Last known · not today's total"
        return "\(freshness) · \(stamp(sampleDate))\n\(source) · checked \(stamp(checkedAt))"
    }

    private func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct TrainingFuelContext: Equatable {
    var movement: TrainingFuelReading?
    var workout: TrainingFuelReading?

    static func value(_ reading: TrainingFuelReading?) -> String { reading?.value ?? "Unavailable" }
}

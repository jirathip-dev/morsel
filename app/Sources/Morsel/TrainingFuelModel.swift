import Combine
import Foundation

/// P1 is a user-authored note, not an exercise-calorie calculation. Owned by
/// the signed-in shell; intentionally session-local until a durable contract
/// is approved. No repository, meal, Health or saved-goal write capability.
@MainActor
final class TrainingFuelModel: ObservableObject {
    @Published private(set) var day: Date?
    /// Issue #254 — the baseline and the confirmed addition are stored with
    /// day ownership and only READ through `baseline`/`addition`, which expose
    /// the current day's state alone. A rollover therefore cannot leak the
    /// previous day's note or target into the new day, even before the next
    /// refresh. Confirmed contract: a goal observed for TODAY is a baseline
    /// revision (it takes effect today and preserves a confirmed addition);
    /// a goal observed for any other date is never used as this day's baseline.
    @Published private var storedBaseline: DashboardGoal?
    @Published private var confirmedAddition: Double?
    @Published var draft = ""
    @Published var acknowledgesDayOnly = false
    @Published private(set) var isEditing = false
    @Published private(set) var isPending = false
    @Published private(set) var error: String?
    @Published var longerDay = false // Explicit user context, never inferred from Health.
    @Published var context = TrainingFuelContext()

    private var operation = UUID()
    private var calendar: Calendar
    private let now: () -> Date
    private let accept: () async throws -> Void

    init(calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init,
         accept: @escaping () async throws -> Void = { await Task.yield(); try Task.checkCancellation() }) {
        self.calendar = calendar
        self.now = now
        self.accept = accept
    }

    var isCurrentDay: Bool { day.map { calendar.isDate($0, inSameDayAs: now()) } ?? false }
    var baseline: DashboardGoal? { isCurrentDay ? storedBaseline : nil }
    var addition: Double? { isCurrentDay ? confirmedAddition : nil }
    var target: Double? {
        guard let baseline else { return nil }
        return baseline.calorieTargetKcal + (addition ?? 0)
    }
    var requiresAcknowledgement: Bool { baseline?.source == .manual }
    var canConfirm: Bool {
        isEditing && !isPending && isCurrentDay && parsedAmount != nil
            && (!requiresAcknowledgement || acknowledgesDayOnly)
    }
    private var parsedAmount: Double? {
        // Technical validation only: a finite, positive addition, no clinical
        // upper bound, suggestion, preset or target reduction. A zero or a
        // removal is expressed by undo, never by an entered amount.
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let amount = Double(text.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")),
              amount.isFinite, amount > 0, let baseline,
              (baseline.calorieTargetKcal + amount).isFinite else { return nil }
        return amount
    }

    func synchronize(_ snapshot: DashboardSnapshot?, calendar: Calendar? = nil) {
        if let calendar, calendar.timeZone != self.calendar.timeZone {
            self.calendar = calendar
            reset()
        }
        let today = self.calendar.startOfDay(for: now())
        if day != today { reset(); day = today }
        guard let snapshot, self.calendar.isDate(snapshot.date, inSameDayAs: today) else { return }
        // Only a goal observed for TODAY supplies a baseline, so a completed
        // past date is never rewritten. A revision of today's goal takes
        // effect immediately and leaves a confirmed addition in place.
        storedBaseline = snapshot.goal
    }

    func beginReview() {
        guard isCurrentDay, baseline != nil, !isPending else { return }
        draft = addition.map { String($0) } ?? ""
        acknowledgesDayOnly = false
        error = nil
        isEditing = true
    }

    func cancel() {
        operation = UUID() // late completion cannot apply a cancelled draft
        isEditing = false
        isPending = false
        error = nil
    }

    func confirm() async {
        guard canConfirm, let amount = parsedAmount else { return }
        let token = UUID()
        operation = token
        isPending = true
        error = nil
        do {
            try await accept()
            guard operation == token else { return }
            guard isCurrentDay else {
                isPending = false
                error = "The day changed. Nothing applied; cancel and review the new day."
                return
            }
            confirmedAddition = amount
            isPending = false
            isEditing = false
        } catch {
            guard operation == token else { return }
            isPending = false
            self.error = "Could not apply this local note. Nothing changed. Retry or cancel."
        }
    }

    func undo() {
        guard isCurrentDay, !isPending else { return }
        confirmedAddition = nil
        cancel()
        draft = ""
        acknowledgesDayOnly = false
    }

    private func reset() {
        cancel()
        storedBaseline = nil
        confirmedAddition = nil
        draft = ""
        acknowledgesDayOnly = false
        longerDay = false
        context = TrainingFuelContext()
    }
}

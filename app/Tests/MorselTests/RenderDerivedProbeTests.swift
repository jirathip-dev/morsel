import SwiftUI
import UIKit
import XCTest
@testable import Morsel

/// Issue #195 — measurement-first probe. It prints the derived-work cost of the
/// production computed properties at both fixture sizes plus the wall time and
/// body-evaluation counts of repeated unchanged updates. It compiles against
/// the pre-change base as well, so the same harness records the baseline and
/// the post-change numbers under identical conditions.
@MainActor
final class RenderDerivedProbeTests: XCTestCase {
    private let account = UUID()
    private let day = DashboardMath.startOfLocalDay(Date(timeIntervalSince1970: 1_770_000_000))

    private func fixture(_ name: String) -> DashboardSnapshot {
        name == "small"
            ? RenderDerivedFixture.snapshot(day: day, meals: 6, itemsPerMeal: 2)
            : RenderDerivedFixture.snapshot(day: day, meals: 40, itemsPerMeal: 12)
    }

    private func microseconds(_ iterations: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1000
    }

    private func formatted(_ value: Double) -> String { String(format: "%.3f", value) }

    private func printLine(_ text: String) { print("ISSUE195-MEASURE \(text)") }

    /// Per-call cost of every production derived computation at both sizes.
    func testDerivedWorkCostsSmallAndDense() async throws {
        for name in ["small", "dense"] {
            let data = fixture(name)
            let items = data.meals.reduce(0) { $0 + $1.items.count }
            let model = DashboardViewModel(repository: ProbeRemote(snapshot: data), userID: account)
            await model.load()
            XCTAssertEqual(model.snapshot?.meals.count, data.meals.count)
            let direct = microseconds(2000) { _ = DashboardMath.totals(for: data.meals) }
            let totals = microseconds(2000) { _ = model.totals }
            let groups = microseconds(2000) { _ = model.mealGroups }
            let review = microseconds(2000) { _ = model.reviewItems }
            let gutter = microseconds(2000) { _ = JournalPageFurniture.gutterDate(day) }
            // The revision check compares the day's meals on every snapshot write;
            // the twin has equal content but distinct storage, so this is the real
            // deep-compare cost the fix pays once per write.
            let twin = (try? JSONDecoder().decode([MealRecord].self,
                                                  from: JSONEncoder().encode(data.meals))) ?? []
            let equality = microseconds(2000) { _ = twin == data.meals }
            printLine("fixture=\(name) meals=\(data.meals.count) items=\(items) "
                + "math_totals_us=\(formatted(direct)) view_totals_us=\(formatted(totals)) "
                + "meal_groups_us=\(formatted(groups)) review_items_us=\(formatted(review)) "
                + "gutter_date_us=\(formatted(gutter)) meals_equality_us=\(formatted(equality))")
            XCTAssertGreaterThan(direct, 0)
            XCTAssertEqual(model.mealGroups.count, 4)
        }
    }

    /// Per-call cost of the History derived list/summary properties.
    func testHistoryDerivedWorkCosts() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let overview = HistoryOverview(days: (0..<30).reversed().map { offset in
            HistoryDay(date: calendar.date(byAdding: .day, value: -offset, to: day) ?? day,
                       eatenKcal: 1_800 + Double(offset), logged: true)
        }, goal: DashboardGoal(calorieTargetKcal: 2_000, proteinG: 100, carbsG: 250, fatG: 55,
                               source: .manual))
        let remote = ProbeRemote(snapshot: fixture("small"))
        remote.overview = overview
        let model = HistoryViewModel(repository: remote, userID: account, dateProvider: { self.day })
        await model.load()
        XCTAssertEqual(model.overview?.days.count, 30)
        let chart = microseconds(2000) { _ = model.chartDays }
        let average = microseconds(2000) { _ = model.averageKcal }
        let over = microseconds(2000) { _ = model.daysOver }
        let logged = microseconds(2000) { _ = model.daysLogged }
        let streak = microseconds(2000) { _ = model.streak }
        printLine("history days=30 chart_days_us=\(formatted(chart)) average_us=\(formatted(average)) "
            + "days_over_us=\(formatted(over)) days_logged_us=\(formatted(logged)) "
            + "streak_us=\(formatted(streak))")
        XCTAssertEqual(model.chartDays.count, 7)
    }

    /// The production body path's access pattern over one unchanged update
    /// cycle: the Today hero reads totals 6×, the log reads mealGroups 2× and
    /// reviewItems 1×. The dense day is the expensive case.
    func testModelWorkloadDenseUnchangedUpdates() async throws {
        let data = fixture("dense")
        let remote = ProbeRemote(snapshot: data)
        let model = DashboardViewModel(repository: remote, userID: account)
        await model.load()
        let cycles = 200
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<cycles {
            await model.load()
            for _ in 0..<6 { _ = model.totals }
            for _ in 0..<2 { _ = model.mealGroups }
            _ = model.reviewItems
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000
        printLine("model_workload cycles=\(cycles) day_reads=\(remote.dayReads) "
            + "accesses=\(cycles * 9) total_us=\(formatted(elapsed)) "
            + "per_cycle_us=\(formatted(elapsed / Double(cycles)))")
        XCTAssertGreaterThan(remote.dayReads, cycles)
    }

    /// Mounts the real Today page and drives repeated unchanged updates: the
    /// wall time and the body-evaluation count one update cycle costs.
    func testMountedTodayRepeatedUnchangedUpdates() async throws {
        let data = fixture("small")
        let remote = ProbeRemote(snapshot: data)
        let model = DashboardViewModel(repository: remote, userID: account)
        await model.load()
        let counter = ProbeBodyCounter()
        let window = RenderDerivedMount.window(VStack(spacing: 0) {
            TodayView(viewModel: model, showSettings: {}, addMeal: {})
            ProbeBodyCounterView(model: model, counter: counter)
        }
        .environment(\.trainingFuelHosted, true)
        .environmentObject(TrainingFuelModel()))
        defer { window.isHidden = true }
        RenderDerivedMount.pump(0.5)
        let start = DispatchTime.now().uptimeNanoseconds
        let cycles = 40
        for _ in 0..<cycles {
            await model.load()
            RenderDerivedMount.pump(0.02)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000
        printLine("mounted_today fixture=small cycles=\(cycles) day_reads=\(remote.dayReads) "
            + "body_evals=\(counter.evaluations) total_us=\(formatted(elapsed)) "
            + "per_cycle_us=\(formatted(elapsed / Double(cycles)))")
        XCTAssertGreaterThan(counter.evaluations, 0)
        XCTAssertGreaterThan(remote.dayReads, cycles)
    }
}

/// Counts its own body evaluations while observing the same day model the real
/// page observes: a proxy for how many times an update cycle re-evaluates the
/// derived work.
@MainActor
final class ProbeBodyCounter: ObservableObject {
    private(set) var evaluations = 0
    func count() { evaluations += 1 }
}

struct ProbeBodyCounterView: View {
    @ObservedObject var model: DashboardViewModel
    let counter: ProbeBodyCounter

    var body: some View {
        counter.count()
        return Color.clear.frame(width: 1, height: 1)
    }
}

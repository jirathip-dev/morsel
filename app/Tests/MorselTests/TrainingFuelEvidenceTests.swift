import SwiftUI
import UIKit
import XCTest
@testable import Morsel

/// Simulator-hosted production Today/editor, fictional inputs. No Health,
/// network, meal or goal writes. The gate driver also takes simctl screenshots
/// at the READY markers; attachments are a reproducible in-bundle fallback.
@MainActor
final class TrainingFuelEvidenceTests: XCTestCase {
    func testPaperAndNightPolicyStates() async throws {
        MorselFontCatalog.register()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        let states = ["normal", "hard-confirmed", "unconfirmed", "missing", "stale", "manual", "save-failure",
                      "undo", "rollover"]
        for (theme, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            for state in states {
                let fixture = try await fixture(state)
                let editor = ["unconfirmed", "manual", "save-failure"].contains(state)
                let page = AnyView(VStack(spacing: 0) {
                    TodayView(viewModel: fixture.viewModel, showSettings: {}, addMeal: {})
                    JournalTabBar(pager: JournalPagerModel())
                }.environmentObject(fixture.model).environment(\.trainingFuelHosted, true))
                let content = editor ? AnyView(TrainingFuelEditor(model: fixture.model)) : page
                window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                window.rootViewController = UIHostingController(rootView: content.preferredColorScheme(scheme))
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(250))
                window.layoutIfNeeded()
                if !editor, let scroll = scrollView(window) {
                    scroll.setContentOffset(CGPoint(x: 0, y: 375), animated: false)
                    try await Task.sleep(for: .milliseconds(100))
                }
                let name = "254-\(theme)-\(state)"
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                print("FUEL_CAPTURE_READY \(name)")
                fflush(stdout)
                // Bounded window for the serial simctl capture driver.
                try await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func scrollView(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView($0) }.first
    }

    private func fixture(_ state: String) async throws -> (model: TrainingFuelModel, viewModel: DashboardViewModel) {
        let day = Date(timeIntervalSince1970: 1_789_300_800)
        let nextDay = day.addingTimeInterval(86_400)
        // Issue #254 — the evidence fixture drives the real model clock so a
        // day rollover is exercised through the production day-ownership code.
        var clock = day
        let model = TrainingFuelModel(now: { clock }, accept: {
            if state == "save-failure" { throw CocoaError(.fileWriteUnknown) }
        })
        let goal = DashboardGoal(calorieTargetKcal: 2_000, proteinG: 90, carbsG: 250, fatG: 60,
                                 source: state == "manual" ? .manual : .computed)
        let item = MealItem(itemID: UUID(), name: "Focaccia", quantity: 1, unit: .serving, caloriesKcal: 230,
                            proteinG: 7, carbsG: 40, fatG: 5, fiberG: nil, sugarG: nil,
                            confidence: 0.9, notes: "Fictional simulator fixture")
        let shown = state == "rollover" ? nextDay : day
        let meal = MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: shown, source: .manual, items: [item])
        func snapshot(for shown: Date) -> DashboardSnapshot {
            DashboardSnapshot(date: shown, meals: [meal], goal: goal)
        }
        let viewModel = DashboardViewModel(repository: MockDashboardRepository(snapshot: snapshot(for: shown)),
                                           userID: UUID(), dateProvider: { shown })
        await viewModel.load()
        model.synchronize(snapshot(for: day))
        if state != "missing" {
            let sampleDate = state == "stale" ? day.addingTimeInterval(-86_400) : day
            model.context = TrainingFuelContext(
                movement: TrainingFuelReading(value: "415 kcal", sampleDate: sampleDate,
                                              source: "Apple Health · active energy", checkedAt: day),
                workout: TrainingFuelReading(value: "Run · 40 min", sampleDate: sampleDate,
                                             source: "Apple Health · Watch", checkedAt: day.addingTimeInterval(90)))
        }
        model.longerDay = ["hard-confirmed", "unconfirmed"].contains(state)
        if ["unconfirmed", "manual", "save-failure", "hard-confirmed", "undo", "rollover"].contains(state) {
            model.beginReview()
        }
        if state == "manual" { model.draft = "125" }
        if ["hard-confirmed", "save-failure", "undo", "rollover"].contains(state) {
            model.draft = "271.5"
            await model.confirm()
        }
        switch state {
        case "undo":
            model.undo()
        case "rollover":
            // The clock crosses midnight and the refreshed new day is adopted:
            // the confirmed note belongs to the previous day and is gone.
            clock = nextDay
            model.synchronize(snapshot(for: nextDay))
        default:
            break
        }
        return (model, viewModel)
    }
}

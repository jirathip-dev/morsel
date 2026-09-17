import SwiftUI
import XCTest
@testable import Morsel

@MainActor
final class HeroBeforeTests: XCTestCase {
    func testPinnedBasePastDayPaperAndNight() async throws {
        MorselFontCatalog.register()
        let past = try XCTUnwrap(MorselDate.date("2026-09-16T12:00:00Z"))
        let today = try XCTUnwrap(MorselDate.date("2026-09-17T12:00:00Z"))
        let goal = DashboardGoal(calorieTargetKcal: 3_000, proteinG: 180, carbsG: 350, fatG: 100, source: .computed)
        let item = MealItem(itemID: UUID(), name: "Repro meal", quantity: 1, unit: .serving,
                            caloriesKcal: 1_953, proteinG: 124, carbsG: 162, fatG: 80,
                            fiberG: nil, sugarG: nil, confidence: nil, notes: "Synthetic owner-total reproduction")
        let meal = MealRecord(mealLogID: UUID(), mealType: .lunch, eatenAt: past, source: .manual, items: [item])
        let snapshot = DashboardSnapshot(date: DashboardMath.startOfLocalDay(past), meals: [meal], goal: goal)
        let model = DashboardViewModel(repository: MockDashboardRepository(snapshot: snapshot),
                                       userID: UUID(), dateProvider: { today })
        model.selectDate(past)
        await model.load()
        let fuel = TrainingFuelModel(now: { today })
        fuel.synchronize(DashboardSnapshot(date: today, meals: [], goal: goal))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; window.rootViewController = nil }
        for (theme, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = UIHostingController(rootView:
                TodayView(viewModel: model, showSettings: {}, addMeal: {})
                    .environmentObject(fuel).environment(\.trainingFuelHosted, true)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .preferredColorScheme(scheme))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(600))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let text = try WeightDeltaRendering.recognizedText(image)
            XCTAssertTrue(text.contains("1,953"))
            let attachment = XCTAttachment(image: image)
            attachment.name = "286-before-\(theme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("ISSUE286-BEFORE \(theme): \(text.replacingOccurrences(of: "\n", with: " | "))")
        }
    }
}

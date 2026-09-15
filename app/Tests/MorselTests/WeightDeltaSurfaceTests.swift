import SwiftUI
import UIKit
import Vision
import XCTest
@testable import Morsel

/// Base-compatible: mounts the shipped History page, not a replacement chart.
@MainActor
final class WeightDeltaSurfaceTests: XCTestCase {
    func testHistoryPaintsUnavailableComparisonAndMissingLogKey() throws {
        let today = DashboardMath.startOfLocalDay(Date())
        let calendar = Calendar.autoupdatingCurrent
        let days = (-6...0).map { offset in
            HistoryDay(date: calendar.date(byAdding: .day, value: offset, to: today) ?? today,
                       eatenKcal: offset == -2 ? 0 : 1_500, logged: offset != -2)
        }
        let points = days.map { WeightTrendPoint(date: $0.date, kilograms: 62) }
        let goal = DashboardGoal(calorieTargetKcal: 2_100, proteinG: 100, carbsG: 250, fatG: 70, source: .manual)
        let repository = MockDashboardRepository(snapshot: DashboardSnapshot(date: today, meals: [], goal: goal))
        repository.seed(history: HistoryOverview(days: days, goal: goal, weightTrend: points))
        let image = try WeightDeltaRendering.render(HistoryView(repository: repository, userID: UUID()),
                                                    size: CGSize(width: 393, height: 2_400))
        let text = try WeightDeltaRendering.recognizedText(image).lowercased()
        print("ISSUE165-PAINT \(text)")
        XCTAssertTrue(text.contains("weight trend"), "control: the actual chart must be inside the captured page")
        XCTAssertTrue(text.contains("food target unavailable"), "the chart must not borrow the one current goal")
        XCTAssertTrue(text.contains("no food log"), "the chart needs an explicit missing-log key, not zero bars")
        XCTAssertTrue(text.contains("eaten") && text.contains("food target"), "the comparison band must be visible")
    }
}

@MainActor
enum WeightDeltaRendering {
    static func render<Content: View>(_ content: Content, size: CGSize,
                                      scheme: ColorScheme = .light) throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        let host = UIHostingController(rootView: content.preferredColorScheme(scheme))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    static func recognizedText(_ image: UIImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

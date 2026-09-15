import SwiftUI
import UIKit
import XCTest
@testable import Morsel

@MainActor
final class WeightDeltaCaptureTests: XCTestCase {
    func testNonzeroBarsActuallyPaintAboveAndBelowZero() throws {
        let above = try chartPNG(eaten: 2_500)
        XCTAssertEqual(above, try chartPNG(eaten: 2_500), "control: repeat renders must be deterministic")
        XCTAssertNotEqual(above, try chartPNG(eaten: 1_500),
                          "opposite signed bars must paint differently; receipt text is deliberately excluded")
    }

    private func chartPNG(eaten: Double) throws -> Data {
        let today = Date(timeIntervalSince1970: 1_789_344_000)
        let day = WeightDeltaDay(date: today, logged: true, eatenKcal: eaten,
                                 foodTargetKcal: 2_000, targetSource: "Illustrative dated target")
        let timeline = WeightDeltaTimeline(days: [day], points: [], today: today)
        let renderer = ImageRenderer(content: WeightDeltaBand(timeline: timeline, points: [], today: today)
            .chart.frame(width: 320, height: 120).background(Color.morselBackground))
        return try XCTUnwrap(renderer.uiImage?.pngData())
    }

    func testPaperAndNightSimulatorCharts() throws {
        let directory = URL(fileURLWithPath: "/tmp/morsel-165-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            for illustrative in [false, true] {
                let fixture = try fixture(illustrative: illustrative)
                let label = illustrative ? "illustrative" : "payload"
                let content = VStack(alignment: .leading, spacing: 16) {
                    Text("SIMULATOR · FICTIONAL RECORDS")
                        .font(Font.morselMono(size: 10))
                    Text(illustrative ? "Illustrative dated targets · not API data"
                         : "Current payload · no dated targets")
                        .font(.morselFootnote)
                    Text("History").font(Font.morselHand(size: 32))
                    V1WeightTrendView(points: fixture.points, delta: -0.3, isThirtyDay: false,
                                      today: fixture.today, foodDays: fixture.days)
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .foregroundStyle(Color.morselInk)
                .background(Color.morselBackground)
                let image = try WeightDeltaRendering.render(content, size: CGSize(width: 393, height: 852),
                                                            scheme: scheme)
                let data = try XCTUnwrap(image.pngData())
                let url = directory.appendingPathComponent("\(label)-\(name).png")
                try data.write(to: url)
                let text = try WeightDeltaRendering.recognizedText(image).lowercased()
                XCTAssertTrue(text.contains("food target unavailable"), "missing-target legend must be visible")
                XCTAssertTrue(text.contains("no food log"), "missing-log legend must be visible")
                XCTAssertTrue(text.contains("partial day"), "today's receipt must be explicitly partial")
                XCTAssertTrue(text.contains("explain weight changes"), "the non-causal disclaimer must not truncate")
                XCTAssertEqual(image.size, CGSize(width: 393, height: 852))
                print("ISSUE165-CAPTURE \(url.path) points=393x852 scale=\(image.scale)")
            }
        }
    }

    private struct Fixture {
        let days: [WeightDeltaDay]
        let points: [WeightTrendPoint]
        let today: Date
    }

    private func fixture(illustrative: Bool) throws -> Fixture {
        let calendar = Calendar.autoupdatingCurrent
        let end = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_789_344_000))
        let dates = try (-6...0).map { try XCTUnwrap(calendar.date(byAdding: .day, value: $0, to: end)) }
        let eaten: [Double] = [1_750, 2_200, 1_850, 0, 1_900, 2_000, 1_500]
        let days = dates.enumerated().map { index, date in
            WeightDeltaDay(date: date, logged: index != 3, eatenKcal: eaten[index],
                           foodTargetKcal: illustrative && index != 2 ? 2_000 : nil,
                           targetSource: illustrative && index != 2 ? "Illustrative dated target · fixture only" : nil)
        }
        let points = [0, 2, 3, 5, 6].map { index in
            WeightTrendPoint(date: dates[index], kilograms: 62.5 - Double(index) * 0.05)
        }
        return Fixture(days: days, points: points, today: end)
    }
}

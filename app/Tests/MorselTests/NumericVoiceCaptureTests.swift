import SwiftUI
import UIKit
import Vision
import XCTest
@testable import Morsel

/// Real production views in a scene-backed simulator window, never a replica.
/// Opt-in keeps the capture matrix out of ordinary regression runs.
@MainActor
final class NumericVoiceCaptureTests: XCTestCase {
    override func tearDown() async throws { try await Task.sleep(for: .milliseconds(500)) }

    func testApprovedSurfacesInPaperAndNight() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/morsel-263-capture.enabled") else {
            throw XCTSkip("Opt-in numeric voice evidence matrix")
        }
        MorselFontCatalog.register()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        for (theme, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            let fixture = TrainingDayFixture("usual")
            await fixture.prepare()
            defer { fixture.model.cancel() }
            try await capture(TodayView(viewModel: fixture.viewModel, showSettings: {}, addMeal: {})
                .environmentObject(fixture.model).environment(\.trainingFuelHosted, true),
                window: window, theme: theme, scheme: scheme, name: "today", scroll: true)
            try await captureHistory(window: window, theme: theme, scheme: scheme, fixture: fixture)
            try await captureForms(window: window, theme: theme, scheme: scheme, fixture: fixture)
            await fixture.finish()
        }
    }

    private func captureHistory(window: UIWindow, theme: String, scheme: ColorScheme,
                                fixture: TrainingDayFixture) async throws {
        let snapshot = try XCTUnwrap(fixture.repository.snapshot)
        let repository = MockDashboardRepository(snapshot: snapshot)
        let start = Calendar.autoupdatingCurrent.startOfDay(for: fixture.clock)
        let days = (0..<7).reversed().map { offset in
            HistoryDay(date: start.addingTimeInterval(Double(-offset) * 86_400),
                       eatenKcal: 1_800 + Double(offset) * 100, logged: true)
        }
        repository.seed(history: HistoryOverview(days: days, goal: snapshot.goal))
        let model = HistoryViewModel(repository: repository, userID: UUID(), dateProvider: { fixture.clock })
        await model.load()
        let ledger = JournalPage(date: fixture.clock) {
            VStack(alignment: .leading, spacing: 16) {
                HistorySummaryStrip(viewModel: model)
                ForEach(days) { day in HistoryBarRow(viewModel: model, day: day) }
            }
        }
        try await capture(ledger, window: window, theme: theme, scheme: scheme, name: "history-ledger-gauge")
        await model.select(try XCTUnwrap(days.last))
        try await capture(JournalPage(date: fixture.clock) { DayDrillDown(viewModel: model) },
                          window: window, theme: theme, scheme: scheme, name: "day-drill-down", scroll: true)
        let calendar = JournalCalendarModel(repository: repository, userID: UUID(), today: fixture.clock,
                                             calendar: Calendar(identifier: .gregorian))
        await calendar.load()
        XCTAssertTrue(calendar.hasIndex)
        try await capture(JournalPage(date: fixture.clock) {
            JournalCalendarView(model: calendar, selectedDate: fixture.clock, openDay: { _ in })
        }, window: window, theme: theme, scheme: scheme, name: "calendar", scroll: true)
        let points = [WeightTrendPoint(date: days[0].date, kilograms: 80),
                      WeightTrendPoint(date: start, kilograms: 79.5)]
        let food = days.map { WeightDeltaDay(date: $0.date, logged: true, eatenKcal: $0.eatenKcal,
                                             foodTargetKcal: 2_126, targetSource: "Fictional dated target") }
        try await capture(JournalPage(date: fixture.clock) {
            V1WeightTrendView(points: points, delta: -0.5, isThirtyDay: false, today: start, foodDays: food)
        }, window: window, theme: theme, scheme: scheme, name: "weight-chart", scroll: true)
    }

    private func captureForms(window: UIWindow, theme: String, scheme: ColorScheme,
                              fixture: TrainingDayFixture) async throws {
        let snapshot = try XCTUnwrap(fixture.repository.snapshot)
        let repository = MockDashboardRepository(snapshot: snapshot)
        let userID = UUID()
        try await capture(GoalsView(repository: repository, userID: userID), window: window,
                          theme: theme, scheme: scheme, name: "goals-filled", scroll: true)
        repository.seedStoredGoal(StoredDashboardGoal(calorieTargetKcal: -1, proteinG: -2,
                                                      carbsG: -3, fatG: -4, source: .manual))
        try await capture(GoalsView(repository: repository, userID: userID), window: window,
                          theme: theme, scheme: scheme, name: "goals-invalid", scroll: true)
        let menus = MenuLibraryModel(repository: repository, userID: userID)
        try await capture(AddMealView(viewModel: fixture.viewModel, onClose: {}, menuLibrary: menus,
                                      onOpenMenus: {}, targetDate: fixture.clock), window: window,
                          theme: theme, scheme: scheme, name: "meal-capture", scroll: true)
        let item = try XCTUnwrap(snapshot.meals.first?.items.first)
        try await capture(MealItemEditSheet(item: item, onSave: { _ in false })
            .environmentObject(fixture.viewModel), window: window, theme: theme, scheme: scheme,
                          name: "meal-edit", scroll: true)
        let photoImage = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
        let photo = FoodImageUpload(data: try XCTUnwrap(photoImage.jpegData(compressionQuality: 0.8)),
                                    mimeType: "image/jpeg")
        try await capture(JournalPage(date: fixture.clock) {
            AddMealPhotoSection(pickerItem: .constant(nil), photo: .constant(photo), message: .constant(nil),
                                isSubmitting: false, isProcessingPhoto: .constant(false))
        }, window: window, theme: theme, scheme: scheme, name: "photo-metadata")
        try await capture(MenuEditorSheet(title: "New menu", model: menus, onSaved: {}), window: window,
                          theme: theme, scheme: scheme, name: "menu-editor", scroll: true)
    }

    private func capture<Content: View>(_ view: Content, window: UIWindow, theme: String, scheme: ColorScheme,
                                        name: String, scroll: Bool = false) async throws {
        window.rootViewController = UIHostingController(rootView: view.preferredColorScheme(scheme)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        try attach(window, name: "263-b-\(theme)-\(name)")
        if scroll, let scroller = scrollView(window) {
            let end = max(0, scroller.contentSize.height - scroller.bounds.height
                          + scroller.adjustedContentInset.bottom)
            if end > 1 {
                scroller.setContentOffset(CGPoint(x: 0, y: end), animated: false)
                try await Task.sleep(for: .milliseconds(150))
                try attach(window, name: "263-b-\(theme)-\(name)-bottom")
            }
        }
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(100))
    }

    private func attach(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
        XCTAssertFalse(words.isEmpty, "Capture must paint real content")
        print("NUMERIC_SURFACE \(name) points=\(image.size) scale=\(image.scale) OCR=\(words)")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollView(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView($0) }.first
    }
}

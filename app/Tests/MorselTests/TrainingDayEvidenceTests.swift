import SwiftUI
import XCTest
@testable import Morsel

/// Real production views, mounted in the native app test process. All data is fictional;
/// no HealthKit, server or account operations. Attachments are the authoritative captures.
@MainActor
final class TrainingDayEvidenceTests: XCTestCase {
    override func tearDown() async throws { try await Task.sleep(for: .milliseconds(500)) }

    func testAllThirtyStatesInPaperAndNight() async throws {
        MorselFontCatalog.register()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer { window.isHidden = true; window.rootViewController = nil }
        var captures = 0
        for (theme, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            for state in TrainingDayFixture.states {
                let fixture = TrainingDayFixture(state)
                await fixture.prepare()
                let sheet = !TrainingDayFixture.pages.contains(state)
                let page = AnyView(VStack(spacing: 0) {
                    TodayView(viewModel: fixture.viewModel, showSettings: {}, addMeal: {})
                    JournalTabBar(pager: JournalPagerModel())
                }.environmentObject(fixture.model).environment(\.trainingFuelHosted, true))
                let content = sheet ? AnyView(TrainingFuelEditor(model: fixture.model)) : page
                window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                window.rootViewController = UIHostingController(rootView: content.preferredColorScheme(scheme))
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(300))
                window.layoutIfNeeded()
                let name = "263-a-\(theme)-\(state)"
                capture(window, name: name)
                captures += 1
                if sheet {
                    let scroll = try XCTUnwrap(scrollView(window))
                    let middle = max(0, min(380, scroll.contentSize.height - scroll.bounds.height))
                    scroll.setContentOffset(CGPoint(x: 0, y: middle), animated: false)
                    try await Task.sleep(for: .milliseconds(100))
                    capture(window, name: name + "-readings")
                    scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)),
                                            animated: false)
                    try await Task.sleep(for: .milliseconds(100))
                    capture(window, name: name + "-about")
                    captures += 2
                }
                window.rootViewController = nil
                await fixture.finish()
            }
        }
        XCTAssertEqual(captures, 140)
    }

    func testRowPaintDistinguishesConfirmationAndUndoRestoresUsual() async throws {
        MorselFontCatalog.register()
        let fixture = TrainingDayFixture("usual")
        await fixture.prepare()
        let model = fixture.model
        func render() throws -> Data {
            let renderer = ImageRenderer(content: TrainingFuelSection(model: model)
                .frame(width: 300).padding(8).background(Color.morselBackground))
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        let usual = try render()
        XCTAssertEqual(usual, try render(), "determinism control")
        model.openSheet()
        model.draft = "300"
        XCTAssertEqual(usual, try render(), "typing cannot change Today")
        await model.confirm()
        XCTAssertNotEqual(usual, try render(), "confirmed amount reaches real row paint")
        model.undo()
        XCTAssertEqual(usual, try render(), "undo removes only the addition")
        await fixture.finish()
    }

    private func capture(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
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

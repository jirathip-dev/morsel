import SwiftUI
import UIKit
import Vision
import XCTest
@testable import Morsel

@MainActor
final class GoalsRestoreRenderingTests: XCTestCase {
    func testRestoreAffordanceInPaperAndNightBeforeAndAfterSave() async throws {
        MorselFontCatalog.register()
        let account = UUID()
        for scheme in [ColorScheme.light, .dark] {
            GoalsRestoreTransport.reset()
            let repository = try GoalsRestoreTransport.repository(userID: account)
            let theme = scheme == .light ? "paper" : "night"
            let before = try await capture(repository: repository, account: account, scheme: scheme)
            let beforeText = try text(in: before)
            XCTAssertTrue(beforeText.contains("Restore previous manual goals"), beforeText)
            XCTAssertTrue(beforeText.contains("earlier manual numbers"), beforeText)
            attach(before, name: "164-\(theme)-before")
            let model = GoalsEditorViewModel(repository: repository, userID: account)
            await model.load()
            let saved = await model.restorePreviousManualGoals()
            XCTAssertTrue(saved)
            let after = try await capture(repository: repository, account: account, scheme: scheme)
            let afterText = try text(in: after)
            XCTAssertFalse(afterText.contains("Restore previous manual goals"), afterText)
            XCTAssertFalse(afterText.contains("earlier manual numbers"), afterText)
            XCTAssertTrue(afterText.contains("manual"), afterText)
            attach(after, name: "164-\(theme)-after")
        }
    }

    private func capture(
        repository: SupabaseDashboardRepository, account: UUID, scheme: ColorScheme
    ) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1100)
        window.overrideUserInterfaceStyle = scheme == .light ? .light : .dark
        window.rootViewController = UIHostingController(rootView:
            GoalsView(repository: repository, userID: account)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(scheme)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        // Yield the main actor for SwiftUI's real .task + controlled URLSession reads.
        try await Task.sleep(for: .milliseconds(800))
        window.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func text(in image: UIImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

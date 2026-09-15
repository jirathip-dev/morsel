import SwiftUI
import UIKit
import XCTest
@testable import Morsel

/// Real production row and detail/edit surfaces in the simulator's app window.
/// The optional host handshake lets capture.py take unmodified simctl screenshots;
/// ordinary XCTest runs still mount every fixture, assert, and attach the frames.
@MainActor
final class ArtworkIdentitySurfaceTests: XCTestCase {
    private let handshake = URL(fileURLWithPath: "/tmp/m241-capture")

    func testRowAndDetailSurfacesInPaperAndNight() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let account = try XCTUnwrap(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let repository = MockDashboardRepository()
        let photoURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "coffee-photo", withExtension: "png"))
        let photo = FoodImageUpload(data: try Data(contentsOf: photoURL), mimeType: "image/png")
        _ = try repository.uploadImage(userID: account, path: ArtworkIdentityFixture.photoPath, upload: photo)
        let model = DashboardViewModel(repository: repository, userID: account)
        for (theme, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            for fixture in fixtures {
                let item = try ArtworkIdentityFixture.item(
                    name: fixture.name, identity: fixture.identity, photo: fixture.photo
                )
                try captureFixture(fixture, item: item, model: model, window: window, theme: theme)
            }
        }
    }

    private struct Fixture {
        let key: String
        let name: String
        var identity: String?
        var photo = false
    }

    private var fixtures: [Fixture] {
        let keys = ["coffee", "black-coffee", "thai-coffee", "americano", "descriptive-americano"]
        var result = zip(keys, ArtworkIdentityFixture.positives).map { Fixture(key: $0, name: $1) }
        result += zip(["coffee-cake", "mixed", "unknown"], ArtworkIdentityFixture.negatives)
            .map { Fixture(key: $0, name: $1) }
        result += [
            Fixture(key: "explicit", name: "Focaccia bread", identity: "coffee"),
            Fixture(key: "unsupported", name: "Americano", identity: "future-study"),
            Fixture(key: "photo", name: "Coffee", identity: "coffee", photo: true)
        ]
        return result
    }

    private func captureFixture(
        _ fixture: Fixture, item: MealItem, model: DashboardViewModel,
        window: UIWindow, theme: String
    ) throws {
        let scheme: ColorScheme = theme == "night" ? .dark : .light
        let original = item
        let row = JournalPage(date: Date(timeIntervalSince1970: 1_783_200_000)) {
            VStack(alignment: .leading, spacing: 16) {
                JournalPageHeader(title: "Food log", leadingTitle: "Back", leadingAction: {})
                SectionHeading(title: "Lunch")
                MealItemRow(item: item, onEdit: { _ in })
            }
        }
        mount(row, in: window, scheme: scheme)
        try capture(window, name: "\(theme)-\(fixture.key)-row", fixture: fixture)
        mount(MealItemEditSheet(item: item, onSave: { _ in false }).environmentObject(model),
              in: window, scheme: scheme)
        try capture(window, name: "\(theme)-\(fixture.key)-detail-top", fixture: fixture)
        let scroll = try XCTUnwrap(scrollView(in: try XCTUnwrap(window.rootViewController?.view)))
        let bottom = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        settle()
        try capture(window, name: "\(theme)-\(fixture.key)-detail-art", fixture: fixture)
        XCTAssertEqual(item, original, "painting must not mutate names, nutrition, identity or photo reference")
        XCTAssertEqual(item.name, fixture.name)
        if fixture.photo {
            XCTAssertEqual(item.mealImage?.path, ArtworkIdentityFixture.photoPath)
        }
    }

    private func mount(_ view: some View, in window: UIWindow, scheme: ColorScheme) {
        window.rootViewController = UIHostingController(rootView: view.preferredColorScheme(scheme))
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        settle()
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func capture(_ window: UIWindow, name: String, fixture: Fixture) throws {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 10_000, "a real rendered surface is required")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard FileManager.default.fileExists(atPath: handshake.appendingPathComponent("enabled").path) else { return }
        let request: [String: String] = [
            "name": name, "food": fixture.name, "identity": fixture.identity ?? "<absent>",
            "photo": fixture.photo ? ArtworkIdentityFixture.photoPath : "<absent>"
        ]
        let requestURL = handshake.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject: request).write(to: requestURL, options: .atomic)
        let ack = handshake.appendingPathComponent(name + ".ack")
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: ack.path), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ack.path), "simctl screenshot acknowledgement: \(name)")
    }

}

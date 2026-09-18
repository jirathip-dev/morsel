import Supabase
import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #310 — shared fixtures for the restoring-shell witnesses: the restore
// attempt the test owns (a deliberately slow / failed token refresh), the
// mounted window, and the pixel probes the theme and no-tab-bar checks read.

/// One restore attempt the test owns. `restoreSession()` parks until the test
/// releases it, so the whole restoring window is observable, and it can answer
/// with a stored session, with no session, or with a thrown refresh failure.
final class DeferredRestoreAuth: SupabaseAuthenticating {
    private let lock = NSLock()
    private var calls = 0
    private var parked: [CheckedContinuation<AuthenticatedSession?, Error>] = []
    private var scripted: Result<AuthenticatedSession?, Error>?

    var restoreCalls: Int { locked { calls } }
    var isParked: Bool { locked { !parked.isEmpty } }

    func restoreSession() async throws -> AuthenticatedSession? {
        let scripted = locked { () -> Result<AuthenticatedSession?, Error>? in
            calls += 1
            return self.scripted
        }
        if let scripted {
            return try scripted.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            locked { parked.append(continuation) }
        }
    }

    /// Answers every parked attempt (and every later one) with `result`.
    func release(_ result: Result<AuthenticatedSession?, Error>) {
        let waiters = locked { () -> [CheckedContinuation<AuthenticatedSession?, Error>] in
            scripted = result
            let waiters = parked
            parked = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    func requestEmailOTP(email: String) async throws {}

    func verifyEmailOTP(email: String, code: String) async throws -> AuthenticatedSession {
        throw MorselError.invalidInput("This witness never verifies a code")
    }

    func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthenticatedSession {
        throw MorselError.invalidInput("This witness never signs in with Apple")
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Phone-sized mounts of the real shell surface, plus the settle/wait helpers
/// the async witnesses use (a synchronous pump can starve the mounted task).
@MainActor
enum RestoringShellMount {
    static let size = CGSize(width: 390, height: 844)

    static func window(_ root: some View, scheme: ColorScheme) throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView: root.preferredColorScheme(scheme))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    static func unmount(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    static func capture(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    static func settle(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Bounded wait that yields the main actor instead of blocking the run loop.
    static func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await settle(25)
        }
        return condition()
    }
}

/// One pixel's channels (the repo lint caps tuples at two members).
struct RGB: Equatable {
    let red: Int
    let green: Int
    let blue: Int

    var luminance: Double {
        (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
    }

    func close(to other: RGB, within tolerance: Int) -> Bool {
        abs(red - other.red) + abs(green - other.green) + abs(blue - other.blue) <= tolerance
    }
}

/// RGBA8 pixels of a capture, drawn through one fixed context so the probe does
/// not depend on the renderer's own bitmap layout. Row 0 is the TOP row — the
/// orientation is pinned by `testPixelProbeReadsTheTopRowFirst`.
struct PixelGrid {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        var buffer = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        guard drawn else { return nil }
        width = pixelWidth
        height = pixelHeight
        bytes = buffer
    }

    /// `row` counts from the TOP edge (the bitmap context stores rows top-down;
    /// the orientation is pinned by `testPixelProbeReadsTheTopRowFirst`).
    func pixel(column: Int, row: Int) -> RGB {
        let offset = (row * width + column) * 4
        return RGB(
            red: Int(bytes[offset]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset + 2])
        )
    }

    /// The most common colour in the rows `band` deep, sampled on a grid so
    /// sheet rules and grain specks cannot decide the answer.
    func dominantColor(fromBottom band: Int) -> RGB {
        var counts: [Int: Int] = [:]
        for row in stride(from: max(0, height - band), to: height, by: 3) {
            for column in stride(from: 0, to: width, by: 3) {
                counts[Self.bucket(pixel(column: column, row: row)), default: 0] += 1
            }
        }
        guard let common = counts.max(by: { $0.value < $1.value })?.key else {
            return RGB(red: 0, green: 0, blue: 0)
        }
        return RGB(red: (common / 4_096) * 4, green: ((common / 64) % 64) * 4, blue: (common % 64) * 4)
    }

    /// Pixels in the bottom band that differ STRONGLY from the theme ground —
    /// the tab bar's words sit there; sheet rules and grain do not. The control
    /// test proves the oracle bites on a real bar.
    func contrastingPixelCount(fromBottom band: Int, ground: RGB, margin: Double = 0.25) -> Int {
        let groundLuminance = ground.luminance
        var count = 0
        for row in max(0, height - band)..<height {
            count += (0..<width).filter { column in
                abs(pixel(column: column, row: row).luminance - groundLuminance) > margin
            }.count
        }
        return count
    }

    private static func bucket(_ pixel: RGB) -> Int {
        (pixel.red / 4) * 4_096 + (pixel.green / 4) * 64 + pixel.blue / 4
    }
}

/// Fixtures for the three cold-launch cases: the stored-session dashboard reads
/// the shared stub transport (no network, no production data).
@MainActor
enum RestoringShellFixture {
    static let endpoint = "https://mcp.example.test/mcp"

    static func session(userID: UUID) -> AuthenticatedSession {
        AuthenticatedSession(userID: userID, email: "witness@example.test")
    }

    /// The production client over the shared stub transport, seeded with a real
    /// session value so the shell's reads answer with no network round trip.
    static func stubClient(userID: UUID) throws -> SupabaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        configuration.urlCache = nil
        return SupabaseClient(
            supabaseURL: try XCTUnwrap(URL(string: "https://restoring-shell.supabase.test")),
            supabaseKey: "stub-anon-key",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: StubSessionStorage(userID: userID, expiresAt: Date().addingTimeInterval(3_600)),
                    storageKey: "sb-stub-auth-token", autoRefreshToken: false
                ),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
    }

    /// One lunch with one item stamped at the running test's own day, so the
    /// dashboard case renders a populated journal rather than an empty page.
    static func seedTodaysDay() {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let mealID = "31313131-3131-4131-8131-313131313131"
        let itemID = "32323232-3232-4232-8232-323232323232"
        StubTransport.respond("meal_logs", .init(body: """
        [{"id":"\(mealID)","eaten_at":"\(stamp.string(from: Date()))","meal_type":"lunch",\
        "source":"manual","image_path":null}]
        """))
        StubTransport.respond("meal_items", .init(body: """
        [{"id":"\(itemID)","meal_log_id":"\(mealID)","name":"jasmine rice","quantity":1.5,\
        "unit":"serving","calories_kcal":300,"protein_g":6,"confidence":0.9}]
        """))
    }
}

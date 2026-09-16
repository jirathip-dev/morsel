import SwiftUI
import XCTest
@testable import Morsel

/// Issue #214: measure real styled Buttons, independently of the style's constants.
/// The external negative padding reserves the old visual footprint, not the target.
@MainActor
final class SharedButtonTargetTests: JournalRenderingTestCase {
    private struct Control {
        let name: String
        let label: String
        let style: String

        var button: AnyView {
            switch style {
            case "primary": return AnyView(Button(label) {}.buttonStyle(MorselPrimaryButtonStyle()))
            case "ghost": return AnyView(Button(label) {}.buttonStyle(MorselGhostButtonStyle()))
            default: return AnyView(Button(label) {}.buttonStyle(MorselDestructiveButtonStyle()))
            }
        }

        var legacy: some View {
            Button(label) {}.buttonStyle(LegacySharedButtonStyle(kind: style))
        }
    }

    private var controls: [Control] {
        [
            Control(name: "Auth email", label: "Send email code", style: "primary"),
            Control(name: "Auth verification", label: "Verify code", style: "primary"),
            Control(name: "Goals save", label: "Use these goals", style: "primary"),
            Control(name: "Goals saved", label: "Goals saved ✓", style: "primary"),
            Control(name: "Connector setup", label: "Continue to connector setup", style: "primary"),
            Control(name: "Copy setup prompt", label: "Copy setup prompt", style: "primary"),
            Control(name: "Copied setup prompt", label: "Copied ✓", style: "primary"),
            Control(name: "First log", label: "Continue to first log", style: "ghost"),
            Control(name: "Coach", label: "Continue", style: "primary"),
            Control(name: "Confirm connection", label: "I'm connected", style: "primary"),
            Control(name: "Open today", label: "Open today's log", style: "primary"),
            Control(name: "Today error", label: "Try again", style: "ghost"),
            Control(name: "History error", label: "Try again", style: "ghost"),
            Control(name: "Day read retry", label: "Try again", style: "ghost"),
            Control(name: "Cancel deletion", label: "Cancel", style: "ghost")
        ] + MealType.allCases.map {
            Control(name: "Delete \($0.title)", label: "Delete \($0.title)", style: "destructive")
        }
    }

    func testEverySharedActionMeasuresAtLeast44Points() {
        MorselFontCatalog.register()
        for category in [ContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            for control in controls {
                let size = fittedSize(of: control.button.environment(\.sizeCategory, category))
                print("ISSUE214-TARGET \(control.name) \(category) width=\(size.width) height=\(size.height)")
                XCTAssertGreaterThanOrEqual(size.height, 44, "\(control.name) interactive height")
                XCTAssertGreaterThanOrEqual(size.width, 44, "\(control.name) interactive width")
            }
        }
    }

    func testPaintAndSurroundingLayoutMatchTheOriginal40PointStyles() throws {
        MorselFontCatalog.register()
        for scheme in [ColorScheme.light, .dark] {
            for category in [ContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                for control in controls {
                    let fixed = surroundings(control.button.padding(.vertical, -2))
                        .environment(\.sizeCategory, category)
                    let original = surroundings(control.legacy).environment(\.sizeCategory, category)
                    let fixedSize = fittedSize(of: fixed)
                    let originalSize = fittedSize(of: original)
                    XCTAssertEqual(fixedSize, originalSize, "\(control.name) surrounding layout")
                    let canvas = CGSize(width: 390, height: 240)
                    let actual = try XCTUnwrap(render(fixed, size: canvas, scheme: scheme))
                    let expected = try XCTUnwrap(render(original, size: canvas, scheme: scheme))
                    let repeated = try XCTUnwrap(render(original, size: canvas, scheme: scheme))
                    XCTAssertEqual(try pixels(expected), try pixels(repeated), "deterministic render control")
                    let difference = try pixelDifference(actual, expected)
                    print("ISSUE214-VISUAL \(control.name) \(scheme) \(category) "
                          + "height=\(fixedSize.height) maxPixelDiff=\(difference.max)")
                    XCTAssertEqual(difference.max, 0, "\(control.name) artwork, glyphs and neighbours must not move")
                }
            }
        }
    }

    func testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Morsel")
        let pattern = #"\.buttonStyle\(Morsel(?:Primary|Ghost|Destructive)ButtonStyle\(\)\)"#
        let expression = try NSRegularExpression(pattern: pattern)
        var count = 0
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try XCTUnwrap(Range(match.range, in: source))
                let following = source[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertTrue(following.hasPrefix(".padding(.vertical, -2)"),
                              "\(file.lastPathComponent): compensate outside the Button, never clip its 44pt target")
                count += 1
            }
        }
        XCTAssertEqual(count, 13, "update the current action inventory when adding or removing a call site")
    }

    private func surroundings(_ button: some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before").font(.morselBody)
            button
            Text("After 123").font(.morselData)
        }
        .padding(20)
        .foregroundStyle(Color.morselInk)
        .background(Color.morselBackground)
    }
}

/// Frozen pre-#214 style for pixel/layout comparison only; never the target oracle.
private struct LegacySharedButtonStyle: ButtonStyle {
    let kind: String

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.morselBodyStrong)
            .foregroundStyle(foreground)
            .frame(minHeight: 40)
            .padding(.horizontal, 14)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }

    private var foreground: Color {
        switch kind {
        case "primary": return .morselLabelOnAccent
        case "ghost": return .morselInkTwo
        default: return .morselBackground
        }
    }

    private var background: Color {
        switch kind {
        case "primary": return .morselAccent
        case "ghost": return .morselSurfaceTwo
        default: return .morselOver
        }
    }
}

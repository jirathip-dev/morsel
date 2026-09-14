import SwiftUI
import UIKit
import XCTest
@testable import Morsel

// Issue #229 — shared render/measure helpers for the Variant A parity tests.
// The bundle cannot read SwiftUI accessibility elements back (#177) and cannot
// synthesize touches, so these tests measure real layout and compare real
// painted pixels against the bundled approved exports.
@MainActor
class JournalRenderingTestCase: XCTestCase {
    static let phone = CGSize(width: 390, height: 844)
    /// The design's `.row img` placement.
    static let artworkPoints: CGFloat = 56

    func render(
        _ view: some View,
        size: CGSize = CGSize(width: 56, height: 56),
        scheme: ColorScheme = .light
    ) -> UIImage? {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
                .background(Color.white)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 1
        return renderer.uiImage
    }

    func render(font: UIFont, text: String, size: CGFloat, width: CGFloat, height: CGFloat) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            (text as NSString).draw(
                at: CGPoint(x: 2, y: 2), withAttributes: [.font: font, .foregroundColor: UIColor.black]
            )
        }
    }

    /// Draws a bundled export at `points` (scale 1) so a render can be
    /// compared with what the same export produces inside a SwiftUI view.
    func draw(_ image: UIImage, at points: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: points, height: points), format: format)
        return renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: points, height: points))
            image.draw(in: CGRect(x: 0, y: 0, width: points, height: points))
        }
    }

    func fittedSize(of view: some View) -> CGSize {
        let host = UIHostingController(rootView: AnyView(view))
        host.view.frame = CGRect(origin: .zero, size: Self.phone)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: Self.phone)
    }

    func pixels(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var buffer = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &buffer, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return buffer
    }

    func pixelDifference(_ lhs: UIImage, _ rhs: UIImage) throws -> (mean: Double, max: Int) {
        let first = try pixels(lhs)
        let second = try pixels(rhs)
        XCTAssertEqual(first.count, second.count, "the compared renders must share their size")
        var total = 0
        var peak = 0
        for index in stride(from: 0, to: min(first.count, second.count), by: 4) {
            for channel in 0..<3 {
                let diff = abs(Int(first[index + channel]) - Int(second[index + channel]))
                total += diff
                peak = max(peak, diff)
            }
        }
        let samples = max(1, (min(first.count, second.count) / 4) * 3)
        return (Double(total) / Double(samples), peak)
    }

    func assertPixelsDiffer(_ lhs: UIImage, _ rhs: UIImage, _ message: String) throws {
        let diff = try pixelDifference(lhs, rhs)
        print("ISSUE229-MEASURE \(message) meanDiff=\(diff.mean)")
        XCTAssertGreaterThan(diff.mean, 0.5, message)
    }

    func assertPixelsEqual(_ lhs: UIImage, _ rhs: UIImage, _ message: String) throws {
        let diff = try pixelDifference(lhs, rhs)
        XCTAssertLessThan(diff.mean, 0.5, message)
    }

    /// The painted (non-white) bounding box of a rendered study.
    func inkBounds(_ image: UIImage) -> CGRect {
        guard let buffer = try? pixels(image), let cgImage = image.cgImage else { return .zero }
        let width = cgImage.width
        let height = cgImage.height
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for column in 0..<width {
            for row in 0..<height {
                let index = (row * width + column) * 4
                if buffer[index] < 240 || buffer[index + 1] < 240 || buffer[index + 2] < 240 {
                    minX = min(minX, column)
                    minY = min(minY, row)
                    maxX = max(maxX, column)
                    maxY = max(maxY, row)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func nonWhitePixels(_ image: UIImage) -> Int {
        guard let buffer = try? pixels(image) else { return 0 }
        var count = 0
        for index in stride(from: 0, to: buffer.count, by: 4) where
            buffer[index] < 240 || buffer[index + 1] < 240 || buffer[index + 2] < 240 {
            count += 1
        }
        return count
    }
}

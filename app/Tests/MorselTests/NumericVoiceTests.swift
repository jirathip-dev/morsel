import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import Morsel

@MainActor
final class NumericVoiceTests: XCTestCase {
    func testSwiftUIRenderedDigitColumnsAtProductionSizes() throws {
        MorselFontCatalog.register()
        for size: CGFloat in [14, 22, 32] {
            for weight: CGFloat in [400, 500] {
                let registered = try XCTUnwrap(MorselFontCatalog.variableSerif(size: size, weight: weight))
                XCTAssertEqual(registered.familyName, "EB Garamond", "No substituted font in this proof")
                let variation = CTFontCopyVariation(registered as CTFont) as? [NSNumber: NSNumber]
                XCTAssertEqual(variation?[MorselFontCatalog.weightAxisKey]?.doubleValue ?? 400, Double(weight))
                for (theme, scheme) in [("paper", ColorScheme.light), ("night", ColorScheme.dark)] {
                    let tabular = Font.morselNumber(size: size, weight: weight)
                    let proportional = proportionalFont(size: size, base: registered)
                    for length in 1...5 {
                        let columns = try markerColumns(font: tabular, length: length)
                        let control = try markerColumns(font: proportional, length: length)
                        XCTAssertLessThanOrEqual(spread(columns), 1, "Painted tabular column must align within 1 pixel")
                        XCTAssertGreaterThan(spread(control), 1, "Proportional negative control must discriminate")
                        print("NUMERIC_ALIGNMENT theme=\(theme) size=\(size) weight=\(weight) digits=\(length) "
                              + "tabular_px=\(columns) proportional_px=\(control)")
                    }
                    let view = HStack(alignment: .top, spacing: 24) {
                        ladder(font: tabular, label: "Tabular")
                        ladder(font: proportional, label: "Proportional control")
                    }.padding(20).background(Color.morselBackground)
                        .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, .large)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 3
                    let image = try XCTUnwrap(renderer.uiImage)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "263-alignment-\(theme)-\(Int(size))-\(Int(weight))"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    private func proportionalFont(size: CGFloat, base: UIFont) -> Font {
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [
            [UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
             UIFontDescriptor.FeatureKey.selector: kProportionalNumbersSelector],
            [UIFontDescriptor.FeatureKey.type: kNumberCaseType,
             UIFontDescriptor.FeatureKey.selector: kUpperCaseNumbersSelector]
        ]])
        return Font(UIFont(descriptor: descriptor, size: size))
    }

    private func ladder(font: Font, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.morselBody)
            ForEach(0..<10) { digit in
                HStack(spacing: 0) {
                    Text(String(repeating: String(digit), count: 5)).font(font)
                    Rectangle().fill(Color.red).frame(width: 2, height: 12)
                }.fixedSize()
            }
        }.foregroundStyle(Color.morselInk)
    }

    /// The marker is painted immediately AFTER a naturally laid-out SwiftUI Text.
    /// No fixed digit cells, CoreText advance measurements or inferred widths.
    private func markerColumns(font: Font, length: Int) throws -> [Int] {
        try (0..<10).map { digit in
            let view = HStack(spacing: 0) {
                Text(String(repeating: String(digit), count: length)).font(font).foregroundStyle(.black)
                Rectangle().fill(Color.red).frame(width: 2, height: 12)
            }.fixedSize().padding(4).background(Color.white).environment(\.dynamicTypeSize, .large)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
                                                 bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var redColumns: [Int] = []
            for column in 0..<image.width where (0..<image.height).contains(where: { row in
                let index = (row * image.width + column) * 4
                return bytes[index] > 200 && bytes[index + 1] < 80 && bytes[index + 2] < 80
            }) { redColumns.append(column) }
            return try XCTUnwrap(redColumns.first, "Marker must actually paint")
        }
    }

    private func spread(_ values: [Int]) -> Int { (values.max() ?? 0) - (values.min() ?? 0) }
}

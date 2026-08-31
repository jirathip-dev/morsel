import Foundation
import SwiftUI

private extension Color {
    init(paletteHex hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let rgb = UInt64(value, radix: 16) else {
            self.init(red: 0.164706, green: 0.149020, blue: 0.121569)
            return
        }
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }
}

// Approved V1 palette "Orange Hearth + Sage" (issue #32). Exact scalar
// contract; docs/DESIGN.md is normative.
extension Color {
    static let morselInk = Color(paletteHex: "#2A261F")
    static let morselInkTwo = Color(paletteHex: "#655A4B")
    static let morselInkThree = Color(paletteHex: "#756955")
    static let morselBackground = Color(paletteHex: "#FFF7E8")
    static let morselSurface = Color(paletteHex: "#FFFCF5")
    static let morselSurfaceTwo = Color(paletteHex: "#F2E9D9")
    static let morselLine = Color(paletteHex: "#E3D2BA")
    static let morselAccent = Color(paletteHex: "#E66A2C")
    static let morselAccentSoft = Color(paletteHex: "#FBE1C9")
    static let morselLeaf = Color(paletteHex: "#5E7E57")
    static let morselLeafSoft = Color(paletteHex: "#E1E9D7")
    static let morselForest = Color(paletteHex: "#2F654B")
    static let morselCoral = Color(paletteHex: "#B94738")
    static let morselMustard = Color(paletteHex: "#D6A62C")
    static let morselMustardDeep = Color(paletteHex: "#A5750B")
    static let morselReview = Color(paletteHex: "#7A3D2B")
    static let morselOver = Color(paletteHex: "#9C3A2F")

    // Semantic aliases over the V1 contract, kept for the existing call
    // sites: accent is the calorie anchor; review is the low-confidence
    // text; accentSoft is the warm review/action wash.
    static let morselEnergy = Color(paletteHex: "#E66A2C")
    static let morselEnergySoft = Color(paletteHex: "#FBE1C9")
    static let morselLow = Color(paletteHex: "#7A3D2B")

    // Measured-data gradient stops (approved TOKENS.md table) — documented
    // measured-data treatment, never scalar/background decoration.
    static let morselProtein = Color(paletteHex: "#B94738")
    static let morselProteinStart = Color(paletteHex: "#C9513D")
    static let morselProteinEnd = Color(paletteHex: "#A63A32")
    static let morselCarbs = Color(paletteHex: "#A5750B")
    static let morselCarbsStart = Color(paletteHex: "#B07A13")
    static let morselCarbsEnd = Color(paletteHex: "#875A02")
    static let morselFat = Color(paletteHex: "#5E7E57")
    static let morselFatStart = Color(paletteHex: "#6B8B60")
    static let morselFatEnd = Color(paletteHex: "#3F6745")
    static let morselGaugeStart = Color(paletteHex: "#6B8B60")
    static let morselGaugeEnd = Color(paletteHex: "#2F654B")
    static let morselCardEnd = Color(paletteHex: "#FFF5E5")
}

extension LinearGradient {
    static let morselProtein = LinearGradient(
        colors: [.morselProteinStart, .morselProteinEnd],
        startPoint: .trailing,
        endPoint: .leading
    )
    static let morselCarbs = LinearGradient(
        colors: [.morselCarbsStart, .morselCarbsEnd],
        startPoint: .trailing,
        endPoint: .leading
    )
    static let morselFat = LinearGradient(
        colors: [.morselFatStart, .morselFatEnd],
        startPoint: .trailing,
        endPoint: .leading
    )
    static let morselGauge = LinearGradient(
        colors: [.morselGaugeStart, .morselGaugeEnd],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )
    static let morselCard = LinearGradient(
        colors: [.morselSurface, .morselCardEnd],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension Font {
    static let morselDisplay = Font.custom("Nunito Sans", size: 22).weight(.heavy)
    static let morselTitle = Font.custom("Nunito Sans", size: 16).weight(.heavy)
    static let morselBody = Font.custom("Nunito Sans", size: 15)
    static let morselBodyStrong = Font.custom("Nunito Sans", size: 15).weight(.bold)
    static let morselLabel = Font.custom("Nunito Sans", size: 12).weight(.bold)
    static let morselData = Font.custom("IBM Plex Mono", size: 11).weight(.medium)
    static let morselGauge = Font.custom("Nunito Sans", size: 26).weight(.heavy)
}

struct MorselPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.morselBodyStrong)
            .foregroundStyle(Color.morselInk)
            .frame(minHeight: 40)
            .padding(.horizontal, 14)
            .background(Color.morselAccent, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct MorselGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.morselBodyStrong)
            .foregroundStyle(Color.morselInkTwo)
            .frame(minHeight: 40)
            .padding(.horizontal, 14)
            .background(Color.morselSurfaceTwo, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension View {
    func morselTag(foreground: Color, background: Color) -> some View {
        font(.morselData)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.morselLine, lineWidth: 1)
            }
    }

    func morselSectionLabel() -> some View {
        font(.morselLabel)
            .foregroundStyle(Color.morselInkThree)
            .textCase(.uppercase)
            .tracking(1)
    }
}

enum MorselFormat {
    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "—"
        }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    static func confidence(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "—"
        }
        return value.formatted(.number.precision(.fractionLength(2)))
    }

    static func portion(quantity: Double, unit: FoodUnit) -> String {
        "\(number(quantity)) \(unit.rawValue)"
    }

    static func macroLine(for item: MealItem) -> String {
        var values: [String] = []
        if let protein = item.proteinG {
            values.append("P\(number(protein))")
        }
        if let carbs = item.carbsG {
            values.append("C\(number(carbs))")
        }
        if let fat = item.fatG {
            values.append("F\(number(fat))")
        }
        return values.isEmpty ? "No macro data" : values.joined(separator: " ")
    }
}

import Foundation
import SwiftUI

private extension Color {
    init(paletteHex hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let rgb = UInt64(value, radix: 16) else {
            self.init(red: 0.125490, green: 0.137255, blue: 0.117647)
            return
        }
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }
}

extension Color {
    static let morselInk = Color(paletteHex: "#20231E")
    static let morselInkTwo = Color(paletteHex: "#666A60")
    static let morselInkThree = Color(paletteHex: "#9BA095")
    static let morselBackground = Color(paletteHex: "#FBFAF6")
    static let morselSurface = Color(paletteHex: "#FFFFFF")
    static let morselSurfaceTwo = Color(paletteHex: "#F3F1EA")
    static let morselLine = Color(paletteHex: "#E7E3D8")
    static let morselAccent = Color(paletteHex: "#F08A2E")
    static let morselAccentSoft = Color(paletteHex: "#F6E8D8")
    static let morselEnergy = Color(paletteHex: "#F08A2E")
    static let morselEnergySoft = Color(paletteHex: "#F6E8D8")
    static let morselOver = Color(paletteHex: "#C0483F")
    static let morselLow = Color(paletteHex: "#8A5514")
    static let morselProtein = Color(paletteHex: "#C0483F")
    static let morselCarbs = Color(paletteHex: "#F0A63C")
    static let morselFat = Color(paletteHex: "#D46A2E")

    static let morselProteinStart = Color(paletteHex: "#C0483F")
    static let morselCarbsStart = Color(paletteHex: "#FFC24B")
    static let morselFatStart = Color(paletteHex: "#F0A63C")
    static let morselUnderStart = Color(paletteHex: "#FFC24B")
    static let morselUnder = Color(paletteHex: "#F08A2E")
    static let morselOnStart = Color(paletteHex: "#F0A63C")
    static let morselOn = Color(paletteHex: "#D46A2E")
    static let morselOverStart = Color(paletteHex: "#F7A98C")
    static let morselOverEnd = Color(paletteHex: "#C0483F")
    static let morselCardEnd = Color(paletteHex: "#FBF9F2")
}

extension LinearGradient {
    static let morselProtein = LinearGradient(
        colors: [.morselProteinStart, .morselProtein],
        startPoint: .top,
        endPoint: .bottom
    )
    static let morselCarbs = LinearGradient(
        colors: [.morselCarbsStart, .morselCarbs],
        startPoint: .top,
        endPoint: .bottom
    )
    static let morselFat = LinearGradient(
        colors: [.morselFatStart, .morselFat],
        startPoint: .top,
        endPoint: .bottom
    )
    static let morselUnder = LinearGradient(
        colors: [.morselUnderStart, .morselUnder],
        startPoint: .top,
        endPoint: .bottom
    )
    static let morselOn = LinearGradient(
        colors: [.morselOnStart, .morselOn],
        startPoint: .top,
        endPoint: .bottom
    )
    static let morselOver = LinearGradient(
        colors: [.morselOverStart, .morselOverEnd],
        startPoint: .top,
        endPoint: .bottom
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
            .foregroundStyle(Color.morselSurface)
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

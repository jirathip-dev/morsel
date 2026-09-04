import CoreText
import Foundation
import SwiftUI
import UIKit

// MARK: - Palette table (single native token authority for issue #94 V1)

/// The V1 field-journal palette: approved "Orange Hearth + Sage" scalars
/// (issue #32) plus the single new line token `inkline` (#8B7355). Every
/// native token ships a Paper (light) and Night-ink (dark) resolved variant —
/// Night values are palette pigments resolved over the ink ground #2A261F per
/// the promoted design contract (docs/evidence/issue-90/tokens.md). This is a
/// data table so native XCTests can measure role distinctness and WCAG pairs
/// without rendering.
enum MorselPalette {
    typealias Pair = (paper: String, night: String)

    static let ink: Pair = ("#2A261F", "#FFF7E8")
    static let inkTwo: Pair = ("#655A4B", "#F2E9D9")
    static let inkThree: Pair = ("#756955", "#E3D2BA")
    static let background: Pair = ("#FFF7E8", "#2A261F")
    static let surface: Pair = ("#FFFCF5", "#373129")
    static let surfaceTwo: Pair = ("#F2E9D9", "#423B31")
    static let line: Pair = ("#E3D2BA", "#756955")
    static let accent: Pair = ("#E66A2C", "#E66A2C")
    static let accentSoft: Pair = ("#FBE1C9", "#7A3D2B")
    static let leaf: Pair = ("#5E7E57", "#E1E9D7")
    static let leafSoft: Pair = ("#E1E9D7", "#2F654B")
    static let forest: Pair = ("#2F654B", "#E1E9D7")
    static let coral: Pair = ("#B94738", "#FBE1C9")
    static let mustard: Pair = ("#D6A62C", "#D6A62C")
    static let mustardDeep: Pair = ("#A5750B", "#A5750B")
    static let review: Pair = ("#7A3D2B", "#FBE1C9")
    static let over: Pair = ("#9C3A2F", "#FFF7E8")
    /// Hand-ruled lines / engraved contours (never body text).
    static let inkline: Pair = ("#8B7355", "#9D917F")
    /// Ink label drawn on the accent identity surface stays the warm dark ink
    /// in BOTH themes (cream on orange would drop to ~3.05:1).
    static let labelOnAccent: Pair = ("#2A261F", "#2A261F")
    /// Wash pigments: Paper renders the pigment at ~0.92 over the page; Night
    /// uses the soft-family role pigments at full strength on charcoal.
    static let proteinWash: Pair = ("#BF5546", "#FBE1C9")
    static let carbsWash: Pair = ("#AC7F1D", "#D6A62C")
    static let fatWash: Pair = ("#6B8863", "#E1E9D7")
    static let todayWash: Pair = ("#E8753B", "#E66A2C")
    static let excessWash: Pair = ("#A4493E", "#9C3A2F")

    static let all: [String: Pair] = [
        "morselInk": ink, "morselInkTwo": inkTwo, "morselInkThree": inkThree,
        "morselBackground": background, "morselSurface": surface, "morselSurfaceTwo": surfaceTwo,
        "morselLine": line, "morselAccent": accent, "morselAccentSoft": accentSoft,
        "morselLeaf": leaf, "morselLeafSoft": leafSoft, "morselForest": forest,
        "morselCoral": coral, "morselMustard": mustard, "morselMustardDeep": mustardDeep,
        "morselReview": review, "morselOver": over
    ]
}

// MARK: - Dynamic native tokens

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

extension Color {
    /// V1 dual-theme token: resolves the Paper variant in Light appearance and
    /// the Night-ink variant in Dark appearance. `MorselAppearance.scheme(for:)`
    /// drives the root preference, so the whole app re-inks without call-site
    /// churn (DesignSystem.swift is the only hex authority for native).
    static func morselJournal(paper: String, night: String) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(morselHex: traits.userInterfaceStyle == .dark ? night : paper)
        })
    }
}

private extension UIColor {
    convenience init(morselHex hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        guard value.count == 6, Scanner(string: value).scanHexInt64(&rgb) else {
            self.init(red: 0.164706, green: 0.149020, blue: 0.121569, alpha: 1)
            return
        }
        self.init(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}

// Approved V1 palette — "Orange Hearth + Sage" (issue #32) with Night-ink
// roles (issue #90/#94). Exact dual-token contract; docs/DESIGN.md normative.
// Token declarations are single-line data for the hosted contract probes.
// swiftlint:disable line_length
extension Color {
    static let morselInk = Color.morselJournal(paper: MorselPalette.ink.paper, night: MorselPalette.ink.night)
    static let morselInkTwo = Color.morselJournal(paper: MorselPalette.inkTwo.paper, night: MorselPalette.inkTwo.night)
    static let morselInkThree = Color.morselJournal(paper: MorselPalette.inkThree.paper, night: MorselPalette.inkThree.night)
    static let morselBackground = Color.morselJournal(paper: MorselPalette.background.paper, night: MorselPalette.background.night)
    static let morselSurface = Color.morselJournal(paper: MorselPalette.surface.paper, night: MorselPalette.surface.night)
    static let morselSurfaceTwo = Color.morselJournal(paper: MorselPalette.surfaceTwo.paper, night: MorselPalette.surfaceTwo.night)
    static let morselLine = Color.morselJournal(paper: MorselPalette.line.paper, night: MorselPalette.line.night)
    static let morselAccent = Color.morselJournal(paper: MorselPalette.accent.paper, night: MorselPalette.accent.night)
    static let morselAccentSoft = Color.morselJournal(paper: MorselPalette.accentSoft.paper, night: MorselPalette.accentSoft.night)
    static let morselLeaf = Color.morselJournal(paper: MorselPalette.leaf.paper, night: MorselPalette.leaf.night)
    static let morselLeafSoft = Color.morselJournal(paper: MorselPalette.leafSoft.paper, night: MorselPalette.leafSoft.night)
    static let morselForest = Color.morselJournal(paper: MorselPalette.forest.paper, night: MorselPalette.forest.night)
    static let morselCoral = Color.morselJournal(paper: MorselPalette.coral.paper, night: MorselPalette.coral.night)
    static let morselMustard = Color.morselJournal(paper: MorselPalette.mustard.paper, night: MorselPalette.mustard.night)
    static let morselMustardDeep = Color.morselJournal(paper: MorselPalette.mustardDeep.paper, night: MorselPalette.mustardDeep.night)
    static let morselReview = Color.morselJournal(paper: MorselPalette.review.paper, night: MorselPalette.review.night)
    static let morselOver = Color.morselJournal(paper: MorselPalette.over.paper, night: MorselPalette.over.night)
    /// #94: hand-ruled ink lines / contours (ring guides, goal ticks, rules).
    static let morselInkLine = Color.morselJournal(paper: MorselPalette.inkline.paper, night: MorselPalette.inkline.night)
    /// Identity-surface label (accent buttons): warm dark ink in both themes.
    static let morselLabelOnAccent = Color.morselJournal(paper: MorselPalette.labelOnAccent.paper, night: MorselPalette.labelOnAccent.night)

    // V1 wash pigments (measured-data/chart treatment, never body text).
    static let morselProteinWash = Color.morselJournal(paper: MorselPalette.proteinWash.paper, night: MorselPalette.proteinWash.night)
    static let morselCarbsWash = Color.morselJournal(paper: MorselPalette.carbsWash.paper, night: MorselPalette.carbsWash.night)
    static let morselFatWash = Color.morselJournal(paper: MorselPalette.fatWash.paper, night: MorselPalette.fatWash.night)
    static let morselTodayWash = Color.morselJournal(paper: MorselPalette.todayWash.paper, night: MorselPalette.todayWash.night)
    static let morselExcessWash = Color.morselJournal(paper: MorselPalette.excessWash.paper, night: MorselPalette.excessWash.night)

    // Semantic aliases over the V1 contract, kept for the existing call
    // sites: accent is the calorie anchor; review is the low-confidence
    // text; accentSoft is the warm review/action wash.
    static let morselEnergy = Color.morselAccent
    static let morselEnergySoft = Color.morselAccentSoft
    static let morselLow = Color.morselReview

    // Measured-data gradient stops (approved TOKENS table) — documented
    // measured-data treatment, never scalar/background decoration.
    static let morselProtein = Color.morselCoral
    static let morselProteinStart = Color(paletteHex: "#C9513D")
    static let morselProteinEnd = Color(paletteHex: "#A63A32")
    static let morselCarbs = Color.morselMustardDeep
    static let morselCarbsStart = Color(paletteHex: "#B07A13")
    static let morselCarbsEnd = Color(paletteHex: "#875A02")
    static let morselFat = Color.morselLeaf
    static let morselFatStart = Color(paletteHex: "#6B8B60")
    static let morselFatEnd = Color(paletteHex: "#3F6745")
    static let morselGaugeStart = Color(paletteHex: "#6B8B60")
    static let morselGaugeEnd = Color.morselForest
    static let morselCardEnd = Color.morselJournal(paper: "#FFF5E5", night: "#423B31")
}
// swiftlint:enable line_length

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

// MARK: - V1 typography (issue #94)

/// Registers the bundled OFL fonts (Caveat, EB Garamond, IBM Plex Mono).
/// Called once at app launch (and by the capture harness); idempotent.
enum MorselFontCatalog {
    static let bundledFontFileNames = [
        "Caveat[wght]", "EBGaramond[wght]", "EBGaramond-Italic[wght]",
        "IBMPlexMono-Regular", "IBMPlexMono-Medium"
    ]

    static func register() {
        guard let bundleURL = Bundle.main.resourceURL else { return }
        for name in bundledFontFileNames {
            let url = bundleURL.appendingPathComponent("\(name).ttf")
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }
}

extension Font {
    /// Hand-lettered heading/annotation voice (Caveat).
    static func morselHand(size: CGFloat) -> Font { Font.custom("Caveat", size: size) }
    /// Serif body/label voice (EB Garamond).
    static func morselSerif(size: CGFloat) -> Font { Font.custom("EB Garamond", size: size) }
    /// Serif italic caption voice (EB Garamond Italic).
    static func morselSerifItalic(size: CGFloat) -> Font { Font.custom("EBGaramond-Italic", size: size) }
    /// Tabular figure voice (IBM Plex Mono).
    static func morselMono(size: CGFloat) -> Font { Font.custom("IBM Plex Mono", size: size) }
    /// Emphasized figures (IBM Plex Mono Medium).
    static func morselMonoMedium(size: CGFloat) -> Font { Font.custom("IBM Plex Mono Medium", size: size) }

    static let morselDisplay = Font.morselHand(size: 34)
    static let morselTitle = Font.morselSerif(size: 17).weight(.semibold)
    static let morselBody = Font.morselSerif(size: 15)
    static let morselBodyStrong = Font.morselSerif(size: 15).weight(.semibold)
    static let morselLabel = Font.morselSerif(size: 11).weight(.semibold)
    static let morselData = Font.morselMono(size: 11)
    static let morselDataMedium = Font.morselMonoMedium(size: 11)
    static let morselGauge = Font.morselMonoMedium(size: 30)
    static let morselHero = Font.morselMonoMedium(size: 32)
    static let morselFootnote = Font.morselSerifItalic(size: 12)
}

// MARK: - Native component primitives

struct MorselPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.morselBodyStrong)
            .foregroundStyle(Color.morselLabelOnAccent)
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

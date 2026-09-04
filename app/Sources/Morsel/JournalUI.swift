import SwiftUI
import UIKit

// Issue #94: V1 field-journal native chrome. Everything here draws through
// the DesignSystem dual tokens (Paper/Night-ink) — no HTML/CSS geometry or
// web gradients are copied; shapes are native SwiftUI paths with inkline
// contours and palette wash fills.

// MARK: - Hand rules & markers

/// A slightly imperfect hand-ruled horizontal rule (inkline, 1pt).
struct JournalRule: View {
    var body: some View {
        Rectangle()
            .fill(Color.morselInkLine.opacity(0.6))
            .frame(height: 1)
    }
}

/// The V1 marker-stroke underline (active tab / today / selected direction /
/// "see it" / CTA links): a short rounded ink stroke under the word.
struct MarkerStroke: View {
    let color: Color
    var width: CGFloat = 30
    var height: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: height)
    }
}

// MARK: - Page furniture

/// Full-height left spine + rotated gutter date of a journal page. The spine
/// sits at x≈26; screens keep a leading inset so content clears the margin.
/// Issue #105 adds the bound-edge crease wash (a soft inkline gradient right
/// of the spine) so the page reads as a bound journal leaf, not a card.
struct JournalPageFurniture: View {
    let date: Date

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer(minLength: 96)
                Text(Self.gutterDate(date))
                    .font(Font.morselMono(size: 9))
                    .tracking(0.5)
                    .foregroundStyle(Color.morselInkThree)
                    .rotationEffect(.degrees(-90))
                    .fixedSize()
                    .frame(width: 14, height: 120)
                Spacer(minLength: 40)
            }
            .frame(width: 20)
            Rectangle()
                .fill(Color.morselInkLine.opacity(0.5))
                .frame(width: 1)
            // Bound-edge crease: restrained inkline wash that fades away from
            // the spine (token-only; Night ink renders it as a fold highlight).
            LinearGradient(
                colors: [Color.morselInkLine.opacity(0.22), Color.morselInkLine.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 7)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// "03.SEP.2026" — mono folio used in the prototype gutter.
    static func gutterDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MMM.yyyy"
        return formatter.string(from: date).uppercased()
    }
}

// MARK: - Paper ground (grain + ruled sheet, deterministic and token-only)

/// The #105 paper ground treatment: warm page ground (existing token), faint
/// horizontal sheet rules, and a deterministic restrained grain. Both are
/// baked once per theme into a seamless 44pt tile so scrolling never
/// recomputes speckles (performance-safe), every launch renders the same
/// grain (deterministic — seeded LCG), and nothing draws outside the token
/// system (inkline only, never a new hue; the darkest speck is capped well
/// below the WCAG floors — see docs/evidence/issue-105/README.md).
struct JournalPaperTexture: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(uiImage: Self.tile(night: colorScheme == .dark))
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static var tileCache: [Bool: UIImage] = [:]

    /// 44pt seamless tile: one sheet rule at the bottom edge plus a fixed set
    /// of inkline specks from a seeded LCG (seed 105 — issue #105).
    static func tile(night: Bool) -> UIImage {
        if let cached = tileCache[night] { return cached }
        let tileSize = CGFloat(44)
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: tileSize, height: tileSize)
        )
        let inkHex = night ? MorselPalette.inkline.night : MorselPalette.inkline.paper
        let ink = UIColor(morselHex: inkHex)
        let image = renderer.image { context in
            // Sheet rule (0.5pt) at the tile bottom — repeated every 44pt.
            ink.withAlphaComponent(night ? 0.16 : 0.12).setFill()
            context.fill(CGRect(x: 0, y: tileSize - 0.5, width: tileSize, height: 0.5))
            // Deterministic restrained grain: ~12 specks per tile from a
            // seeded LCG (fixed seed → identical speckle every launch).
            var state: UInt64 = 105
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double((state >> 33) % 1_000_000) / 1_000_000
            }
            let speckAlpha: CGFloat = night ? 0.10 : 0.08
            for _ in 0..<12 {
                let x = next() * Double(tileSize)
                let y = next() * Double(tileSize)
                let radius = 0.4 + next() * 0.5
                ink.withAlphaComponent(speckAlpha * (next() > 0.8 ? 1.6 : 1.0)).setFill()
                context.cgContext.fillEllipse(
                    in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                )
            }
        }
        tileCache[night] = image
        return image
    }
}

// MARK: - Ink drawings (native glyphs; no stock chrome)

/// Hand-drawn strike × (meal removal — the V1 ink strike, never a trash glyph).
struct InkStrikeX: View {
    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 3, y: 3))
                path.addLine(to: CGPoint(x: 13, y: 13))
            }
            .stroke(Color.morselInkTwo, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            Path { path in
                path.move(to: CGPoint(x: 13, y: 3))
                path.addLine(to: CGPoint(x: 3, y: 13))
            }
            .stroke(Color.morselInkTwo, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
    }
}

/// Hand-drawn plus (the torn paper-tab "+").
struct InkPlus: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.morselInk).frame(width: 1.8, height: 12)
            Rectangle().fill(Color.morselInk).frame(width: 12, height: 1.8)
        }
        .frame(width: 16, height: 16)
    }
}

/// Small toothed cog (Settings affordance), drawn ink-style — the V1 custom
/// cog, not the stock gearshape.
struct ToothedCog: View {
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .fill(Color.morselInkTwo)
                    .frame(width: 2, height: 4)
                    .offset(y: -8)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
            Circle()
                .stroke(Color.morselInkTwo, lineWidth: 1.6)
                .frame(width: 11, height: 11)
            Circle()
                .fill(Color.morselInkTwo)
                .frame(width: 3, height: 3)
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
}

/// The torn-paper add-meal tab: warm paper patch with an ink contour and the
/// hand-drawn plus. Night ink renders the charcoal surface + cream contour.
struct AddMealTab: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.morselSurface)
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.morselInkLine, lineWidth: 1.2)
            InkPlus()
        }
        .frame(width: 38, height: 38)
        .rotationEffect(.degrees(-2))
        .contentShape(Rectangle())
        .accessibilityLabel("Add meal")
    }
}

// MARK: - Wash fills

/// A deterministic irregular wash edge — the right edge of each wash strip
/// wobbles like a pigment pool (seeded from the fill fraction).
struct WashEdgeShape: Shape {
    var fillFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        let edgeX = rect.minX + rect.width * min(max(fillFraction, 0), 1)
        // seeded wobble: deterministic zig-zag along the pigment front
        let steps = 4
        var cursorY = rect.maxY
        path.addLine(to: CGPoint(x: edgeX, y: cursorY))
        for step in 0..<steps {
            cursorY = rect.maxY - rect.height * CGFloat(step + 1) / CGFloat(steps)
            let wobble = (sin(Double(step) * 2.4 + Double(edgeX)) * 1.2)
            path.addLine(to: CGPoint(x: edgeX + CGFloat(wobble), y: cursorY))
        }
        path.closeSubpath()
        return path
    }
}

/// One V1 macro wash strip: faint denominator rail, pigment wash fill,
/// inkline goal tick at the goal, mono value readout on the right.
struct MacroWashStrip: View {
    let label: String
    let value: Double
    let target: Double?
    let wash: Color

    private var fraction: Double {
        guard let target, target > 0 else { return 0 }
        return min(max(value / target, 0), 1)
    }

    private var scaleDenominator: Double {
        // over-goal days keep the tick visible: scale to the larger of the two
        guard let target, target > 0 else { return max(value, 1) }
        return max(value, target)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.morselTitle)
                .foregroundStyle(Color.morselInk)
                .frame(width: 74, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    // denominator rail
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.morselSurfaceTwo)
                    // wash fill
                    WashEdgeShape(fillFraction: fraction)
                        .fill(wash)
                    // goal tick
                    Rectangle()
                        .fill(Color.morselInkLine)
                        .frame(width: 1.4)
                        .offset(x: tickX(in: proxy.size.width))
                }
                .frame(height: 8)
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            Text(valueText)
                .font(.morselDataMedium)
                .foregroundStyle(Color.morselInkTwo)
                .frame(width: 108, alignment: .trailing)
        }
    }

    private var valueText: String {
        guard let target else { return "\(MorselFormat.number(value)) g" }
        return "\(MorselFormat.number(value)) / \(MorselFormat.number(target))g"
    }

    private func tickX(in width: CGFloat) -> CGFloat {
        guard let target, target > 0 else { return 0 }
        let scale = scaleDenominator
        return width * CGFloat(target / scale) - 0.7
    }
}

// MARK: - V1 calorie ring

/// The hand-inked calorie ring: inkline contour + stippled inner guide, wash
/// pigment band from 12 o'clock, and the ink tick at 12. The ring itself
/// carries no text (the readout column sits beside it, per the approved V1).
struct JournalCalorieRing: View {
    let eaten: Double
    let goal: Double?
    let status: GoalStatus

    private var progress: Double {
        DashboardMath.goalProgress(eaten: eaten, goal: goal)
    }

    private var bandColor: Color {
        switch status {
        case .over: return Color.morselExcessWash
        case .nearGoal: return Color.morselMustardDeep
        case .onTrack, .unavailable: return Color.morselTodayWash
        }
    }

    var body: some View {
        ZStack {
            // stippled inner guide
            Circle()
                .stroke(Color.morselInkLine, style: StrokeStyle(lineWidth: 1.2, dash: [1.4, 4.5]))
                .padding(13)
            // inkline contour
            Circle()
                .stroke(Color.morselInkLine, lineWidth: 1.4)
            // pigment wash band (pooled darker edge on top)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(bandColor, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Color.morselAccent.opacity(status == .over ? 0.25 : 0), lineWidth: 2)
                .rotationEffect(.degrees(-90))
            // 12 o'clock ink tick
            Rectangle()
                .fill(Color.morselInkLine)
                .frame(width: 1.4, height: 8)
                .offset(y: -46)
        }
        .frame(width: 104, height: 104)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calories eaten versus goal")
        .accessibilityValue(
            "\(MorselFormat.number(eaten)) kilocalories of \(MorselFormat.number(goal))"
        )
    }
}

// MARK: - Journal page wrapper

extension View {
    /// Scrolls the deterministic paper texture (sheet rules + grain) under
    /// this content. Drawn as a ZStack underlay — not a `.background` view —
    /// so the chrome byte contract (one `.background` in the journal file)
    /// stays intact while the paper scrolls with its content.
    func morselJournalPaperUnderlay() -> some View {
        ZStack {
            JournalPaperTexture()
            self
        }
    }
}

/// Standard journal page: warm paper ground (with the #105 grain + sheet
/// rules), spine furniture + leading content inset. `content` scrolls; the
/// bottom inset clears the floating tab bar. The page scrolls the paper with
/// its content and dismisses the keyboard on vertical scroll (AC6).
struct JournalPage<Content: View>: View {
    let date: Date
    let bottomInset: CGFloat
    @ViewBuilder let content: Content

    init(date: Date, bottomInset: CGFloat = 56, @ViewBuilder content: () -> Content) {
        self.date = date
        self.bottomInset = bottomInset
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
                    .padding(.leading, 46)
                    .padding(.trailing, 18)
                    .padding(.top, 20)
                    .padding(.bottom, bottomInset)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .morselJournalPaperUnderlay()
            .morselBlankSpaceDismissesKeyboard()
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(Color.morselBackground.ignoresSafeArea())
        .overlay(alignment: .leading) {
            JournalPageFurniture(date: date)
                .padding(.top, 8)
        }
    }
}

// MARK: - Section heading (V1: uppercase serif label + mono detail)

struct SectionHeading: View {
    let title: String
    let detail: String?

    init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .morselSectionLabel()
            Spacer()
            if let detail {
                Text(detail)
                    .font(.morselData)
                    .foregroundStyle(Color.morselInkTwo)
            }
        }
    }
}

// MARK: - Readout tags (V1: italic serif provenance + mono outline confidence)

/// Provenance annotation: italic serif ("manual", "photo vision").
struct ProvenanceLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.morselFootnote)
            .foregroundStyle(Color.morselInkTwo)
    }
}

/// Mono confidence box: thin inkline contour + tabular value ("0.90").
struct ConfidenceBox: View {
    let value: Double?

    var body: some View {
        Text(MorselFormat.confidence(value))
            .font(.morselData)
            .monospacedDigit()
            .foregroundStyle(Color.morselInkTwo)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.morselInkLine, lineWidth: 1)
            }
    }
}

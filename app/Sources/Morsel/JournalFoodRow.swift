import SwiftUI

// Issue #229 — the approved Variant A food row, ported from the pinned design
// source (`docs/design/tactile-journal/style.css` `.row`):
//
//   grid 56px minmax(0,1fr) 38px · column-gap 8px · align-items center
//   padding 10px 0 · min-height 87px · border-bottom 1px var(--line)
//   img 56×56 object-fit contain (spans both rows)
//   name 18px/1.05 weight 500 · portion 11px/1.8 Plex (secondary)
//   energy 14px Plex right-aligned + 10px/1.5 "kcal ›" line (16px Garamond)
//   nutrition 12px/1.5 Plex (secondary), second grid row
//   `#confirmation` 15px positive text under the nutrition line
//
// CSS line boxes are explicit there and implicit in SwiftUI, so the four line
// boxes that decide the row's height and rhythm are pinned (Dynamic Type keeps
// them live through @ScaledMetric): the row then measures the design's 87pt.
// The row is a Button in the design (its `:active` state lifts the row by 1px
// with a 100ms transition); Reduce Motion removes the lift, exactly like the
// design's `.rm`/`prefers-reduced-motion` block. Navigation and page-turn
// mechanics are untouched — this is only the row's own press state.

/// The A row's own measurement contract, in points.
enum JournalRowMetrics {
    static let artwork: CGFloat = 56
    static let columnGap: CGFloat = 8
    static let energyColumn: CGFloat = 38
    static let textInset: CGFloat = artwork + columnGap
    static let contentMinHeight: CGFloat = 67
    static let rowMinHeight: CGFloat = 87
    static let verticalPadding: CGFloat = 10
    // Pinned line boxes (the design's own line-height budget).
    static let nameLine: CGFloat = 19
    static let portionLine: CGFloat = 20
    static let energyValueLine: CGFloat = 17
    static let energyUnitLine: CGFloat = 13
    static let chevronLine: CGFloat = 18
}

/// One food row: the approved A artwork, the food's name and portion, the
/// right-aligned energy column and the macro line, over a hairline.
struct JournalFoodRow: View {
    let item: MealItem
    /// The saved-edit confirmation line (nil unless this row was just saved).
    var confirmation: String?

    @ScaledMetric(relativeTo: .body) private var nameLine = JournalRowMetrics.nameLine
    @ScaledMetric(relativeTo: .body) private var portionLine = JournalRowMetrics.portionLine
    @ScaledMetric(relativeTo: .body) private var energyValueLine = JournalRowMetrics.energyValueLine
    @ScaledMetric(relativeTo: .body) private var energyUnitLine = JournalRowMetrics.energyUnitLine
    @ScaledMetric(relativeTo: .body) private var chevronLine = JournalRowMetrics.chevronLine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: JournalRowMetrics.columnGap) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name)
                        .font(.morselSerif(size: 18, weight: 500))
                        .foregroundStyle(Color.morselInk)
                        .lineLimit(2)
                        .frame(height: nameLine, alignment: .leading)
                    Text(MorselFormat.portion(quantity: item.quantity, unit: item.unit))
                        .font(.morselMono(size: 11))
                        .foregroundStyle(Color.morselInkTwo)
                        .frame(height: portionLine, alignment: .leading)
                }
                Spacer(minLength: 0)
                energyColumn
            }
            Text(MorselFormat.macroLine(for: item))
                .font(.morselMono(size: 12))
                .foregroundStyle(Color.morselInkTwo)
            if let confirmation {
                Text(confirmation)
                    .font(.morselSerif(size: 15))
                    .foregroundStyle(Color.morselForest)
                    .padding(.top, 8)
                    .accessibilityLabel("Saved edit: \(confirmation)")
            }
        }
        .frame(maxWidth: .infinity, minHeight: JournalRowMetrics.contentMinHeight, alignment: .topLeading)
        .padding(.leading, JournalRowMetrics.textInset)
        .padding(.vertical, JournalRowMetrics.verticalPadding)
        .frame(minHeight: JournalRowMetrics.rowMinHeight)
        .overlay(alignment: .leading) {
            MealArtworkSlot(items: [item], size: JournalRowMetrics.artwork)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.morselLine)
                .frame(height: 1)
        }
    }

    /// Right column: kcal value, the "kcal" unit word and the row's chevron.
    /// The design's 38px column wraps the 16px Garamond chevron onto its own
    /// line under "kcal" — reproduced literally.
    private var energyColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(MorselFormat.number(item.caloriesKcal))
                .font(.morselMono(size: 14))
                .monospacedDigit()
                .foregroundStyle(Color.morselInk)
                .frame(height: energyValueLine, alignment: .trailing)
            Text("kcal")
                .font(.morselMono(size: 10))
                .foregroundStyle(Color.morselInkTwo)
                .frame(height: energyUnitLine, alignment: .trailing)
            Text("›")
                .font(.morselSerif(size: 16))
                .foregroundStyle(Color.morselInkTwo)
                .frame(height: chevronLine, alignment: .trailing)
        }
        .frame(width: JournalRowMetrics.energyColumn, alignment: .trailing)
    }
}

/// The A row press state: `translateY(-1px)` with a 100ms transition, and no
/// transform under Reduce Motion (design `.rm .row:active`).
struct JournalRowButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed && !reduceMotion ? -1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

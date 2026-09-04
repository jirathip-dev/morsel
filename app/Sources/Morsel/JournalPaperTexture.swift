import SwiftUI
import UIKit

// Issue #105 — deterministic paper ground (grain + ruled sheet). Kept in
// its own file so JournalUI stays inside the repo lint budgets.

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
                let posX = next() * Double(tileSize)
                let posY = next() * Double(tileSize)
                let radius = 0.4 + next() * 0.5
                ink.withAlphaComponent(speckAlpha * (next() > 0.8 ? 1.6 : 1.0)).setFill()
                context.cgContext.fillEllipse(
                    in: CGRect(
                        x: posX - radius, y: posY - radius,
                        width: radius * 2, height: radius * 2
                    )
                )
            }
        }
        tileCache[night] = image
        return image
    }
}

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

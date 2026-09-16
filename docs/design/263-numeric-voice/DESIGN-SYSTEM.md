# Numeric voice · isolated type study

Surface archetype: Compare. This is an approval/evidence gallery, not a dashboard redesign or a hero-plus-cards landing page.

## Locked

Source base: `2d87d61e73c6c3db7bd1420294ccf1551232405d`.
Approved Variant A artwork control: `68be41d1f3e3fdabcfe28efab79e7c4a2879377b`.
Existing source files, native navigation, page flipping, calendar interaction and data/Health policy are untouched.

Palette is resolved from the pinned DesignSystem table: Paper background #FFF7E8, ink #2A261F, secondary #655A4B, tertiary #756955, surface #FFFCF5, line #E3D2BA. Night background #2A261F, ink #FFF7E8, secondary #F2E9D9, tertiary #E3D2BA, surface #373129, line #756955. Accent #E66A2C; theme-resolved supporting pigments retained. No new decorative gradients.

Bundled Caveat remains heading/annotation voice; EB Garamond remains body; Garamond Italic remains provenance. No downloaded font or network dependency. SVG food art is retained byte-for-byte; 56 px illustration slots remain illustrations, not photographs.

## One deliberate candidate delta

Affected numeric and nontechnical inherited-mono text: IBM Plex Mono Regular/Medium → bundled EB Garamond variable face at nominal weights 400/500, with explicit `tnum` and `lnum`. Declared point-size equivalents are 9, 10, 11, 12, 14, 17, 22, 30 and 32 CSS px at DPR 1. No optical size compensation in this round: owner sees the true same-size family change, including how fine small serif text becomes.

Technical URL/setup prompt/copy pills stay Plex. The issue explicitly names the auth wordmark as retained; both identical “morsel” brand uses are retained as a named brand exception, not dishonestly labelled technical. Settings configuration-status text is retained with its endpoint block. Other attribution/prose/button-label mono becomes serif. JPEG/KB is treated as user-facing photo metadata, so its whole mixed line changes.

The implementation must split semantic font roles; it must NOT globally replace `morselData` or `morselDataMedium`, since those tokens also carry the unchanged technical strings. This document does not provide or approve a Swift implementation.

## Layout and evidence posture

Phone excerpt width 390 px, fixed capture viewport 390×844; gallery also checked at 1100×1000. Excerpts retain source size/weight and text hierarchy, but are browser reconstructions, not pixel-equivalent native screenshots. Footer and review header are evidence furniture, outside the app excerpt. Source-site labels are machine annotations rather than visible app UI.

Page gutter, ruled fields, unboxed readouts, serif food names and unchanged illustrations express the established journal language. Spacing uses 6/8/10/12/14/16/20/24 px as appropriate to a specimen, not a proposed app-wide spacing migration. Radius only where an existing pill/cell warrants it. No elevation. No motion. Review controls have visible focus/hover and ≥44 px targets; specimen fields/buttons are deliberately inert text studies.

## Approval boundaries

Browser layout can prove browser tabular advances and detect clipping. It cannot prove SwiftUI custom-font feature propagation, UIKit UIFontMetrics, Dynamic Type, VoiceOver, actual native input or Swift Charts marker fidelity. No decision about these is inferred from the font binary. Native proof and owner approval are separate gates.

---
version: alpha
name: Morsel
description: A readout, not a showcase — data store + read-only dashboard + agent skill. Approved V1 naturalist field-journal (issue #90): warm paper ground + Night-ink theme, orange identity/action anchor (ink label, never white), sage/forest support, hand-inked calorie ring with wash fill, macro wash strips, Today · History · Goals primary tabs, eaten-vs-goal semantics.
colors:
  ink: "#2A261F"
  ink2: "#655A4B"
  ink3: "#756955"
  bg: "#FFF7E8"
  surface: "#FFFCF5"
  surface2: "#F2E9D9"
  line: "#E3D2BA"
  accent: "#E66A2C"
  accentSoft: "#FBE1C9"
  leaf: "#5E7E57"
  leafSoft: "#E1E9D7"
  forest: "#2F654B"
  coral: "#B94738"
  mustard: "#D6A62C"
  mustardDeep: "#A5750B"
  review: "#7A3D2B"
  over: "#9C3A2F"
  inkline: "#8B7355"
typography:
  display:
    fontFamily: Caveat
    fontSize: 34px
    fontWeight: 400
  title:
    fontFamily: EB Garamond
    fontSize: 17px
    fontWeight: 600
  body:
    fontFamily: EB Garamond
    fontSize: 15px
    fontWeight: 400
    lineHeight: 1.4
  label:
    fontFamily: EB Garamond
    fontSize: 11px
    fontWeight: 600
    letterSpacing: "0.08em"
    textTransform: uppercase
  data:
    fontFamily: IBM Plex Mono
    fontSize: 11px
    fontWeight: 400
    fontFeature: tnum
rounded:
  sm: 6px
  md: 8px
  lg: 12px
spacing:
  sm: 8px
  md: 16px
  lg: 24px
components:
  journal-ring:
    trackColor: "{colors.inkline}"
    fillColor: "{colors.accent}"
    wash: today wash
  macro-wash:
    proteinWash: "{colors.coral}"
    carbsWash: "{colors.mustardDeep}"
    fatWash: "{colors.leaf}"
  tag:
    textColor: "{colors.ink2}"
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.sm}"
  tag-conf-high:
    textColor: "{colors.forest}"
    backgroundColor: "{colors.leafSoft}"
  tag-conf-low:
    textColor: "{colors.review}"
    backgroundColor: "{colors.accentSoft}"
  btn-confirm:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "0 14px"
  btn-ghost:
    backgroundColor: "{colors.surface2}"
    textColor: "{colors.ink2}"
    rounded: "{rounded.md}"
    padding: "0 14px"
  row-low:
    backgroundColor: "{colors.accentSoft}"
    rounded: "{rounded.sm}"
---

## Overview

Morsel is **not** a chat app and has **no in-app AI**. It is a Supabase-backed
store that a remote MCP server writes to (on behalf of the agent you already
talk to), plus a read-only iOS dashboard. So the dashboard's job is *not* to
persuade or entertain — it is to **render the record honestly** and make it
correctable.

The approved V1 presentation (issue #90, implemented by issue #94) is a
**naturalist's field journal**: warm paper (or Night-ink charcoal) pages with
hand-lettered headings, inkline contours, wash pigment fills, and mono data
vocabulary. The visual weight sits on the data the agent wrote — `source`,
`confidence`, `unit`, per-item macros — and on the trust affordance that
surfaces low-confidence estimates for a one-tap correction.

The approved V1 contract (390×844 proofs per state × Paper/Night) is committed
at `docs/evidence/issue-90/` (README + token map + PNGs). This file is the
normative token spec the SwiftUI app follows. The prototype (HTML) is a web
reference only: HTML geometry, CSS gradients, and browser controls are never
copied into SwiftUI.

## Themes (Paper and Night ink)

Two ink themes plus "Follow system", switched in Settings → Appearance and
applied at the root (`MorselAppearance.scheme(for:)` + dynamic native tokens):

- **Paper** (default) — page `bg #FFF7E8`, ink copy, warm surfaces.
- **Night ink** — the palette pigments resolved over the ink ground
  `#2A261F`: page `ink`, copy cream, secondary `surface2`, hairline `ink3`,
  pigments invert to their soft family (Protein wash `accentSoft`, Carbs wash
  `mustard`, Fat wash `leafSoft`, positive text `leafSoft`, review text
  `accentSoft` on `review` wash, over text cream — the hatch carries the over
  mark). Exact resolved hexes live in `docs/evidence/issue-90/tokens.md` and
  `app/Sources/Morsel/DesignSystem.swift` (each token ships a paper + night
  pair; no other hex authority for native).
- Strict text pairs stay ≥ 4.5:1 and marks ≥ 3:1 worst-case-over-grain in
  both themes (measured tables in the promoted contract).

## Colors (approved V1 — Orange Hearth + Sage, plus inkline)

- **ink (#2A261F)** — warm near-black primary copy and the dark label on
  identity hues. Orange never carries a white label.
- **inkline (#8B7355)** — warm sepia hand-ruled lines, plate/ring contours,
  goal ticks, and page furniture; never body text (3.77:1 on paper, 4.04:1 in
  night — marks/contours ≥ 3:1).
- **accent (#E66A2C)** — the orange **identity/action anchor**: confirm
  buttons, the today ring wash, focus states. It takes dark **ink**, never
  white. Orange pigment washes are the measured-data wash treatment below,
  never new scalar colors.
- **forest (#2F654B) / leafSoft (#E1E9D7)** — stable/on-track support and
  high-confidence tags; **forest** is also the active-tab word and the
  history bar ink. In Night ink the positive family reads light
  (leafSoft/leaf washes on charcoal).
- **review (#7A3D2B) on accentSoft (#FBE1C9)** — needs-review/low-confidence
  names uncertainty without treating it as an error. **coral (#B94738)**
  supports protein/correction; **over (#9C3A2F)** is over-goal/error text on
  paper (cream in Night ink; the hatch is the over mark).
- **mustard (#D6A62C)** — non-text highlight; **mustardDeep (#A5750B)** is
  the accessible data stroke (carbs tick/near-goal).
- **Neutrals** — bg (#FFF7E8) warm paper, surface (#FFFCF5), surface2
  (#F2E9D9) field/track, line (#E3D2BA) hairline, ink2 (#655A4B) secondary,
  ink3 (#756955) metadata/section labels.

Color is discipline: one orange action anchor, a sage/forest support family,
a warm review family, and mustard highlights. Add a color to the token table
first, never an ad-hoc hex in a component.

## Charts & washes (measured-data treatment)

Wash fills apply **only** to measured data (ring, macro strips, history bars,
weight trend). Pigments are palette tokens rendered as translucent washes
(Paper ~0.92 over the page with an inkline contour and pooled edge; Night at
full strength over charcoal) — see `tokens.md` for the wash role map. The
legacy measured-data gradient stops remain documented for the renderer/SVG
parity:

```css
--grad-protein: linear-gradient(90deg,#C9513D,#A63A32);
--grad-carbs:   linear-gradient(90deg,#B07A13,#875A02);
--grad-fat:     linear-gradient(90deg,#6B8B60,#3F6745);
--grad-gauge:   linear-gradient(135deg,#6B8B60,#2F654B);
--grad-card:    linear-gradient(180deg,#FFFCF5,#FFF5E5);
```

- **Macro strips** — wash pigment along a faint denominator rail with an
  inkline goal tick and mono `value / goalg` readout; Protein
  coral/accentSoft, Carbs mustardDeep/mustard, Fat leaf/leafSoft by theme.
- **Calorie ring** — hand-inked contour + stippled guide with a wash band
  from 12 o'clock (today wash = accent; near-goal = mustardDeep; over =
  over wash + cream/ink hatch). Numeric readout sits beside the ring; the
  ring itself stays empty (values live in the readout column).
- Every bar/ring keeps an adjacent numeric value and label — the wash
  carries *feel*, mono text carries the precise value.

## Typography

- **Hand lettering:** Caveat (OFL) — page titles, annotations, tab words,
  hand margin notes. Never use it for data.
- **Serif body + labels:** EB Garamond (OFL) — copy, item names, section
  labels (uppercase, tracked).
- **Italic captions:** EB Garamond Italic — `source:`, provenance
  (`manual`, `photo vision`), "moved 386 kcal today".
- **Figures:** IBM Plex Mono `tnum` (OFL) — every visible number: totals,
  item calories, macro grams, dates/times, confidence, chart labels, folios.
- Fonts are bundled in the app (`app/Fonts/`, OFL licenses) and registered
  at launch (`MorselFontCatalog`); no network fetch, no UIAppFonts plist
  route (the fastlane INFOPLIST_FILE template is release tooling).

## Layout

- Journal page: full-height left margin line (inkline) + rotated gutter date
  + hand rules; warm paper ground (Paper) or charcoal (Night ink); content
  clears the margin (~46pt) and the floating bottom bar (96pt inset).
- Bottom navigation: **Today · History · Goals** — three primary tabs, hand
  words with an ink marker stroke under the active tab. Goals is a primary
  tab (issue #94), never a secondary route. Settings sits behind the toothed
  cog on Today.
- **Today** — header (date line + hand title + add tab + cog), hero (ring +
  `EATEN · GOAL` readout + `886 kcal left`/`over` + `source:`), three macro
  wash strips, the activity margin note, then a hairline-divided meal log.
  No weight chart on Today.
- **History** — `Calories vs goal` ledger: 7/30-day range (hand words),
  per-day wash bars against the goal's ±50 kcal tolerance band with orange
  hatch on the overshoot, summary strip (avg kcal / days over / logged /
  streak / `today · partial`), `DAYS VS GOAL` list (signed mono delta +
  state word), tap-a-day drill-down (macros + items), and the real-dated
  weight trend (`the line, not one day`).
- **Goals** — journal editor as a tab: direction choices (Cut / Maintain /
  Bulk), one-decimal mono target fields with inkline underlines, `Use these
  goals` / `Goals saved ✓`, `WHAT CHANGES`, `See it` back to Today.
- Each meal group: name + mono time, kcal; item rows: name, mono portion +
  macro line, italic provenance + mono confidence box, kcal. Low-confidence
  rows carry the soft review wash + `verify` tag (never a left rail).
  Remove uses the ink strike × (native swipe removal also allowed); Settings
  keeps Appearance, MCP endpoint, Replay onboarding, Health (margin-note
  copy), Sign out, and the version folio.

## Elevation & Depth

Matte and near-flat. Journal hairlines (inkline/line at low alpha) and warm
washes do the separation; no cards, no drop-shadow stacks, no stock
table-view chrome. The bottom bar sits on the page ground behind a hairline.

## Semantics (locked — never regressed)

- The Today hero and every delta read **eaten vs goal** (TDEE-based computed
  or manual target). Displayed status words: "kcal left" / "kcal over" on
  Today; History state words are the signed **under / on target / over**
  within a ±50 kcal tolerance band.
- **Active/active energy is context only** ("moved 386 kcal today"), a margin
  note that is **never subtracted** from eaten calories; there is no "net
  intake"/net-energy display in the app.
- Empty/loading/unavailable-goal/low-confidence states are honest and
  readable; no invented values; raw Supabase/Postgres/backend text never
  reaches users (friendly copy tables only).

## Do's and Don'ts

**Do**
- Show exactly what the agent wrote: source, confidence, unit, per-item macros.
- Make the trust affordance (needs-review / verify) a first-class element.
- Use mono only for data figures; use hand lettering for headings only.
- Use orange for identity/action + today wash, sage/forest for stable
  support, mustard for measured highlights, warm paper breathing room.
- Separate with ink hairlines and washes, not shadows.
- Keep every strict text pair ≥4.5:1 and marks ≥3:1 in BOTH themes.

**Don't**
- Don't build a chat UI, a feed, or any in-app AI surface — out of scope by design.
- Don't copy HTML geometry, web gradients, or browser controls into SwiftUI.
- Don't subtract activity from eaten calories or display a "net" readout.
- Don't invent colors ad-hoc — add the token, then use it.
- Don't put white on the orange button; ink is the label.
- Don't render a white/light surface in Night ink that would blind the page.
- Don't collapse review and over-goal into one state — review (#7A3D2B on
  accentSoft) and over (#9C3A2F) stay distinct.
- Don't decorate low-confidence with an accent rail or an icon; a wash tint +
  `verify` tag + the reason is the honest treatment.

## Native implementation (SwiftUI)

The prototype is a **web reference**, not the shipped UI. The real Morsel
dashboard is the **SwiftUI** app (`app/`) and uses **SwiftUI + Apple native
components** so it reads as a platform app — not a ported web mockup:

| Design (this doc) | SwiftUI implementation |
|---|---|
| Journal page furniture | `JournalPage`/`JournalPageFurniture` (spine rule + rotated mono date), inkline `JournalRule` dividers, `MarkerStroke` underlines |
| Tab bar (Today · History · Goals) | custom native `JournalTabBar` (hand words + marker stroke), `JournalTab` shell switch |
| Calorie ring | `JournalCalorieRing` (inkline contour + stipple, wash `trim` band, 12 o'clock tick) beside the mono readout column |
| Macro wash strips | `MacroWashStrip` (rail + `WashEdgeShape` pigment + inkline goal tick + mono readout) |
| Meals log | `ScrollView` + `LazyVStack` with inkline hairlines, `JournalRule` group separators |
| Provenance/confidence | italic serif label + mono outline `ConfidenceBox` |
| Needs-review / verify | wash row tint + `verify` tag + correction sheet |
| Goals editor | `GoalsView` primary tab (hand directions, one-decimal mono fields, inkline underlines) |
| History ledger | `HistoryView`/`HistoryViewModel` (7/30 bars, summary, list, drill-down, `V1WeightTrendView` Swift Charts) |
| Settings | `SettingsJournalView` full-page cover behind the toothed cog |

Design tokens live in `app/Sources/Morsel/DesignSystem.swift` (dual paper/night
pairs) with this file as the normative spec; the web reference stays in
lockstep for the server snapshot renderer.

## Server snapshot renderer (Tier 1)

`get_dashboard_summary` (and `get_day`) should emit the History chart as the
`image` content block (`{ type:"image", data:<base64 SVG>, mimeType:"image/svg+xml" }`)
per `IN_CHAT_RENDER.md`, so the in-chat chart and the app agree without native
rasterization dependencies. The renderer output should match the **History
chart** here: bars scaled to the range's max, a dashed goal line at the
computed target, a `markdown` `text` block fallback (summary + delta list) for
clients that can't render images. One dataset, many views.

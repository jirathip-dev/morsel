---
version: alpha
name: Morsel
description: A readout, not a showcase — data store + read-only dashboard + agent skill. Warm paper ground, orange identity/action anchor (ink label, never white), sage/forest support, mustard highlights. Approved V1 "Orange Hearth + Sage" (issue #32).
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
typography:
  display:
    fontFamily: Nunito Sans
    fontSize: 22px
    fontWeight: 800
    letterSpacing: "-0.02em"
  title:
    fontFamily: Nunito Sans
    fontSize: 16px
    fontWeight: 800
  body:
    fontFamily: Nunito Sans
    fontSize: 14.5px
    fontWeight: 400
    lineHeight: 1.4
  label:
    fontFamily: Nunito Sans
    fontSize: 12px
    fontWeight: 700
    letterSpacing: "0.08em"
    textTransform: uppercase
  data:
    fontFamily: IBM Plex Mono
    fontSize: 11px
    fontWeight: 500
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
  gauge:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: 16px
  gauge-ring:
    trackColor: "{colors.surface2}"
    fillColor: "{colors.accent}"
    fillColorNear: "{colors.mustardDeep}"
    fillColorOver: "{colors.over}"
  macro-track:
    backgroundColor: "{colors.surface2}"
  macro-line:
    proteinColor: "{colors.coral}"
    carbsColor: "{colors.mustardDeep}"
    fatColor: "{colors.leaf}"
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

The design consequence: the UI reads like an **instrument**, not a marketing
mockup. No phone-bezel theater, no fake status bar, no decorative cards. The
visual weight sits on the **data the agent wrote** — `source`, `confidence`,
`unit`, per-item macros — and on the **trust affordance** that surfaces
low-confidence estimates for a one-tap correction.

The reference implementation is `./prototype.html` (this repo, `docs/`). This
file is the normative token spec the SwiftUI app and the server snapshot
renderer should follow.

## Colors (approved V1 — Orange Hearth + Sage)

- **ink (#2A261F)** — warm near-black for primary copy and the dark label on
  identity hues. Orange never carries a white label.
- **accent (#E66A2C)** — the orange **identity/action anchor**: confirm
  buttons, calorie figures, active nav, slider thumbs, focus states. It takes
  dark **ink**, never white.
- **forest (#2F654B) / leafSoft (#E1E9D7)** — stable/on-track support and
  high-confidence tags; **forest** is also the active-navigation text.
  **leaf (#5E7E57)** is the leafy supporting data color. Surfaces stay warm —
  the sage family supports status, it never green-washes backgrounds.
- **review (#7A3D2B) on accentSoft (#FBE1C9)** — needs-review/low-confidence
  names uncertainty without treating it as an error. **coral (#B94738)**
  supports protein/correction and warm over-goal families; **over (#9C3A2F)**
  is over-goal/error text.
- **mustard (#D6A62C)** — non-text highlight; **mustardDeep (#A5750B)** is
  the accessible data stroke (carbs).
- **Neutrals** — bg (#FFF7E8) warm paper, surface (#FFFCF5), surface2
  (#F2E9D9) field/track, line (#E3D2BA) hairline, ink2 (#655A4B) secondary,
  ink3 (#756955) metadata/section labels.

Color is discipline: one orange action anchor, a sage/forest support family,
a warm review family, and mustard highlights. Measured data graphics keep
their documented measured-data gradients (below); everything else is matte
and near-flat. Add a color to the token table first, never an ad-hoc hex in a
component.

## Charts & gradients (measured-data treatment)

Gradients apply **only** to measured data and the single readout card — they
are the documented measured-data treatment from the approved token artifacts,
never new scalar/background decoration. Values are defined once — in the
prototype CSS and a SwiftUI `LinearGradient` extension — **not** in the
`colors:` block, which only takes single CSS colors:

```css
--grad-protein: linear-gradient(90deg,#C9513D,#A63A32);
--grad-carbs:   linear-gradient(90deg,#B07A13,#875A02);
--grad-fat:     linear-gradient(90deg,#6B8B60,#3F6745);
--grad-gauge:   linear-gradient(135deg,#6B8B60,#2F654B);
--grad-card:    linear-gradient(180deg,#FFFCF5,#FFF5E5);
```

- **Macro bars** — `gradProtein` (coral), `gradCarbs` (mustardDeep family),
  `gradFat` (leaf family), rounded caps, ~6px tall on a surface2 track, each
  verified ≥3:1 against its track. The macro dot uses the same gradient.
- **Calorie ring** — `gradGauge` (leaf→forest). Near-goal uses
  `mustardDeep`, over-goal uses `over`. Every bar/ring keeps an adjacent
  numeric value, label, and track — the gradient carries *feel*, text carries
  the precise value, so gradient degeneracy never blinds a readout.
- **Cards** — a faint `gradCard` (surface → #FFF5E5) on the gauge readout
  surface only.

On native, map them to SwiftUI `LinearGradient` styling.

## Typography

- **Copy + numerals:** Nunito Sans (400/600/700/800). Humanist, warm, food-friendly.
  Numerals use tabular figures (`font-variant-numeric: tabular-nums`) so calorie
  counts align in lists.
- **Data vocabulary:** IBM Plex Mono (400/500). Reserved for the things the agent
  wrote — `source` (photo_vision / manual), `confidence` (0.90), gram targets
  (`69 / 156g`), and per-item macro lines (`P24 C30 F9`). Mono is the "the app is
  showing you raw data" signal. Never use mono for headings or body copy.
- Hierarchy comes from weight + size + spacing, not boxes: section labels are
  12px 700 uppercase (ink3), item names 14.5px 700, headline kcal 14px 800
  in accent, the gauge number 26px 800.

## Layout

- App column: `max-width: 430px`, centered; `padding: 24px 18px`. On small
  screens `20px 16px`. Fixed bottom nav (4 items max) with a subtle top hairline.
  Active nav text uses forest.
- **The gauge** is the only card; everything below is a hairline-divided
  **list** (the log), not a grid of cards. Group items by `meal_type`
  (breakfast/lunch/dinner/snack); each group has a header row (type, time,
  group kcal) then item rows.
- Each **item row**: name + portion (left), headline kcal (right), and below the
  name a mono macro line + a tag row (source + confidence). This is the primary
  composition. A **low-confidence** row gets a soft accentSoft tint + a `verify`
  tag; it is *not* given a left accent rail (that reads as decoration, not
  hierarchy).

## Elevation & Depth

Matte and near-flat. Cards carry a 1px hairline (line) border on surface; no
drop-shadow stacks. Hairlines and warm/sage tints do the separation work. The
fixed bottom nav uses a near-opaque surface backdrop so scrolled content
recedes — not a glassy banner. Depth is earned through tint and border, not
shadow.

## Shapes

No shape-system change. `rounded.sm` (6px) micro elements, `rounded.md`
(8px) buttons/tags, `rounded.lg` (12px) the gauge card. Macro dots stay 9px
squares (2px radius). The approved bitten smiling-onigiri geometry (wrap,
bite, face) remains byte-for-byte the control — only its three scalar fills
map to this palette.

## Components

- **Gauge** — small ring (left) with remaining kcal centered; right side shows
  `Eaten · Goal · X left` and three macro lines (label, 4px track with progress,
  `value / targetg`). Ring fill: the measured `gradGauge`; near-goal
  `mustardDeep`, over `over`.
- **Goal source** — the gauge's `Goal` is the **computed** target from the profile
  (Mifflin-St Jeor → TDEE → diet goal; see `TARGETS.md`), not a manual number. The
  Targets screen shows the computed value and lets the user **confirm or adjust**;
  adjusting flips `goals.source` to `manual`.
- **Targets screen** — a short profile form (sex, age, height, weight, activity,
  diet goal: mono upper-case labels + number inputs on surface2 + segmented
  toggles) above a computed readout (big `t-kcal` number, `BMR … · TDEE … ·
  <goal>` meta line, mono macro line, `source: computed` tag). Actions:
  **Looks right** (confirm → lock, `source: computed`) and **Adjust** (reveals
  the manual kcal/macro sliders → `source: manual`); a `Use computed` ghost
  returns to the computed value.
- **Tag** — monospace, 5px radius, surface bg + hairline border, ink2 text.
  `tag-conf-high` (forest on leafSoft), `tag-conf-low` (review on accentSoft).
- **btn-confirm** (accent with ink label) and **btn-ghost** (surface2, ink2) —
  40px tall, 8px radius. Confirmation is the high-emphasis action; there is
  exactly one confirm per correction card. Hover stays legible: ink on
  accentSoft.
- **row-low** — the low-confidence item row (accentSoft tint, 6px radius). It
  must always carry a `verify` tag so the tint is never the only signal.
- **Review card** — `// agent: <reason>` note in mono plus editable kcal/P/C/F
  fields (mono inputs on surface2) with `Keep guess` (ghost) and `Looks right`
  `(confirm)`. Confirming flips the confidence tag to `1.00` high.
- **History screen** — a `calories vs goal` bar chart with a **7 / 30 day**
  range toggle (bars scaled to the range's max, dashed goal line at the computed
  target), a summary
  strip (avg kcal, days over, day streak), and a **Days vs goal** list where each
  day shows kcal vs goal and a signed mono **delta** with a state word
  (**under / on target / over**) — the over/under framing, not "over/under eat".
  **Tap a day to open it** (drill-down: that day's kcal, macro split, and items
  for today; past-day macros derive from the total via the 30/45/25 split).
- **Tab bar** — the bottom nav is the floating translucent pill pinned to the
  bottom of the app column; content scrolls behind it; active item text uses
  forest.

## Do's and Don'ts

**Do**
- Show exactly what the agent wrote: source, confidence, unit, per-item macros.
- Make the trust affordance (needs-review / verify) a first-class element.
- Use mono only for data vocabulary; use tabular numerals for all numbers.
- Use orange for identity/action, sage/forest for stable support, coral for
  correction, mustard for measured highlights, and generous cream breathing room.
- Separate with hairlines and tints, not shadows and decorations.
- Keep measured-data gradients verified ≥3:1 against their tracks and every
  text pair ≥4.5:1.

**Don't**
- Don't build a chat UI, a feed, or any in-app AI surface — out of scope by design.
- Don't add a fake phone bezel, fake status bar, or mock OS chrome.
- Don't reach for a card-per-thing or a 3-feature grid; the day is a log.
- Don't invent colors ad-hoc — add the token, then use it.
- Don't put white on the orange button; ink is the label.
- Don't turn every surface sage; green supports status, it doesn't paint the app.
- Don't copy botanical geometry; the approved onigiri geometry is the control.
- Don't collapse review and over-goal into one state — review (#7A3D2B on
  accentSoft) and over (#9C3A2F) stay distinct.
- Don't decorate low-confidence with an accent rail or an icon; a tint +
  `verify` tag + the reason is the honest treatment.

## Native implementation (SwiftUI)

This prototype is a **web reference**, not the shipped UI. The real Morsel
dashboard is a **SwiftUI** native app (`app/`) and must use **SwiftUI + Apple
native components** so it reads as a platform app — not a ported web mockup.
Map each design element to its native equivalent:

| Design (this doc) | SwiftUI implementation |
|---|---|
| Tab bar | `TabView` with a `toolbarBackground`, or a custom `.regularMaterial` capsule overlay; SF Symbols for icons (`chart.bar`, `list.bullet`, `checkmark.seal`, `slider.horizontal.3`) |
| Calorie gauge / ring | `Circle` stroke with `trim(to:)` progress arc + `Text` center |
| Macro split | `HStack` of label/value rows, or a `Gauge`/`ProgressView` per macro |
| Meals log | `List` / `ScrollView` + `LazyVStack` with `Divider` hairlines |
| Confidence tag | small `Text` capsule (`.caption` mono) — use `monospaced()` for data |
| Item row | `HStack` (name + portion, macro `Text`, kcal) |
| Needs-review / verify | coloured row tint + `Button` ("Looks right") |
| Profile / Targets | `Form` or `ScrollView`: segmented `Picker` for sex & diet goal, `TextField` (`.numberPad`) for age/height/weight, `Picker` for activity, live confirm/adjust `Button`s |
| Range toggle 7/30 | segmented `Picker` |
| Day drill-down | a `Sheet`/`NavigationLink` per day, or an expandable row |

Keep the **design tokens** in this file as the single source; expose them to
SwiftUI via an asset catalog / `Color`+`Font` extension so the native app and the
web reference stay in lockstep. The app is **read-only** (no chat, no AI) — it
renders the store the agent wrote.

## Server snapshot renderer (Tier 1)

`get_dashboard_summary` (and `get_day`) should emit this same chart as the
`image` content block (`{ type:"image", data:<base64 SVG>, mimeType:"image/svg+xml" }`)
per `IN_CHAT_RENDER.md`, so the in-chat chart and the app agree without native
rasterization dependencies. The renderer output should match the **History
chart** here: bars scaled to the range's max, a dashed goal line at the
computed target, a `markdown` `text` block fallback (summary + delta list) for
clients that can't render images. One dataset, many views.

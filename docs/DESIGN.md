---
version: alpha
name: Morsel
description: A readout, not a showcase. Morsel is a data store + read-only dashboard
  + agent skill (no chat). The UI renders what the agent wrote — source, confidence,
  unit, per-item macros — and surfaces a needs-review affordance for low-confidence
  estimates. Warm neutral ground, a single warm-orange accent for interaction and
  calories, amber for carbs, coral-red for over-goal. Humanist sans for copy,
  monospace for the data vocabulary.
colors:
  ink: "#20231E"
  inkTwo: "#666A60"
  inkThree: "#9BA095"
  bg: "#FBFAF6"
  surface: "#FFFFFF"
  surfaceTwo: "#F3F1EA"
  line: "#E7E3D8"
  accent: "#F08A2E"
  accentSoft: "#F6E8D8"
  energy: "#F08A2E"
  energySoft: "#F6E8D8"
  over: "#C0483F"
  low: "#8A5514"
  protein: "#C0483F"
  carbs: "#F0A63C"
  fat: "#D46A2E"
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
    trackColor: "{colors.surfaceTwo}"
    fillColor: "{colors.accent}"
    fillColorNear: "{colors.energy}"
    fillColorOver: "{colors.over}"
  macro-track:
    backgroundColor: "{colors.surfaceTwo}"
  macro-line:
    proteinColor: "{colors.protein}"
    carbsColor: "{colors.carbs}"
    fatColor: "{colors.fat}"
  tag:
    textColor: "{colors.inkTwo}"
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.sm}"
  tag-conf-high:
    textColor: "{colors.ink}"
    backgroundColor: "{colors.accentSoft}"
  tag-conf-low:
    textColor: "{colors.low}"
    backgroundColor: "{colors.energySoft}"
  btn-confirm:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "0 14px"
  btn-ghost:
    backgroundColor: "{colors.surfaceTwo}"
    textColor: "{colors.inkTwo}"
    rounded: "{rounded.md}"
    padding: "0 14px"
  row-low:
    backgroundColor: "{colors.energySoft}"
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

## Colors

- **ink (#20231E)** — warm near-black for primary text and numerals.
- **accent (#F08A2E)** — the *interaction* accent: **warm orange**. Confirm
  buttons, active nav, streak, high-confidence tags; slider thumbs and
  focus states. It is **not** a chart color.
- **energy (#F08A2E)** — calories. Headline kcal numbers and the "verify"
  affordance; the ring's near/over gradient uses this copper-amber family.
- **over (#C0483F)** — text only when eaten exceeds goal.
- **Macro colors (gradients)** — protein coral (#C0483F), carbs amber
  (#F0A63C), fat warm orange-brown (#D46A2E), used as gradient fills
  (`gradProtein` / `gradCarbs` / `gradFat`).
- **Neutrals** — bg (#FBFAF6), surface (#FFFFFF), surfaceTwo (#F3F1EA), line
  (#E7E3D8), inkTwo/inkThree for muted and faint text.

Color is discipline: one interaction accent, a calorie color, and a warm
**status ramp** (see Charts & gradients). Charts use gradients, not flat fills.
Add a color to the token table first, never an ad-hoc hex in a component.

## Charts & gradients

Charts never use flat fills. Every data element is a **gradient**:

- **Macro bars** — `gradProtein` (coral), `gradCarbs` (amber), `gradFat`
  (warm orange-brown), `linear-gradient(180deg,…)`, rounded caps, ~6px tall on
  a surfaceTwo track. The macro dot uses the same gradient.
- **Calorie ring** — SVG `linearGradient` stroke (3-stop for richness). On target
  `gradOn` (amber→warm orange-brown); `gradNear` (golden→copper) as you approach
  (>85%); `gradOver` (blush-coral) when over. A soft radial glow lifts it.
- **History bars + over/under** — a **warm temperature ramp**: `gradUnder`
  (golden-amber, below target) → `gradOn` (amber→warm orange-brown, in the
  ±50 kcal zone) → `gradOver` (blush-coral, above). The dashed goal line
  and signed delta text carry the precise value; the gradient carries the *feel*.
- **Cards** — a faint `gradCard` (#FFFFFF → #FBF9F2) on the gauge/history
  readout surfaces for a soft modern lift.

Gradient values are defined once — in the prototype CSS and a SwiftUI
`LinearGradient` extension — **not** in the DESIGN.md `colors:` block, which only
takes single CSS colors. Never hard-code them per component:

```css
--grad-protein: linear-gradient(180deg,#C0483F,#C0483F);
--grad-carbs:   linear-gradient(180deg,#FFC24B,#F0A63C);
--grad-fat:     linear-gradient(180deg,#F0A63C,#D46A2E);
--grad-under:   linear-gradient(180deg,#FFC24B,#F08A2E);
--grad-on:      linear-gradient(180deg,#F0A63C,#D46A2E);
--grad-over:    linear-gradient(180deg,#F7A98C,#C0483F);
```

On native, map them to SwiftUI `LinearGradient` / `HueRotation` / `Charts`
`LinearGradient` styling.

## Typography

- **Copy + numerals:** Nunito Sans (400/600/700/800). Humanist, warm, food-friendly.
  Numerals use tabular figures (`font-variant-numeric: tabular-nums`) so calorie
  counts align in lists.
- **Data vocabulary:** IBM Plex Mono (400/500). Reserved for the things the agent
  wrote — `source` (photo_vision / manual), `confidence` (0.90), gram targets
  (`69 / 140g`), and per-item macro lines (`P24 C30 F9`). Mono is the "the app is
  showing you raw data" signal. Never use mono for headings or body copy.
- Hierarchy comes from weight + size + spacing, not boxes: section labels are
  12px 700 uppercase (inkThree), item names 14.5px 700, headline kcal 14px 800
  in energy, the gauge number 26px 800.

## Layout

- App column: `max-width: 430px`, centered; `padding: 24px 18px`. On small
  screens `20px 16px`. Fixed bottom nav (4 items max) with a subtle top hairline.
- **The gauge** is the only card; everything below is a hairline-divided **list**
  (the log), not a grid of cards. Group items by `meal_type` (breakfast/lunch/
  dinner/snack); each group has a header row (type, time, group kcal) then item
  rows.
- Each **item row**: name + portion (left), headline kcal (right), and below the
  name a mono macro line + a tag row (source + confidence). This is the primary
  composition. A **low-confidence** row gets a soft amber tint + a `verify` tag;
  it is *not* given a left accent rail (that reads as decoration, not hierarchy).

## Elevation & Depth

Near-flat. Cards carry a 1px hairline (line) border on surface; no drop shadows.
The only non-flat element is the fixed bottom nav, which uses a near-opaque
`rgba(255,255,255,.96)` backdrop so scrolled content recedes — not a glassy
banner. Depth is earned through tint and border, not shadow.

## Shapes

- `rounded.sm` (6px) — micro elements (range thumbs, small fills).
- `rounded.md` (8px) — buttons, mono field inputs, confidence tags.
- `rounded.lg` (12px) — the gauge card and review/config cards.
- Macro dots are 9px squares (2px radius) — a data landmark, not an icon.

## Components

- **Gauge** — small ring (left) with remaining kcal centered; right side shows
  `Eaten · Goal · X left` and three macro lines (label, 4px track with progress,
  `value / targetg`). Ring fill: accent when on track, energy when near goal
  (>85%), over when exceeding.
- **Goal source** — the gauge's `Goal` is the **computed** target from the profile
  (Mifflin-St Jeor → TDEE → diet goal; see `TARGETS.md`), not a manual number. The
  Targets screen shows the computed value and lets the user **confirm or adjust**;
  adjusting flips `goals.source` to `manual`.
- **Targets screen** — a short profile form (sex, age, height, weight, activity,
  diet goal: mono upper-case labels + number inputs + segmented toggles) above a
  computed readout (big `t-kcal` number, `BMR … · TDEE … · <goal>` meta line, mono
  macro line, `source: computed` tag). Actions: **Looks right** (confirm → lock,
  `source: computed`) and **Adjust** (reveals the manual kcal/macro sliders →
  `source: manual`); a `Use computed` ghost returns to the computed value.
- **Tag** — monospace, 5px radius, surface bg + hairline border, inkTwo text.
  `tag-conf-high` (ink on accentSoft), `tag-conf-low` (low on energySoft).
- **btn-confirm** (accent with ink label) and **btn-ghost** (surfaceTwo, inkTwo) —
  40px tall, 8px radius. Confirmation is the high-emphasis action; there is
  exactly one confirm per correction card.
- **row-low** — the low-confidence item row (energySoft tint, 6px radius). It
  must always carry a `verify` tag so the tint is never the only signal.
- **Review card** — `// agent: <reason>` note in mono plus editable kcal/P/C/F
  fields (mono inputs on surfaceTwo) with `Keep guess` (ghost) and `Looks right`
  `(confirm)`. Confirming flips the confidence tag to `1.00` high.
- **History screen** — a `calories vs goal` bar chart with a **7 / 30 day**
  range toggle (bars scaled to the range's max, dashed goal line at the computed
  target), a summary
  strip (avg kcal, days over, day streak), and a **Days vs goal** list where each
  day shows kcal vs goal and a signed mono **delta** with a state word
  (**under / on target / over**) — the over/under framing, not "over/under eat".
  **Tap a day to open it** (drill-down: that day's kcal, macro split, and items
  for today; past-day macros derive from the total via the 30/45/25 split).
- **Liquid-glass tab bar** — the bottom nav is a floating, translucent frosted
  pill (`rgba(255,255,255,.55)` + `backdrop-filter: blur(22px) saturate(1.6)`,
  rounded 22px, hairline border, soft shadow) pinned to the bottom of the app
  column; content scrolls behind it. This is the native-iOS "liquid glass" tab
  bar (see Native implementation below).

## Do's and Don'ts

**Do**
- Show exactly what the agent wrote: source, confidence, unit, per-item macros.
- Make the trust affordance (needs-review / verify) a first-class element.
- Use mono only for data vocabulary; use tabular numerals for all numbers.
- Keep ONE interaction accent and ONE calorie color; encode over/under with the
  warm ramp, not generic red.
- Separate with hairlines and tints, not shadows and decorations.
- Charts use gradient fills; encode over/under as a warm ramp, never
  generic red.

**Don't**
- Don't build a chat UI, a feed, or any in-app AI surface — out of scope by design.
- Don't add a fake phone bezel, fake status bar, or mock OS chrome.
- Don't reach for a card-per-thing or a 3-feature grid; the day is a log.
- Don't invent colors ad-hoc — add the token, then use it.
- Don't decorate low-confidence with an accent rail or an icon; a tint + `verify`
  tag + the reason is the honest treatment.

## Native implementation (SwiftUI)

This prototype is a **web reference**, not the shipped UI. The real Morsel
dashboard is a **SwiftUI** native app (`app/`) and must use **SwiftUI + Apple
native components** so it reads as a platform app — not a ported web mockup.
Map each design element to its native equivalent:

| Design (this doc) | SwiftUI implementation |
|---|---|
| Liquid-glass tab bar | `TabView` with a glass `toolbarBackground`, or a custom `.regularMaterial` capsule overlay; SF Symbols for icons (`chart.bar`, `list.bullet`, `checkmark.seal`, `slider.horizontal.3`) |
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

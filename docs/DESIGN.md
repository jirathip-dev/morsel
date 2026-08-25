---
version: alpha
name: Morsel
description: A readout, not a showcase. Morsel is a data store + read-only dashboard
  + agent skill (no chat). The UI renders what the agent wrote — source, confidence,
  unit, per-item macros — and surfaces a needs-review affordance for low-confidence
  estimates. Warm neutral ground, a single green accent for on-track/confirm, amber for
  calories, red for over-goal. Humanist sans for copy, monospace for the data vocabulary.
colors:
  ink: "#20231E"
  inkTwo: "#666A60"
  inkThree: "#9BA095"
  bg: "#FBFAF6"
  surface: "#FFFFFF"
  surfaceTwo: "#F3F1EA"
  line: "#E7E3D8"
  accent: "#1F7A48"
  accentSoft: "#E7F1E9"
  energy: "#D9792C"
  energySoft: "#F6E8D8"
  over: "#C0483F"
  low: "#8A5514"
  protein: "#C85A55"
  carbs: "#D98B2B"
  fat: "#5E8E82"
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
    textColor: "{colors.accent}"
    backgroundColor: "{colors.accentSoft}"
  tag-conf-low:
    textColor: "{colors.low}"
    backgroundColor: "{colors.energySoft}"
  btn-confirm:
    backgroundColor: "{colors.accent}"
    textColor: "#FFFFFF"
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
- **accent (#2E8C58)** — the *single* action/on-track color. Confirm buttons,
  "Looks right", streak, high-confidence tags, on-track ring fill.
- **energy (#D9792C)** — calories. Headline kcal numbers, the ring when you're
  nearing goal, the "verify" affordance.
- **over (#C0483F)** — only when eaten exceeds goal.
- **Macro colors** — protein rose (#C85A55), carbs amber (#D98B2B), fat sage
  (#5E8E82). These are the only colors beyond the green/amber system.
- **Neutrals** — bg (#FBFAF6), surface (#FFFFFF), surfaceTwo (#F3F1EA), line
  (#E7E3D8), inkTwo/inkThree for muted and faint text. Hairlines, not shadows,
  carry separation.

Color is discipline: one accent, one calorie color, one danger state. If a new
color is needed for a new meaning, that meaning belongs in the token table
first, never as an ad-hoc hex in a component.

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
- **Tag** — monospace, 5px radius, surface bg + hairline border, inkTwo text.
  `tag-conf-high` (accent on accentSoft), `tag-conf-low` (low on energySoft).
- **btn-confirm** (accent, white text) and **btn-ghost** (surfaceTwo, inkTwo) —
  40px tall, 8px radius. Confirmation is the high-emphasis action; there is
  exactly one confirm per correction card.
- **row-low** — the low-confidence item row (energySoft tint, 6px radius). It
  must always carry a `verify` tag so the tint is never the only signal.
- **Review card** — `// agent: <reason>` note in mono plus editable kcal/P/C/F
  fields (mono inputs on surfaceTwo) with `Keep guess` (ghost) and `Looks right`
  (confirm). Confirming flips the confidence tag to `1.00` high.

## Do's and Don'ts

**Do**
- Show exactly what the agent wrote: source, confidence, unit, per-item macros.
- Make the trust affordance (needs-review / verify) a first-class element.
- Use mono only for data vocabulary; use tabular numerals for all numbers.
- Keep ONE accent (green) and ONE calorie color (amber); red only for over-goal.
- Separate with hairlines and tints, not shadows and decorations.

**Don't**
- Don't build a chat UI, a feed, or any in-app AI surface — out of scope by design.
- Don't add a fake phone bezel, fake status bar, or mock OS chrome.
- Don't reach for a card-per-thing or a 3-feature grid; the day is a log.
- Don't invent colors ad-hoc — add the token, then use it.
- Don't decorate low-confidence with an accent rail or an icon; a tint + `verify`
  tag + the reason is the honest treatment.

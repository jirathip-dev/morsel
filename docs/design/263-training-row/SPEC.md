# #263 — Half (a): Today row and Training day sheet

PROTOTYPE — awaiting owner review. Decisions in #263 remain FINAL. This document specifies their execution, not alternatives to policy. Half (b), the exhaustive app-wide numeric-voice before/after gallery, is deliberately NOT included in this first gate.

## Scope and authority

- Product base: `2d87d61e73c6c3db7bd1420294ccf1551232405d`, `design/263-training-row-numeric-voice`.
- Approved visual control: Variant A, product commit `68be41d1f3e3fdabcfe28efab79e7c4a2879377b`, original `docs/design/tactile-journal/`. Byte-exact controls are retained in `baseline/`; art/font provenance in `references/asset-lock.json`.
- Final requirements: `sources/issue-263.json`; lane brief ends delivery after half (a) for owner review.
- Current policy/copy: `TrainingFuelViews.swift`, `TrainingFuelModel.swift`, `TrainingFuelContext.swift` at the stated base. `sources/` retains exact snapshots and inventory.
- No source changes, no product builds, no DB calls, no native navigation changes. Browser specimens are not screenshots of a shipped app.

## Surfaces and composition

Today = Monitor. It needs one legible answer and one entry point.
Sheet = Configure. The user authors a date-owned addition, explicitly confirms it, or undoes it.
Gallery = Compare. It is review tooling, not proposed app chrome.

Both compositions keep the approved A language: continuous journal paper, date gutter, fine ink rules, Caveat headings, Garamond body, understated existing A illustrations, no stock cards/shadows. Existing food/hero/macro numeric typography stays Plex in this round. The new row and new sheet use Garamond body figures with tabular lining features; this local component proposal is NOT the app-wide migration.

### A — Open journal (recommended)

A ruled, unfilled target row under the calorie readout. The sheet uses a wide underlined writing field with the unit visibly adjacent; confirm/cancel share a horizontal action group. Reading name and value share a line; source/sample/checked lines follow underneath. Best hierarchy for blank-first authorship and honest metadata; fewer nested enclosures.

### B — Ruled form

Same row content, location and behavior, set on the existing field tone. The sheet pairs the amount label with a bounded input on one ledger line, stacks confirm/cancel, and pairs each reading’s title/value column against its source/time column. More compact horizontal information organization; narrower entry and metadata columns trade off against the calm reading rhythm of A. It is not a palette variant.

Neither variant changes policy or section order. Owner chooses the composition at this gate; no claim of approval.

## Today row contract

Exactly one effective-calorie-target statement, one focusable button, full-row hit region ≥44pt:

| Data | Visible string |
|---|---|
| readable baseline, no confirmed addition | `Usual day · 2,126 kcal` |
| readable baseline + confirmed user-authored example addition | `Training day · 2,426 kcal` |
| target unavailable | `Usual target · unavailable` |

The example total uses the owner’s example numbers. The blank first-entry field never contains 300 or another preset. The `valid-draft`, confirmed and pending fixtures describe a fictitious user who typed 300; they are not a recommendation, inferred bonus or default.

The row always opens the same Training day sheet, including when unavailable. A trailing chevron is subordinate; the text communicates state without color. Undo never appears on Today.

Remove the current TrainingFuelSection/TrainingFuelReceipt text stack from Today: Movement, Workout, timestamps, source/provenance, About disclosure, longer-day toggle, helper lines, duplicated receipt, and undo. To satisfy the literal “exactly one target statement”, move the hero’s explicit calorie goal/provenance out of the hero; the hero retains Eaten and the existing comparison ring, whose denominator is the same effective target. Do not add another target or repeat it as a receipt elsewhere on Today. Macro targets are unchanged and are not calorie-target statements. The existing food readout and illustrated log remain; no new navigation or calendar behavior is specified.

Unreadable goal: no fallback to another day, zero, or a guessed value; no meaningful ring progress when a denominator is unavailable. Known zero food intake is different from unavailable food intake. Partial meal nutrition has no fabricated daily total.

## Sheet structure — exact order

One vertically scrolling sheet; native drag/dismissal conventions in eventual SwiftUI implementation. HTML uses a modal dialog with focus containment, Escape dismissal and focus return. Sheet header: date context, “Training day”, 44pt Close. No second nested sheet.

1. Today's answer
   - `Usual target` and provenance. “computed” occurs only here and never on Today. Baseline provenance is an existing read, not a new calculation.
   - “For a longer or harder session, enter an addition from your own plan.”
   - Label `Add for this day`, empty amount field, `kcal` unit. Placeholder `Your amount`, never a number.
   - `No amount suggested. This screen cannot assess adequate fuelling.`
   - When relevant, unchecked consent: `I choose a day-only change; keep my saved manual goal.` It is required for each confirmation and reset on edit/reopen.
   - Explicit `Confirm for this day` / `Cancel`; failure changes confirm to `Retry confirmation`.
   - Confirmed mode: the exact authored addition, this-day-only scope, `Edit amount`, `Undo adjustment`. No three-line duplicate receipt.
   - Session-local / not-synced status and unchanged saved goals/macros remain visible.
2. Readings
   - Movement and Workout remain separate named readings; no sum and no subtraction from food intake.
   - Each readable value has source, actual sample date/time and checked date/time.
   - Older samples: `Last known · not today’s total`, the real earlier sample date, and the separate current checked time. Never relabel as today’s measurement.
   - Missing/no readable data: Unavailable, never `0 kcal`. A genuine zero is shown as zero.
   - HealthKit does not reveal denied read permission reliably: the denied simulation intentionally uses the same honest no-readable-data presentation as missing data. It does not assert known denial or imply a rest day.
   - Read failure is explicitly named; an in-flight read says reading, not a value or completed check.
3. About this context
   - All caveats in `sources/copy-inventory.md` are retained, including movement overlap, sampling vs checked time, missing Health not meaning rest, no fuelling adequacy assessment, professional guidance and local-only scope.
   - `Read Apple Health` is here only. Prototype click simulates a read; it never requests permission or data.

## State and transition contract

- Baseline `B`, nullable confirmed addition `A`, draft `D`. Effective target is `B + (A ?? 0)` only when B is available.
- Draft is not confirmed state. No typing, checkbox, Health read or view opening changes the target.
- New entry is blank. Edit may show the user's existing confirmed amount; that is not a suggestion.
- Technical validation: finite positive number and finite sum; allow decimals, no clinical upper bound. This English prototype accepts a decimal point and rejects commas rather than silently reinterpreting a grouped amount. Positive fractions are not rounded to two decimal places. Production locale parsing remains the native formatter’s responsibility. Zero/removal goes through Undo. No negative reductions or inferred calculation from Movement/Workout.
- Disabled confirmation is explained by blank field, field error, missing target, pending operation, or required unchecked manual consent. Error copy is inline, not a toast.
- Confirm freezes the draft during the pending operation and keeps the previous target. Completion changes the row exactly once. Edit replaces the previous addition rather than stacking it.
- Cancel, Close and Escape invalidate an in-flight operation; late completion must not apply it. Failure retains the entered draft and prior confirmed target; retry is explicit.
- Undo is sheet-only; clears only the date-owned addition, preserving baseline, meals, macros, Health context and saved manual goal. Row returns to Usual day after a successful undo.
- Date/time-zone/account lifecycle remains source-owned. The prototype exercises an in-flight date rollover invalidation; no old addition may leak onto a new date. A new baseline is not synthesized. New observation of today's baseline preserves a confirmed addition, per current model; a no-goal queued meal is not an instruction to erase a previously known baseline.
- Empty, loading, degraded/cached, error, multi-meal and partial-nutrition contexts do not create new target rows. Full list and exact specimen links: `STATE-MATRIX.md`.

## Design system and accessibility

- Palette is byte-pinned to approved A (Paper/Night): Paper page #FFF7E8, ink #2A261F, secondary #655A4B, field #F2E9D9, inkline #8B7355; Night page #2A261F, copy #FFF7E8, secondary #F2E9D9, field #423B31, inkline #9D917F. Action #E66A2C with dark #2A261F text, never white.
- Type: bundled Caveat 34–40 display, Garamond body 17–20, small metadata 14–15, amount 26 (A) / 23 (B); new figures `tnum` + `lnum`. Existing food/hero metrics retain their approved mono roles pending gate (b).
- Spacing: 8/12/16/24; journal left gutter retained. Sheet padding 24, 20 on narrow widths. Controls ≥44 CSS px at 390×844 and 320×740, measured by browser gate.
- Radius: field 4, action 6, sheet 12; no new shadow system. Rules, not card stacks, divide sections.
- Focus visible; full-row access; labeled amount with error/hint linkage; alert vs status; modal focus containment, Escape and return focus. Initial focus is Close, not an automatic software keyboard.
- No animated treatment; Reduce Motion remains static. This does not propose a change to approved native page flips.
- Native Dynamic Type, VoiceOver, keyboard viewport, drag-to-dismiss and actual device interaction require later native verification. Browser dimensions are CSS pixels, not a device certification.

## Separate gates and explicit limits

Half (a): these candidates, both themes, interactions, state matrix, copy inventory, live gallery, recommendation and spec. STOP here for owner review.

Half (b): subsequent exhaustive inventory and before/after gallery for every affected surface and kept technical mono roles, both themes, with owner approval BEFORE any numeric implementation lane opens. No implementation lane was opened. `alignment.html` is only an enabler witness, not that gallery. No selective before/after sample is represented as exhaustive.

`tnum` and existing `.monospacedDigit()` evidence is real source/font evidence; actual tabular rendering is independently measured in the browser. Native SwiftUI use of those features is not proven by HTML.

Current source is explicitly session-local P1 even though the server dated-target contract exists separately. This round retains the source’s honest local-only copy; it does not silently wire persistence, promise sync, or settle #226 P2/P3. A persistence cutover would require its own verified integration and truthful copy update.

Unresolved: owner selection of A/B; later gate (b) review; native device HealthKit/permissions and accessibility acceptance. No locked product decision is reopened.

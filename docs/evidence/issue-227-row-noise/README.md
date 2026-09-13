# Issue #227 — food-row noise removed; confidence/provenance live in the food sheet

Owner-approved UX refinement: food rows carry only the illustration (#223), the
food's name, its portion/macros and kcal; the row confidence box, the
manual/source label, the verify pill, the review-only tint and the entire
"Needs review" section are retired. The individual food sheet ("Edit item") now
exposes source, confidence, the low-confidence cue and agent estimation notes in
a compact secondary `DETAILS` area, with the shipped edit/save behaviour intact.

## Captures (simulator, not device)

Produced by the native test
`app/Tests/MorselTests/RowNoiseRegressionTests.testPhoneSizedPaperAndNightCaptures`
on the iPhone 16 simulator `59DDC0C5-891E-4EC0-91AF-4F50DF68D793`
(390×844 pt page, 390×1200 pt sheet; PNGs at @3x). The test writes them to
`/tmp/morsel-227-evidence/` and the lane copies them here.

| file | state | what it shows |
|---|---|---|
| `before-issue-227-today-row-paper.png` | base `b5b2f52` | the noisy row: `photo_vision`, `0.42`, `verify`, the accent tint, and the duplicated "NEEDS REVIEW" card |
| `after-issue-227-today-row-paper.png` | head | clean row: illustration + `jasmine rice` + `120 g · P3 C34 F0` + `156 kcal`; goal `source: manual` under the ring is kept (unrelated label) |
| `before-issue-227-food-sheet-paper.png` | base | sheet shows only the source line under "PROVENANCE" |
| `after-issue-227-food-sheet-paper.png` | head | `DETAILS`: `source: photo_vision`, `0.42`, `low confidence` tag, `// agent: agent estimate: about 1 cup`, plus Cancel/Save |
| `…-night-ink.png` | both | the same pair in the Night theme |

Theme grounding was verified on the raw PNGs (corner pixel of the page/sheet
ground): Paper `(254, 248, 234)` ≈ `#FFF7E8`, Night `(41, 38, 31)` ≈ `#2A261F`.

## How the before/after pair was produced

* after — the lane worktree (`issue/227-row-noise`) at the head commit.
* before — a detached scratch worktree of the pre-change base
  (`git worktree add --detach /tmp/morsel-227-red b5b2f52`) carrying ONLY the
  new regression suite (the suite compiles at base). The same capture test ran
  there: `/tmp/xc-dd-227 … -only-testing:MorselTests/RowNoiseRegressionTests`.
  Raw RED exit: `red_exit=65` — 6 tests, 13 failures (see the lane report).

## Verification (raw exits in the lane report)

* `RowNoiseRegressionTests` renders the REAL page/sheet and compares painted
  output: the page is pixel-identical for normal, low and missing confidence;
  the sheet paints differently when (and only when) source, confidence or agent
  notes change; the row measures 82 pt tall (base: 104.67 pt, i.e. the retired
  44 pt pill line is gone) and spans the full phone width as the sheet entry.
* `JournalHitRegionTests` retargets the retired review pill's measurement to the
  food row itself (full-width sheet entry, ≥44 pt tall).
* `JournalInteractionOwnershipTests` already pins the shell-owned presentation
  chain (one sheet, no duplication, dismissal clears it).

## Lane run record (iPhone 16 `59DDC0C5-891E-4EC0-91AF-4F50DF68D793`)

* Native suite HEAD: **322 tests, 0 failures** — `xcodebuild test` (exit 0) split
  into two invocations because the documented fresh-sim `GoalsPolishTests` wedge
  froze two full-suite attempts mid-class (log frozen >2 min, app process ~0%
  CPU; killed): `-skip-testing:MorselTests/GoalsPolishTests` ran 317 tests
  (exit 0, includes all 6 `RowNoiseRegressionTests`) and
  `-only-testing:MorselTests/GoalsPolishTests` ran 5 tests (exit 0). Union = 322.
* RED at base `b5b2f52` (same suite, scratch worktree): exit 65 — 6 tests,
  13 failures, all behavioural (page pixels differ for low/missing confidence,
  the sheet paints identically with/without confidence and notes, the row
  measures 104.67 pt, the retired symbols are still present).
* `npm test` HEAD: exit 1 with **0 AssertionError** and 10
  `Test timed out in 5000ms` failures in `server/http.test.ts`,
  `server/render-png.test.ts`, `server/tool-classification.test.ts` (host load);
  the three files pass 12/12 in an isolated
  `npx vitest run --testTimeout=60000` run (exit 0).

## Known limits (disclosed)

* The unit bundle cannot synthesize touches and vends 0 accessibility elements
  in-process (#174/#177), so the "full-row tap" is proven as the measured
  full-row target plus the row's exact activation closure
  (`onEdit(item)` → `JournalPresentationModel.requestEdit`) driven through a
  mounted shell that really presents the sheet's `PresentationHostingController`.
  The UIKit chain's post-dismissal emptiness is not observable in that mount
  within a bounded wait; the request state is asserted instead, and the shipped
  ownership suite pins the chain itself.
* `MealThumbnailView`/`MealThumbnailLoader` (dead since #223 removed their only
  production call site) and their loader-transition test were retired; the live
  photo path (`MealPhotoEditorSection.existingPhotoRow` →
  `repository.loadMealImage`) is untouched.
* The stale `FoodArtworkView.swift` comment that still names `MealThumbnailView`
  was left alone: that file is outside this lane's fence (#223/#229 surfaces).

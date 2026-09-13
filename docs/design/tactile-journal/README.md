# Morsel #228 — tactile journal comparison

Status: DESIGN HANDOFF — awaiting Guy's selection. Not shipped, not implementation approval.

## Open the previews

- [A / refined ink-wash](a.html) · [A Night](a.html?theme=night)
- [B / simplified tactile](b.html) · [B Night](b.html?theme=night)
- [Side-by-side interactive comparison](index.html) · [Night comparison](index.html?theme=night)
- [Paper PNG](evidence/comparison-paper.png) · [Night PNG](evidence/comparison-night.png)

Live gallery: https://jirathips-macbook-air.tail8c3301.ts.net:8444/morsel/228-tactile-journal/index.html
Archive: https://github.com/jirathip-dev/design-output/tree/main/morsel/228-tactile-journal

Open direct A/B links on a phone. The comparison uses tall 390-wide contexts to show all five food rows; the individual evidence PNGs use 390×844. Vertical scrolling is intentional. The fixed navigation clears the final row when scrolled. No horizontal overflow was measured at 390 or 320 CSS pixels. The explanation below the list may need scrolling, even in the tall comparison.

## Recommendation: B, with the compactness trade-off acknowledged

Choose **B's larger, simplified food silhouettes and deliberate row spacing**. At phone scale the meat slices and vegetable cluster separate more clearly, and the artwork contributes to recognition rather than just decorating a label. Keep the established journal furniture and fixed numeric column.

A is the conservative alternative: lighter layered pigment, selective fine ink, a smaller art slot and tighter rows. It exposes more entries before scrolling and stays closer to the quiet existing art treatment. B uses broader opaque shapes and less fine edge work. Both are original representative studies, not a replacement catalog. The difference is intentionally concentrated in the row/art treatment, not a full reskin.

Exact-food recognition is not proven by illustrations alone: stracciatella can read as generic soft cheese, and focaccia as bread. Labels remain essential. No blinded recognition/user study was run. The designer's recommendation is supported by a visual inspection, not a measured usability win.

## Fixture and unchanged semantics

`fixture.json` is the readable fixture; `fixture.js` is its deterministic browser form. All foods, nutrition, confidence values, goals, and date/time are fictional. The food names mirror the requested lunch, not an authenticated owner record.

| Food | Portion | kcal | P / C / F, g |
|---|---:|---:|---:|
| Focaccia bread | 100 g | 300 | 8 / 46 / 9 |
| Mortadella | 40 g | 125 | 6 / 1 / 11 |
| Stracciatella cheese | 50 g | 130 | 5 / 2 / 11 |
| Grilled vegetables | 80 g | 70 | 2 / 8 / 3 |
| Unidentified side | 1 serving | 90 | 2 / 10 / 5 |

Food sum = 715 kcal, goal = 2000, remaining = 1285. Macros = 23 / 67 / 39 g. Calories are the recorded item values, not recomputed from rounded macros. Demonstration edit changes focaccia from 300 to 320: eaten becomes 735, remaining 1265, macro totals unchanged. No activity is added to the food goal or subtracted from intake.

The Movement + exercise region is a small unavailable-context line with extensible block layout. #226 remains parked: no training-day suggestions, confirmations, adjustments, formula or adequate-fuelling claims were designed. Goal provenance remains in the summary. #223/#227 override older DESIGN.md row-review guidance: rows are always original illustrations, no row confidence/source/manual/verify copy, no Needs Review section. Detail preserves source, confidence and notes; the vegetable fixture has missing notes, and unknown/cheese demonstrate lower confidence without row warning tint.

## Exactly two product flows

1. Full-row tap → detail, with close/cancel as part of the sheet flow. Entire rows are native HTML buttons with food/portion/calorie accessible names and dialog semantics. Focus returns to the originating row.
2. Edit calories → save → updated row, with an inline “Updated in this prototype only · not saved to server” confirmation. Other edit fields and other app navigation are intentionally not implemented.

Top add/settings and Today / History / Goals are inactive context, not extra prototype workflows. Theme, failure and motion links live in the external review wrapper, not proposed in-app controls.

| Scenario | URL suffix | What to exercise |
|---|---|---|
| Normal local demonstration | `?theme=paper` or `?theme=night` | Open any row, edit calories, save |
| Detail pending | `&scenario=open-pending` | Tap a row; pending remains until closed |
| Detail failure | `&scenario=open-fail` | Tap a row; error, no editable detail, unchanged row |
| Save pending | `&scenario=save-pending` | Save an edit; disabled save, original row retained |
| Save failure | `&scenario=save-fail` | Save an edit; failure keeps draft and original row |
| Forced Reduce Motion | `&rm=1` | Immediate/no-transform sheet and row response |

Normal entry has a deliberately visible 240 ms prototype delay; save has 900 ms. These are simulated state-demonstration delays, not backend latency or performance claims. Pending states never assert success. Failure leaves the editable draft intact. Closing cancels outstanding timers. Retry in a forced-failure URL intentionally fails again. Reload resets all edits. There are no fetches, browser storage, backend calls or user-data writes.

Motion posture: 100 ms row press treatment, 140 ms sheet entrance, no loops/confetti/reward animations. System `prefers-reduced-motion: reduce` removes animations/transforms; static status text still conveys progress and errors. Real device haptic/latency behavior is unverified.

## Small design system

Preserved source tokens and original brief are in `references/`. Paper/Night colors come from the approved token map; orange actions keep dark ink labels. Caveat headings, EB Garamond names/body, IBM Plex Mono figures are bundled with OFL notices. Hairlines, margin spine, orange empty-centered calorie ring, adjacent eaten/goal readout and three macro strips retain Morsel vocabulary. No new card system, stock UI kit, elevated stacks, invented palette or layout gradients.

A uses 56 px art slots and minimum 87 px rows; B uses 70 px slots and minimum 100 px rows at 390 width. Names 18/19 px; row macros 12 px; portions 11 px; calories 14 px. At 320 width slots compact to 52 px and macro text 10 px. This narrow fallback passes containment, but compact text still merits physical-device readability review. Fields/close/save targets are at least 44×44. Thin separator rules are decorative; important text and marks have measured contrast in `evidence/audit.json`.

## Original art and photo provenance

`generate.py` contains the authored, editable vector paths. Five subjects × A/B × Paper/Night produce 20 local 256-viewBox SVG files. No tracing or copying from the inspiration game, no external stock illustration, no per-log generation. Lightweight pigment layers and selective contour strokes stand in for heavier noise/filter rendering. Shipped `app/Resources/FoodArt/` and approved `docs/art/food-library-v2/` were not changed. These studies and the neutral bowl fallback require separate approval before any catalog adoption.

Only the detail-photo fixture uses a third-party **photograph** (not illustration art):

- “Focaccia with Crumb,” Fred Benenson, 6 September 2020.
- Source: https://commons.wikimedia.org/wiki/File:Focaccia_with_Crumb.jpg
- License: CC BY-SA 4.0, https://creativecommons.org/licenses/by-sa/4.0/
- Downloaded Wikimedia thumbnail: https://upload.wikimedia.org/wikipedia/commons/thumb/b/bf/Focaccia_with_Crumb.jpg/960px-Focaccia_with_Crumb.jpg
- Stored locally as `assets/fixture-photo.jpg`, displayed proportionally, no image edits. License applies to this photo, including its appearance in screenshots; author/source/license are retained here and the detail includes a short credit.

The same meal-level public photo is accessible from known lunch item details, explicitly labeled as meal-level, public demonstration—not item evidence or the owner's lunch. The unknown side is the no-photo case. This demonstrates the stored-photo presentation path without claiming a real Supabase attachment, reading an owner account or fabricating signed URLs.

## Reproduce, lightweight only

Prerequisites: existing Node with built-in WebSocket/fetch (this run: v26.7.0), Python 3 stdlib, and an **already-running isolated Chrome CDP endpoint**. This run used existing HeadlessChrome/151.0.7922.34 at `http://127.0.0.1:9333`. No browser installs/startups, dependencies or native builds are performed by these scripts. Override `CDP_URL` if the owner provides another endpoint. If unavailable, stop; do not install a browser.

From this directory:

```sh
bash reproduce.sh
```

Exact worktree command:

```sh
cd /Users/jirathip/.herdr/worktrees/morsel/design-tactile-journal/docs/design/tactile-journal
bash reproduce.sh
```

Individual executed gates:

- `python3 generate.py` — exit 0, fixture + HTML shells + original SVGs.
- `node verify.mjs > evidence-run.log 2>&1` — exit 0, **134 browser checks**, **34 PNGs**; one owned tab, serial mouse/input events, closed on finish. Captures main, known detail/photo, unknown detail, save pending, local updated, save failure, open failure and reduced-motion detail across A/B × themes, plus two comparisons.
- `node verify.mjs --comparison-only > comparison-run.log 2>&1` — exit 0; corrected the comparison capture height to include both nav bars. Does not overwrite full interaction results.
- `python3 audit.py > audit-run.log 2>&1` — exit 0; **113 static checks**, generator byte reproducibility, PNG dimensions, contrast and manifest.
- `python3 audit.py --check-manifest` — verify exact delivered bytes without rendering.
- `git diff --cached --check` — scoped whitespace gate before commit.

`reproduce.sh` captures each raw exit and duration in `gate-exits.json`. Sources/generated vectors are byte reproducible. Screenshot state/layout is reproducible with the recorded fonts/browser; pixel hashes are not promised across browser engines/platforms, and pending-state captures are not a performance measurement.

## Verified / deferred

Verified: all five row targets in all four variants; source/confidence/missing-notes/unknown detail; real local demo image loading only inside detail; pending distinction; actual input/save and failure with unchanged old row and retained draft; updated totals and row focus; system reduced-motion opening/save with no active animations; 390/320 containment and 44 px controls; no runtime errors; no HTTP requests during browser exercise. Important text contrast minimum 4.631:1 (orange ink label); tested important mark minimum 3.830:1. No texture under UI text alters those pairs.

Visual review: Paper comparison, Night comparison and Night failure detail inspected. Larger B silhouettes read more clearly; cheese identity remains label-dependent. The first pass found small numeric secondary copy (enlarged) and a meal-specific folio alongside day totals (changed to FOOD JOURNAL). Interaction testing found the lowest row could be obscured by fixed nav when programmatically scrolled (added scroll margin and reran). A file-origin iframe inspection limitation was fixed in the verifier with explicit iframe load signals, not browser security flags.

Deferred/unverified: actual SwiftUI render, iOS Safari behavior, VoiceOver and Dynamic Type, physical-device text readability and tactile latency, authenticated photo storage/readback, backend pending/error behavior, blinded food recognition, native contrast-over-grain and heavy render proofs. No native builds or heavy renders were run under this admission exception.

## Ten-tell self-audit

1. Generic default typography: no; bundled product families and data hierarchy.
2. Arbitrary accent/gradient: no; locked Paper/Night tokens, orange only in known roles.
3. Hero + three cards: no; continuous operational journal and measured-data strips.
4. Decorative icon clutter: no; representative food studies and existing context chrome only.
5. Pill/badge proliferation: no; row confidence/provenance/verify intentionally removed.
6. Shadow/glass stacks: no; flat journal rules, one native-like sheet.
7. Fake social proof/metrics: no; all numeric fixture data explicitly fictional, no effectiveness claim.
8. Repetitive marketing blocks: no; one meal ledger, not a content funnel.
9. Performative motion: no; short optional press/entry, static RM alternative.
10. Generic symmetric dashboard composition: no; asymmetric spine, shared journal hierarchy, row-scale comparison only. The wrapper pairs A/B because comparison is its purpose.

Stop here for owner selection. No #226 workflow continuation, catalog expansion or native implementation is authorized by this handoff.

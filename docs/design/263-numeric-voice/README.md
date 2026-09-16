# #263 half (b) · numeric voice before / after

PROTOTYPE — awaiting owner review. Browser gallery delivered; the required native SwiftUI alignment proof remains **UNVERIFIED** under the brief's no-Swift fence. This is not a completed native acceptance gate and does not authorize implementation.

Live gallery: https://jirathips-macbook-air.tail8c3301.ts.net:8444/morsel/263-numeric-voice/index.html

Archive: https://github.com/jirathip-dev/design-output/tree/main/morsel/263-numeric-voice

Canonical path: `/Users/jirathip/design-output/morsel/263-numeric-voice/`

Product evidence path: `docs/design/263-numeric-voice/` on `design/263-numeric-voice`.

## What is here

A Compare surface: 36 source-derived HTML excerpt pages, each captured before/after in Paper and Night. The intended delta is only the font family: IBM Plex Mono → bundled EB Garamond at the same sizes/nominal weights, with tabular lining figures. No product UI or policy is implemented. All numerical records are fictional specimens.

| Coverage group | Pages | Phone captures |
|---|---:|---:|
| Headline figures | 2 | 8 |
| Rows / columns / folios / peripheral labels | 12 | 48 |
| Weight / chart labels and receipts | 4 | 16 |
| Calendar | 1 | 4 |
| Goals / shared forms / current training amount | 4 | 16 |
| Meal capture / photo / edit / menu | 9 | 36 |
| Kept-mono technical strings + named wordmark exception | 4 | 16 |
| Total | 36 | 144 |

Additional evidence: 8 rendered alignment proofs, 2 gallery captures, 14 native-size group contact sheets and 18 native-size review plates covering all phone captures. Counts are generated in `evidence/counts.json`; file totals come from audit.py, not these presentation counts.

The issue's six-group wording is normalized by separating chart labels from rows/columns; kept mono is separate. Source sweep: 72 font-use/field-binding lines across 22 files; 69 map to visible specimens, 3 are explicitly excluded (unused generic tag; two SF Symbol font consumers). This includes all 59 font-use source lines independently discovered plus 13 numeric field bindings. Shared helpers and their reuse hosts are expanded in COVERAGE.md and the retained independent audit.

## Real execution

- Full browser gate: 1,493 checks, 154 captures, no runtime/console errors, no artifact HTTP requests.
- Independent rerender: 1,647 checks; all 154 PNGs byte-identical.
- Deterministic generator re-executed: all 40 emitted HTML/coverage files byte-identical.
- Kept technical/wordmark excerpt pixels are independently checked unchanged, excluding only the BEFORE/AFTER review header.
- Important-text contrast and exact source/asset/manifest integrity are measured by `scripts/audit.py`.

Browser alignment uses actual text DOM Ranges and platform-font readback, not a GSUB-table assertion or fixed-width grid. For digits 0–9 at 400 weight in Paper:

```text
size px   advance of EVERY digit (CSS px)   max-min
9         4.328125                          0
10        4.8125                            0
11        5.28125                           0
12        5.765625                          0
14        6.734375                          0
17        8.171875                          0
22        10.5625                           0
30        14.40625                          0
32        15.375                            0
```

Both themes, both 400/500 weights pass: maximum tabular spread 0 px. Minimum proportional-control spread 1.109375 px. Natural 11111 / 22222 / 88888 strings also measure equal widths. Raw results: `evidence/alignment.raw.tsv`, `evidence/alignment.json`; actual platform-font information is retained alongside measurements.

**This proves Chromium shaping only, not SwiftUI.** No Swift was authored/run, no native after-render was minted. The clarification request for an isolated native evidence probe was unanswered; LIMITS.md records the block rather than claiming SwiftUI supports or rejects the proposed feature.

## Review findings

The larger serif figures and 17/22 px fields sit naturally within the diary's existing type. At 9–11 px, the serif loses apparent weight and scanability compared with Plex, especially chart labels, macro columns and small validation copy. This is deliberately visible at the same source sizes, not hidden by a silent size/weight change. Owner review and eventual native/physical-device readability checks are necessary; no unconditional visual/native acceptance is asserted.

The old “30 px Goals gauge” is absent from the pinned base. Current Goals 22/17 px fields are shown instead. No fake missing gauge, hidden chart axis, native screenshot, account metric, source timestamp or photo was invented.

## Files to open

- `index.html` — theme/group browsing, before/after pairs, source links.
- `COVERAGE.md` / `coverage.json` — exhaustive discovered source set, exclusions, shared-host mapping.
- `LIMITS.md` — state list and every non-minted/native limitation.
- `DESIGN-SYSTEM.md` — locked context, semantic role split, scope boundary.
- `capture-verification.md` — visual dispositions and 10-tell self-audit.
- `REPRODUCE.md` — exact saved commands.
- `manifest.json` — SHA-256 and bytes for every bundle file except itself.
- `baseline/` — untouched approved A reference images, not new native captures.
- `history/` — retained earlier failed-probe evidence, superseded by final PASS reports.

Implementation remains gated on owner approval; native alignment remains an open verification requirement.

DESIGN ARTIFACTS ONLY; no app/DB edits; not merged; not opened as PR; no deploy.

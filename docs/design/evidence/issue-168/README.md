# Morsel #168 — Calendar-diary prototype (design-gate round 1)

Status: **PROTOTYPE — awaiting Guy approval.** Docs-only; no app code, no
product-repo changes.

Locked spec being designed (issue #168 comment, 2026-09-07):

- **B1** — past dates are FULL: browse + edit items + add a meal on any date.
- **B2** — swipe from Today flips days directly; a month grid lives in History.
- **B3** — month grid with meal-presence dots; tap a date to open that day.
- **B4** — in Today, **vertical** swipe up/down flips ±1 day (the #105/#111
  page-turn token, rotated) AND a calendar button in Today opens the same grid.
- **B5** — range is ALL HISTORY (as far back as data goes).

## What is here

Two self-contained HTML variants over the locked #90 journal identity
(same palette tokens, fonts, grain, margin/folio furniture):

| file | variant |
|---|---|
| `168-v1.html` | **V1** — month switch as segmented `aug / sep` hand tabs; frameless grid |
| `168-v2.html` | **V2** — identical grid in a slightly rotated hairline "specimen card" |

28 fixed-frame PNG proofs (`168-V<n>-<screen>-<theme>.png`, exactly 780×1688 =
390×844 @2x): today-day · today-empty · history-cal-aug · history-cal-sep ·
diary-sheet · addmeal-past · flip-mid × 2 themes × 2 variants.

## Routes

`?screen=<today|history|diary|addmeal|flip>&state=<default|empty|cal|cal-sep|mid>&theme=<paper|night>&motion=<off|fade|rich>`

- today+default → **Wed 5 Aug** (first logged day) rendered in the Today layout
  with date pill, prev/next flip arrows, calendar button.
- today+empty → **Tue 4 Aug** (before history): true empty page — zeroed ring,
  zeroed macros, plate illustration, prev-flip disabled (B5 boundary).
- history+cal → month grid state (B3); `aug`/`sep` tabs; `5 Aug – 3 Sep`
  range caption (B5).
- diary → the grid as a sheet opened from Today's calendar button (B4).
- addmeal → dated add-meal sheet for **Tue 4 Aug** ("Save to 4 Aug") (B1).
- flip → the mid-swipe state: yesterday's page lifting above today's (V1-style
  page-turn token, vertical) (B4).

Tap any calendar cell → the dated Today page. The dot legend reuses the
History ink families (under = forest, on target = mustard-deep, over = over-red).

## Deterministic generator

Fixture universe is the #90 one (`90-journal-redesign/tools/fixtures.py`) —
the calendar dots, the ledger numbers, and the weight chart cannot disagree.
Day A (5 Aug, 1,980 kcal) and day C (28 Aug, 2,410 kcal, five items) item
lists sum exactly to their ledger bars.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tools/build168.py     # deterministic HTML
PYTHONDONTWRITEBYTECODE=1 python3 tools/render168.py    # 28 proofs, 780x1688
PYTHONDONTWRITEBYTECODE=1 python3 tools/verify168.py    # gate + manifest
shasum -a 256 -c manifest.sha256                        # reproduce check
```

| tool | purpose |
|---|---|
| `tools/fixtures168.py` | #90 universe + month grids, diary days, self-checks |
| `tools/kit168.py` | #168 screens over the #90 builder (kit + CSS + router) |
| `tools/build168.py` | writes both variant HTMLs (byte-deterministic) |
| `tools/render168.py` | one chrome-headless-shell capture per proof |
| `tools/verify168.py` | spec markers, calendar geometry, PNG dims, red probe, manifest |

## Verify (gate) coverage

- Locked-spec markers: flip buttons, calendar button, month tabs, dots legend,
  dated add/save copy, all-history range caption, empty-state copy.
- Calendar geometry: 31 Aug + 30 Sep cells per grid surface (×2 surfaces,
  + ledger list rows), correct Monday-first lead blanks, exactly one
  `today` cell and two selected cells per surface.
- Text markers tag-stripped (mono-wrapped digits normalized).
- Forbidden strings (lorem/ipsum/raw hex/box-shadow/real names) absent.
- All 28 PNGs exactly 780×1688; no transient files.
- Red probe: marker + cell-drop mutations in memory are detected (gate bites).

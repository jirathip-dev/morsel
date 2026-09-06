# Issue #152 — named menus: native app evidence

Captured on a dedicated per-lane simulator (`Morsel152-iPhone16`,
UDID 628F850D-ADE4-4BCF-A719-630E4A80CFC0, iOS 26.5), unsigned Debug build,
light (Paper) theme, 1179x2556 px device pixels (@3x).

The capture used the repo's standard temporary `@main` harness pattern: a
throwaway `CaptureHarness152.swift` `@main` seeded a `MockDashboardRepository`
(three menus; one day with an "Eggs on toast" set + loose coffee + a loose
lunch) and rendered the production views directly, driven per capture by the
`MORSEL_CAPTURE152` launch environment (`today` | `picker` | `menus` |
`history`). The production `@main` in `MorselApp.swift` was suspended with a
`CAPTURE-HARNESS-ACTIVE` marker, the app was rebuilt, screenshots were taken
with `simctl io screenshot`, and the source was restored byte-identical to
the clean working state (verified with `cmp`); the harness file was deleted
before commit.

Screens:

- `mode-today.png` — Today journal: the breakfast meal renders the logged
  set as `Eggs on toast (set)` with nested `toast`/`eggs` rows, and the loose
  `coffee` item renders flat inside the same meal (A3 mixed composition).
- `mode-picker.png` — Add Meal sheet: the 'Log from menu' section lists the
  seeded menus with item/kcal summaries and per-row `Log` actions, plus the
  `Manage menus` row that opens the Menus screen route (A6 picker).
- `mode-menus.png` — Menus screen: `Your menus` list with name + item/kcal
  summary, `Edit` and delete actions per row, and a `New` header action
  (A6/A7 CRUD surface).
- `mode-history.png` — History day drill-down: the same snapshot grouping
  persists over time — `Eggs on toast (set)` header with indented set rows,
  loose rows at the margin (A4/AC4).

Totals shown (645 kcal = 120 + 90 + 5 + 430) match the seeded snapshot; the
drill-down card in the history capture is the real DayDrillDown view fed
through the real HistoryViewModel load/select path with the mock repository.

Gate evidence at the capture commit is in `.report.md` of the lane:
239 native XCTest green (suite split runs, see report), swiftlint --strict 0,
full `npm test` + `typecheck` + `lint` green, `git diff --check` clean.

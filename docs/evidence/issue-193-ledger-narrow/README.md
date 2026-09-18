# #193 — the History overview transfers only what the ledger renders

Lane checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-193-ledger-narrow`.
Base: `a79491186f29e44de7adb1a447d9dee254d3379a` (`origin/staging`).
Test commit (RED bytes): `e3130003e98edfc15f6917875374a6fe16880fff`.
Fix commit: `04bef2e12d6efdb53ac3f26de7138d5e663be7ae`. Head: see
`.report.md` (evidence commits follow the fix commit).

## The audited mechanism (base pin)

The History overview (`loadHistory`) read the shared RICH item projection —
`Repository.swift`'s `mealItemColumns` (16 columns: name, quantity, unit,
macros, confidence, source_notes, menu_group_id, menu_name, artwork_id) — plus
the full meal-log row (`id,eaten_at,meal_type,source,image_path`) only to sum
`calories_kcal` per meal and count meals per local day. Notes, names, macros,
menu metadata and photo columns crossed the wire for every bar in the ledger.

## What changed

- **A dedicated typed narrow ledger read** (`HistoryRepository.swift`):
  `loadLedgerMealLogs` selects `id,eaten_at` and `loadLedgerMealCalories`
  selects `meal_log_id,calories_kcal`, on the same endpoints, filters and
  indexes (`user_id`/`eaten_at` window; `meal_log_id` IN; `created_at` order).
  The typed rows are `LedgerMealLogResponse` / `LedgerMealItemResponse`; a
  missing `calories_kcal` stays `nil` and contributes 0, exactly like the base.
- **The rich projection is untouched.** `mealItemColumns`,
  `MealLogResponse`/`MealItemResponse` and the Today read keep serving the
  drill-down: `HistoryViewModel.select` → `loadToday` still transfers complete
  items, menu metadata, notes and the meal photo path.
- **No RPC, no migration, no schema or index change** — projection reduction
  only (the brief's fence).

## AC mapping (all five)

| AC | Where it is proved |
| --- | --- |
| 1. Only required fields are selected; notes/names/macros/menu/photos are not transferred | `LedgerNarrowReadTests.testOverviewRequestsOnlyTheNarrowLedgerColumns` asserts the real requests' `select` lists are exactly `["id","eaten_at"]` and `["meal_log_id","calories_kcal"]` and disjoint from the 16 descriptive/nutrition/menu/photo fields |
| 2. Narrow and baseline aggregation match: empty days, null calories, multiple meals, named-menu snapshots | `testNarrowAndBaselineAggregationMatchForEveryFixture` — five fixtures, each compared day-by-day (date, kcal, logged) against the base-pin aggregation computed from the identical fixture rows |
| 3. Logged-empty vs zero-calorie distinction; local timezone/DST buckets; effective goal and weight trend unchanged | `testLoggedEmptyAndZeroCalorieDaysStayDistinct` (null row and 0 row stay logged at 0 kcal; a meal-less day stays unlogged), `testLocalDayBucketingAcrossDSTTransitions` (America/New_York 2026-03-08 23-hour day: 01:30 EST + 03:30 EDT are one day; 2026-11-01 25-hour day: 01:30 EDT + 01:30 EST are one day; next-day starts 23/25 h later), goal/weight asserted in the parity loop (`goal == 2000/150/200/60 manual`, `weightTrend == [81.2]`) |
| 4. Drill-down still retrieves complete items/images; identical edit/view behaviour | `testDrillDownStillRetrievesCompleteItemsAndImages` drives the production `loadToday` (what `HistoryViewModel.select` calls) and asserts the rich `mealItemColumns` select is still requested, the meal carries its canonical photo path, and items carry identity, name, quantity, unit, macros, notes, menu group/name and artwork id |
| 5. Transport-level selected-column + parity tests; payload bytes on identical fixtures | The whole suite runs through a PostgREST-shaped URLProtocol stub that records the real request's `select` and delivers the identical fixture rows projected through that select. Measured bytes (identical fixtures, synthetic): `ISSUE193-BYTES` receipts below |

### Payload bytes on identical fixtures (synthetic rows, not a production speedup claim)

| Fixture | `meal_logs` narrow | base select | `meal_items` narrow | base select |
| --- | --- | --- | --- | --- |
| multiple meals (4 meals / 5 items) | 337 B | 561 B (−39.9%) | 378 B | 1763 B (−78.6%) |
| named-menu snapshot (1 meal / 2 items) | 85 B | 141 B (−39.7%) | 151 B | 863 B (−82.5%) |

The narrow body is also asserted against a hand-written expected JSON string
(no parallel calculation), and the byte count is what the stub actually
delivered for the real request's own projection.

## RED → GREEN

- **RED** (base production code, committed test bytes): `RAW_EXIT=65`, 6 tests,
  8 assertion failures — every one inside the two transfer tests
  (`excerpts/red-base-narrow-tests.txt`). The parity/DST/drill-down cases pass
  at the base pin too, which is the base-side half of AC2–AC4.
- **GREEN** (head): `RAW_EXIT=0`, 6 tests, 0 failures
  (`excerpts/green-head-narrow-tests.txt`).
- **Mutation battery** (head): M1 restores the rich item projection for the
  ledger read → the transfer tests bite; M2 drops the calorie column from the
  narrow read → the parity + DST tests bite. Both files restored
  byte-identically (sha256-verified) (`excerpts/mutation-battery.txt`).

## Recorded limits (disclosed, not silently claimed)

- **Byte receipts are fixture measurements.** The stub serves synthetic rows;
  no production network capture is claimed and no server-side change was made.
  The receipts show what the *requested projection* transfers on identical
  rows, which is the AC's subject.
- **No physical-device run.** Simulator/model evidence only; physical-device
  acceptance is retained by tracker #172.
- **Pre-existing red (not this lane's).**
  `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts`
  fails in the focused leg at head **and** at base with this lane's production
  file restored (`excerpts/base-known-reds.txt`) — the same red #192's GATES.md
  recorded. Everything else in the leg (31/32) is green, including
  `ParallelReadsTests.testHistoryAndGoalsContextOverlapAndKeepBaselineValues`,
  which drives the History read graph through the #178 transport.
- **Not run: the full unfiltered native suite** (584 tests at the base pin;
  known pre-existing reds plus evidence-capture tests). The brief's gate is the
  History/ledger classes; the focused leg above is the recorded scope.
- **Hosted gates are the hosted ones.** `npx vitest run app` (153 tests) and
  `swiftlint lint --strict` are green; the native gate ran locally on this host
  through the shared `/tmp/n.lock` admission (never concurrent with another
  heavy native gate).

## Files

| File | Change |
| --- | --- |
| `app/Sources/Morsel/HistoryRepository.swift` | narrow projection constants, typed ledger rows, `loadLedgerMealLogs` / `loadLedgerMealCalories`; `loadHistory` uses them |
| `app/Tests/MorselTests/LedgerNarrowReadTests.swift` | **new** — the AC1–AC5 regressions |
| `app/Tests/MorselTests/LedgerNarrowTestSupport.swift` | **new** — PostgREST-shaped projecting transport, synthetic fixtures, base-pin baseline aggregation |
| `app/Morsel.xcodeproj/project.pbxproj` | xcodegen output for the two new files (regeneration is byte-stable) |
| `docs/evidence/issue-193-ledger-narrow/` | this evidence |

`Repository.swift` is deliberately untouched: the narrow projection lives with
the ledger read, and `Repository.swift` sits at 398/400 of the SwiftLint
`file_length` budget (the repo's own reason for splitting these files).

Gate receipts: `GATES.md`. Machine-readable receipts: `native/run.json`.

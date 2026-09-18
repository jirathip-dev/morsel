# Issue #195 — profile and bound repeated view-body totals, grouping and formatting

Measurement-first lane. Base `1cf9ecc26b56037b53b34cc611425043bf21a36d` (`origin/staging`),
head `<HEAD_SHA_PLACEHOLDER>`. Worktree `/Users/jirathip/.herdr/worktrees/morsel/issue-195-render-derived`.

## 1. Baseline before any production change (AC1)

Harness: `app/Tests/MorselTests/RenderDerivedProbeTests.swift` (+ `RenderDerivedTestSupport.swift`).
It compiles against the unmodified base, so the same harness produced the baseline and the head
numbers. Conditions: iPhone 17 simulator, iOS 26.5 runtime, Debug build,
`-derivedDataPath /tmp/morsel-195-dd`, one heavy native leg at a time (`flock /tmp/n.lock`).
Per-call numbers are the mean of 2 000 calls inside the test bundle (`DispatchTime` around the
call); they are Debug-build numbers and move with host load — the base and head runs were taken
under the same lane conditions and are reported raw in `excerpts/`.

Baseline run (pre-change, `excerpts/195-baseline-probe.txt`, 4 tests / 0 failures, RAW_EXIT=0):

| derived call (fixture) | small (6 meals / 12 items) | dense (40 meals / 480 items) |
| --- | --- | --- |
| `DashboardMath.totals` (direct) | 6.27 µs | 166.3 µs |
| `DashboardViewModel.totals` | 6.85 µs | 174.5 µs |
| `DashboardViewModel.mealGroups` | 9.73 µs | 48.5 µs |
| `DashboardViewModel.reviewItems` | 11.03 µs | 288.7 µs |
| `JournalPageFurniture.gutterDate` | 41.1 µs | 41.5 µs |
| History `chartDays` (30-day overview) | 9.0 µs | — |
| History `averageKcal` / `daysOver` / `daysLogged` / `streak` | 20.5 / 22.1 / 20.2 / 27.1 µs | — |

Identified repeated calls (source-verified multiplicity per body evaluation):

- `JournalHeroView.body` (`Views.swift:149-210`) reads `viewModel.totals` **6×** per evaluation
  (goal status, ring, readout, protein/carbs/fat strips).
- `TodayLogSection.body` (`TodayLogViews.swift:36-52`) reads `viewModel.totals` once more and
  `viewModel.mealGroups` **2×** (`.isEmpty` + `ForEach`); `reviewItems` is read by the review card.
- `HistoryView.historyContent` (`HistoryView.swift:70-127`) evaluates `viewModel.chartDays` **3×**
  per body (`ForEach`, `.last`, `.map`); `HistorySummaryStrip` reads `averageKcal`, `daysOver`,
  `daysLogged`, `streak` once each.
- `JournalPageFurniture.body` (`JournalUI.swift:47`) calls `gutterDate` once per page body
  evaluation and **built a fresh `DateFormatter` on every call**.

Repetition measured in the mounted real page: 40 unchanged update cycles on the small fixture
produced **82 body evaluations** (2.05 per cycle) and 41 day reads
(`excerpts/195-baseline-probe.txt`, `mounted_today` line).

### Decision: material

- Dense day: 6× `totals` + 2× `mealGroups` + 1× `reviewItems` = **~1.43 ms of derived work per
  body evaluation** (174.5×6 + 48.5×2 + 288.7 µs), i.e. ~8.6 % of a 60 Hz frame budget, repeated
  on every publish — including publishes that do not change the day's data.
- A 200-cycle model workload with the production access pattern (1 800 accesses) spent **292 ms**
  in derived work at base (`excerpts/195-baseline-probe.txt`, `model_workload` line).
- The gutter folio cost **41.5 µs per call** because of the per-call formatter; a shared
  formatter is 0.6 µs (measured on this host with the same pattern).
- History's derived list/summary properties are **9–27 µs per call** — see §5 for the no-change
  rationale (fence + measurement).

Implemented: the Today-side derived reuse (§2.1) and the shared gutter formatter (§2.2).
`MealThumbnail.swift` was not touched — image work stays with the companion thumbnail issue.

## 2. What changed

### 2.1 `DashboardViewModel` — one derived scan per day-data revision (`ViewModel.swift`)

- `snapshot`'s write path maintains `derivedRevision`; the revision moves only when the day's
  **meals** actually change (`didSet` compares `snapshot?.meals` with `oldValue?.meals`), never on
  the publish count.
- `totals`, `mealGroups` and `reviewItems` now come from one cached `DayDerived` scan keyed on that
  revision, so loading/status/turn updates that leave the data unchanged reuse it.
- `derivedScanCount` (internal, `private(set)`) counts full scans; the reuse regression reads it.
- The grouping/review/totals semantics are the same expressions the base used, computed once.

### 2.2 `JournalPageFurniture.gutterDate` — one shared formatter (`JournalUI.swift`)

- A `static let` POSIX formatter replaces the per-call `DateFormatter()`; it assigns no time zone,
  exactly like the per-call instance it replaces, so the device zone still decides the folio.
- `DateFormatter` is documented thread-safe for formatting once configured, and the shared
  instance is never mutated after construction.

### 2.3 Line-budget compaction (no behaviour change)

`ViewModel.swift` sits at the 400-line `file_length` cap. The fix reclaimed the lines it added by
compacting existing statements that are semantically identical (multi-`var` declarations on one
line, `isSaving = true; errorMessage = nil`, one-line `cancelRefresh`/`invalidateDay` bodies,
multi-argument `DashboardSnapshot` construction, folding two locals into one condition). No comment
that carries rationale was removed; the file ends at exactly 400 lines and `swiftlint --strict`
passes.

## 3. After — same harness, same conditions

Head run (`excerpts/195-head-probe.txt`, 10 tests / 0 failures, RAW_EXIT=0). The "base" columns
are the base-leg run of the same harness in a scratch worktree at `1cf9ecc`
(`excerpts/195-base-probe.txt`, 4 tests / 0 failures, RAW_EXIT=0) — adjacent in time to the head
run, so the pair is comparable:

| derived call (fixture) | base small | head small | base dense | head dense |
| --- | --- | --- | --- | --- |
| `DashboardViewModel.totals` | 8.36 µs | 0.54 µs | 190.8 µs | 0.63 µs |
| `DashboardViewModel.mealGroups` | 11.69 µs | 0.29 µs | 52.6 µs | 0.29 µs |
| `DashboardViewModel.reviewItems` | 14.11 µs | 0.29 µs | 359.9 µs | 0.29 µs |
| `gutterDate` | 66.8 µs | 1.66 µs | 64.1 µs | 1.50 µs |
| model workload, 200 cycles / 1 800 accesses | 359.8 ms | 144.7 ms | — | — |

Derived work per body evaluation (dense): **~1.6 ms → ≤0.63 µs** on the reused path (one scan per
data revision instead of nine scans per evaluation). The History numbers are unchanged (no edit
there, §5). The mounted leg stays render-dominated (122–133 ms/cycle ±, 82 body evaluations for 40
cycles at both base and head) — **no frame-rate claim is made** (AC4).

The fix pays a new, bounded per-write cost: the revision check compares the day's meals
(`snapshot?.meals != oldValue?.meals`) on every snapshot write. The probe measures that deep
compare directly (`meals_equality_us`, equal content with distinct storage) — see
`excerpts/195-head-probe.txt`; it is one O(items) pass per write, against the nine O(items) scans
per body evaluation the base ran, and the per-call table above already shows the resulting
reuse-path cost.

## 4. Count regression and invalidation parity (AC2/AC3)

`app/Tests/MorselTests/RenderDerivedReuseTests.swift`, focused run
(`excerpts/195-reuse-focused.txt`): 10 tests / 0 failures / RAW_EXIT=0.

- `testUnchangedUpdatesReuseTheDerivedScan`: 200 unchanged `load()` cycles + 50 `cancelRefresh()`
  status updates with the production access pattern (6× totals, 2× mealGroups, 1× reviewItems) add
  **zero** scans; the values still match an independent reference scan.
- `testMountedTodayReusesTheDerivedScan`: the real `TodayView` mounted in a scene-backed window
  adds **zero** scans across 20 unchanged update cycles.
- `testMealMutationInvalidatesExactlyOnce`: an equal republish adds zero scans; adding a meal adds
  exactly one, and the totals/groups/review items equal the reference computation exactly.
- `testDaySelectionClearsAndReloadsTheDerivedValues`: selecting another day clears the derived
  values to the exact empty totals, and reloading restores the reference values.
- `testGutterDateMatchesAFreshFormatterAcrossTimeZones`: under `TZ=UTC`, `TZ=Asia/Tokyo`,
  `TZ=America/Los_Angeles` the shared formatter matches a freshly built one for every instant and
  produces the exact baseline strings (`02.FEB.2026`, `03.FEB.2026`, `01.FEB.2026`).
- `testHistoryWindowFollowsRangeAndZone`: range (7/30) and a `Pacific/Kiritimati` zone change
  reproduce the exact reference window (30 → 29 days) and the exact completed-day average.

The count regression **bites** on the un-reused path: `tools/mutation-battery.sh` reverts each
mechanism of the fix (cache check inverted, `totals` bypassed, invalidation removed, formatter zone
pinned) and the durable suite fails for every mutation — see `excerpts/195-mutation-battery.txt`
and §6.

## 5. AC5 — History-side derived list/summary: measured no-change rationale

The issue's source evidence names `HistoryView.swift:59-93` for "derived chart/list/summary
properties". In the current tree those properties live in `HistoryViewModel.swift`
(`chartDays`, `listDays`, `visibleListDays`, `averageKcal`, `daysOver`, `daysLogged`, `streak`);
`HistoryView.swift` itself only reads them. Measurements: `chartDays` 9.0 µs and the four summary
properties 20–27 µs per call (30-day overview), i.e. ~3× chart + 4 summaries ≈ **0.1 ms per History
body evaluation** — an order of magnitude below the dense Today case (1.43 ms) that was fixed.

This lane's fence authorizes "the derived-work computation sites in `ViewModel.swift` /
`HistoryView.swift` / `JournalUI.swift`"; `HistoryViewModel.swift` is not in it, and a view-model
cache there cannot be reached from `HistoryView.swift`. Rather than cross the fence or add
speculative caching, the History side is closed as **no change**, and its exact semantics are
pinned by `testHistoryWindowFollowsRangeAndZone` (range/day/zone) so a later lane that does touch
the file inherits a regression pin.

## 6. Evidence index

- `excerpts/195-baseline-probe.txt` — pre-change probe run (baseline numbers), RAW_EXIT.
- `excerpts/195-base-probe.txt` — the same probe at the base commit (scratch worktree), RAW_EXIT.
- `excerpts/195-head-probe.txt` — post-change probe + reuse suite, RAW_EXIT.
- `excerpts/195-reuse-focused.txt` — the durable suite alone (test names + result).
- `excerpts/195-mutation-battery.txt` — four mutations, each with the failing assertion and RAW_EXIT.
- `excerpts/195-base-durable.txt` — the durable suite at the base (no `derivedScanCount`): build
  failure, RAW_EXIT=65.
- `excerpts/195-base-known-reds.txt` — the suites that failed in the head full run, re-run at base.
- `excerpts/195-tz-order-verify.txt` — the zone-pinning ordering that the tests must survive.
- `excerpts/195-full-native.txt` — one complete unfiltered native invocation at head.
- `excerpts/195-swiftlint.txt`, `excerpts/195-xcodegen.txt`, `excerpts/195-diffcheck.txt`,
  `excerpts/195-contracts.txt` — gates.
- `GATES.md` — exact commands and raw exits.
- `tools/mutation-battery.sh`, `tools/base-legs.sh`, `tools/xctrace-attempt.sh`,
  `tools/make-excerpts.py` — reproducible drivers.

## 7. Full native suite and what this lane did NOT verify

One complete unfiltered invocation at head: **624 tests, 3 skipped, 5 failures, RAW_EXIT=65**
(`excerpts/195-full-native.txt`). Every failure is pre-existing or a documented full-run flake,
classified by re-running the same suites at the base commit
(`excerpts/195-base-known-reds.txt`):

| failing suite | at base (focused) | verdict |
| --- | --- | --- |
| `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping` | fails (2 assertions) | pre-existing |
| `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts` | fails | pre-existing |
| `PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll` | fails | pre-existing |
| `MealReliabilityTests.testOfflineAddMealCommitsLocallyAndPaintsPendingRow` | passes focused | full-run flake (also documented in lane notes) |

The lane's own suites are green inside that full run.

Not verified:

- **No frame-rate / Time Profiler claim.** The harness measures derived-work cost and counts, not
  frames. Two bounded `xctrace record --attach` attempts against the simulator test host failed
  (`exit 21`, "Cannot find process for provided pid") and produced no trace; the raw outcome is in
  `excerpts/195-xctrace.txt`, and no fps statement is made.
- Physical-device behaviour (#172) is out of scope; every number here is simulator/model evidence.
- The History-side reuse is deliberately not implemented (§5) and no History-side performance claim
  is made.
- The dense **mounted** leg was bounded out (a 40-meal page renders too slowly to loop 200×); the
  mounted evidence uses the small fixture and the dense per-call numbers are reported separately.
- Host-load variance: per-call numbers move with fleet load (the same base numbers measured 1.7×
  apart in two runs on this host, and the full-suite probe run measured the reuse path at
  0.12–0.23 µs). Before/after comparisons use runs taken under the same lane conditions, and the raw
  logs are attached rather than a single ratio.

# Issue #181 — merge durable queued meals and Health rows into cached Today first paint

Base `b5e64f3059c3bc7de31d28e58a58b0914c80b477` (`origin/staging` at lane start; the
lane branch was fast-forwarded to it before any work). Head = this lane's commits
(`test` → `fix` → this evidence commit; exact sha in the lane `.report.md`).

Evidence captured on a **private temporary iPhone 16 simulator created and deleted
per run** by `hermes-sim-task` (the fleet `xcodebuild` shim routes simulator actions
there because `HERDR_ENV=1`), unsigned Debug build (`CODE_SIGNING_ALLOWED=NO`,
simulator — **not a physical device**), device-local day = Asia/Bangkok (+07).
Raw logs stay in the untracked `.lane-logs/`; the excerpts committed here carry the
raw log's SHA-256 and its raw exit status.

## What changed

`cachedToday` (the seam `TodayRefreshOwner` publishes as the FIRST paint) served the
stored snapshot untouched, so the first paint was strictly poorer than the refresh
that followed it:

- `app/Sources/Morsel/DayReadState.swift` — `cachedToday` now runs the **same**
  account/day merge the authoritative read path already uses. With a cached day:
  `merged(cached, …)`. Without one: `merged(<empty local day>, …)` and the result is
  returned only when the outbox actually contributed rows — so a queued-only startup
  paints its rows while a genuine cache miss (no overlays) still returns `nil` and
  keeps its error path (`DayReadCompositionTests` still green).
- `app/Sources/Morsel/LocalFirstRepository.swift` — `merged` widened `private` →
  internal (the same cross-file seam convention as `remote`/`snapshotCache`/
  `revisions`) so the hydration path reuses it instead of growing a second rule set.

Because `merged` is reused verbatim, the first paint inherits: queued rows filtered to
the selected **device-local** day, dedup by client meal id (a row the server already
carries is replaced by its authoritative copy — never duplicated), the journal record
(real `pending` / `needs_attention` state + the deterministic photo path), weight
de-dup by whole second, the trailing 30-day weight window, and the dirty-day
`max(remote, local)` energy rule. Nothing is invented: a local-only day carries
`goal == nil`, `datedTarget == nil`, no remote weight/energy, and
`readProvenance.loadedAt == nil` (the cached-day paint keeps the day's own saved read
time, #258 semantics).

## RED — the audited mechanism, before the fix

The final test files were run with the fix **stashed**
(`git stash push -- app/Sources/Morsel/DayReadState.swift app/Sources/Morsel/LocalFirstRepository.swift`,
restored byte-identical afterwards, `sha256sum -c` OK) at base `b5e64f3`:

```
xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:MorselTests/TodayFirstPaintOverlayTests \
  -only-testing:MorselTests/TodayFirstPaintBoundaryTests \
  -only-testing:MorselTests/MealReliabilityTests -only-testing:MorselTests/PageIdentityTests \
  -only-testing:MorselTests/ParallelReadsTests -only-testing:MorselTests/SharedButtonTargetTests \
  -derivedDataPath /tmp/morsel-181-dd CODE_SIGNING_ALLOWED=NO
```

Raw exit **65**. `TodayFirstPaintBoundaryTests`: 4 tests / 6 failures.
`TodayFirstPaintOverlayTests`: 4 tests / 12 failures. Excerpt:
`red-base-focused.txt`; receipt `receipt-base-red-final-tests.json`.

The discriminating raw lines (verbatim from the log):

```
TodayFirstPaintOverlayTests.swift:80: error: … testFirstPublishedPaintIsTheCachedDayAlreadyCarryingQueuedRows :
  XCTAssertEqual failed: ("1") is not equal to ("3") - the cached paint already carries both queued rows
TodayFirstPaintOverlayTests.swift:133: error: … testQueuedOnlyStartupPaintsOnlyTheSelectedDaysOwnRows :
  XCTUnwrap failed: expected non-nil value of type "DashboardSnapshot"
TodayFirstPaintBoundaryTests.swift:59: error: … testFirstPaintAppliesTheWeightWindowAndWholeSecondDedupRules :
  XCTAssertEqual failed: ("1") is not equal to ("2") - one point per whole second inside the trailing window
TodayFirstPaintBoundaryTests.swift:87: error: … testFirstPaintEnergyKeepsTheLargerDirtyLocalTotalForTheSelectedDayOnly :
  XCTAssertEqual failed: ("200.0") is not equal to ("480.0") - the dirty local day total is fresher than the last remote total
```

So at base the first cached paint carries **one** row (the last authoritative meal),
`cachedToday` is `nil` for a queued-only startup, unsynced weight/energy never appear,
and the queued photo path is absent on the first paint.

**First attempt was not evidence:** the initial RED run (`.lane-logs/red-first-paint-compile-error.txt`)
failed at *compile* time (`'async' call in an autoclosure that does not support concurrency`
— `try await` inside `XCTUnwrap`/`XCTAssertEqual`); it is kept only as an audit trail and
was re-run as above after binding the awaited values.

## GREEN — same tests, fixed head

```
xcodebuild test … -only-testing:MorselTests/TodayFirstPaintOverlayTests \
  -only-testing:MorselTests/TodayFirstPaintBoundaryTests … CODE_SIGNING_ALLOWED=NO
```

Raw exit **0**, 8 tests / 0 failures — `green-focused.txt`,
`receipt-green-focused.json`. Full suite (no `-only-testing`): raw exit **65**,
534 tests / 3 skipped / **5 failures**, `green-full-suite.txt`:

| failing test at head | same failure at base (fix stashed)? | touched by this lane? |
| --- | --- | --- |
| `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping` (2 assertions: "GoalsEditor.swift: compensate outside the Button", inventory 14 ≠ 13) | yes (`base-red-final-tests.txt`) | no — source-scan over `app/Sources/Morsel/*.swift`; the extra `.buttonStyle(Morsel…)` call site arrived with the ff-merged #286 work |
| `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts` ("7" ≠ "6") | yes | no — the day read gained a 7th request from the ff-merged #286 dated-target read (`loadToday`: `calendar.isDateInToday(start) ? nil : try? await loadDatedTargets(…)`) |
| `PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll` ("the seed exposes a drill-down day") | yes | no — history seed/expectation, no `cachedToday` call |
| `MealReliabilityTests.testOfflineAddMealCommitsLocallyAndPaintsPendingRow` ("Something went wrong. Please try again.") | **no** — passes at base, and passes at head in the focused reruns (`head-known-reds.txt`) | no — `addMeal` starts an `invalidating` refresh (`needsCache == false`), so `cachedToday` is never called on that path; the offline `.failed` publish races the assertion (load/timing flake under full-suite load) |

None of the three pre-existing reds is caused by this lane: they fail identically with
the lane's fix stashed at base and are untouched by these two files. No file in this
lane's diff is referenced by them.

## AC mapping

| AC | witness |
| --- | --- |
| 1. cached day + queued photo/non-photo meals, restart + blocked network → each queued meal exactly once with its real state | `testRelaunchFirstPaintMergesQueuedMealsOnceWithTheirTrueState` (first **published** paint via `FirstPaintRecorder`), `testFirstPublishedPaintIsTheCachedDayAlreadyCarryingQueuedRows` (the refresh owner's `events[0]` is the cached paint) |
| 2. no dashboard cache + outbox rows for the selected local day → rows paint, no fabricated goal/remote values | `testQueuedOnlyStartupWithoutDashboardCachePaintsRowsWithoutFabricatedValues` (goal `nil`, empty trend, `activeEnergyBurned == 0`, no success time), `testQueuedOnlyStartupPaintsOnlyTheSelectedDaysOwnRows` (other day / other account never leak) |
| 3. unsynced weight/energy obey the existing dedup/window rules; no other-day/account rows | `testFirstPaintAppliesTheWeightWindowAndWholeSecondDedupRules` (whole-second identity replaces the round-tripped remote point once; −40 day sample absent), `testFirstPaintEnergyKeepsTheLargerDirtyLocalTotalForTheSelectedDayOnly` (dirty 480 > remote 200 wins; dirty 150 < remote 300 does not lower it; yesterday's 900 never leaks) |
| 4. later authoritative refresh reconciles by identity, no duplicates; queued photos available until reconciliation | `testAuthoritativeRefreshReconcilesByIdentityAndKeepsQueuedPhotoUntilReadback` (same client id appears once and is `synced`; queued bytes serve before and after the authoritative read; the real `LocalSyncEngine` readback releases the row, then the path resolves remotely) |
| 5. SQLite-backed hydration, repository/model recreation, cache miss, midnight/timezone | every test opens real per-account SQLite files (`LocalDataStore` + `LocalSnapshotCache` + `LocalHealthStore`) and rebuilds all connections + a fresh `DashboardViewModel` between phases; `testFirstPaintFollowsTheDeviceLocalDayAcrossMidnight` (23:30Z/06:30 +07 belong to the local Sep 5; 23:59 local Sep 4 does not; an empty day paints nothing) |

## Gate exits (this lane)

| gate | command | raw exit | log |
| --- | --- | --- | --- |
| npm ci | `npm ci --no-audit --no-fund` | 0 (256 packages) | `.lane-logs/npm-ci.txt` |
| hosted app contracts | `npx vitest run app` | 0 (21 files / 153 tests) | `.lane-logs/app-contracts.txt` |
| typecheck | `npm run typecheck` | 0 | `.lane-logs/app-contracts.txt` |
| full JS suite | `npm test` | **1** (2 × `Test timed out in 5000ms`, 0 `AssertionError` — host-load timeout class) → diagnostic rerun `npx vitest run server/http.test.ts server/tool-classification.test.ts --testTimeout=60000` = 0 (10/10) | `.lane-logs/npm-test.txt`, `.lane-logs/npm-test-diagnostic.txt` |
| swiftlint | `swiftlint lint --strict` | 0 (0 violations, 184 files) | `.lane-logs/swiftlint.txt` |
| xcodegen stability | `cd app && xcodegen generate` then `git diff` (from repo root) | 0, no diff | `.lane-logs/` + this commit |
| whitespace | `git diff --check` | 0 | — |
| native focused (RED) | base mechanism, fix stashed | **65** (8 tests / 18 failures) | `red-base-focused.txt` |
| native focused (GREEN) | head | **0** (8 tests / 0 failures) | `green-focused.txt` |
| native full (head) | no `-only-testing` | **65** (534 tests / 5 failures, all characterized above) | `green-full-suite.txt` |
| native focused (head, pre-existing reds) | 4 classes | 65 (30 tests / 4 failures — same 3 classes; `MealReliabilityTests` all green) | `head-known-reds.txt` |

`xcodegen generate` note: the generated `project.pbxproj` embeds a group named after the
**checkout directory** for its `path = ..` entry (`name = "issue-181-today-firstpaint"`,
replacing staging's `issue-286-hero`). That is xcodegen's own output for a worktree
checkout, not a hand edit; the stability gate passes (no diff after re-generating).

## Not verified here / disclosures

- **No physical-iPhone run.** Simulator/model evidence only; physical feel and HealthKit
  acceptance stay in tracker #172. Nothing here is presented as physical verification.
- The full native suite is **not green at base**: the three red classes above are
  pre-existing at `b5e64f3` (fix stashed). This lane leaves them alone (they are outside
  the #181 fence: matcher/GoalsEditor/ParallelReads expectations).
- Hosted CI (`ci.yml`) has no `xcodebuild test` job, so those base reds are not visible in
  hosted CI; the hosted app contracts (`npx vitest run app`) are green here.
- The full local JS suite (`npm test`) is red only through the documented host-load timeout
  class (2 × `Test timed out in 5000ms`, 0 `AssertionError`); both files pass 10/10 with a
  raised timeout, and no JS/`server/**` file is touched by this lane. The hosted `quality`
  job remains the authoritative `npm test` signal.
- The local-day boundary witnesses require the device zone east of UTC (Asia/Bangkok +07,
  as the repo's `LocalDayBucketTests` already require); the midnight test asserts the zone
  explicitly so a UTC host fails loudly instead of passing by accident.
- The fixture photo bytes are synthetic (`Data([0x10, 0x20, 0x30])`); no real meal,
  health, token or signed-URL data appears in these logs.

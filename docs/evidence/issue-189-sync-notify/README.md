# Issue #189 — notify the UI about what a sync pass actually changed

Simulator/model witnesses, not a physical-device, HealthKit or live-server acceptance run: every
fixture (meal, weight, energy day) is a synthetic value written into a throwaway account file.
Physical-iPhone feel and HealthKit behaviour stay with tracker #172.

Lane base: `94a662fc75a5711d609e5073eb5ed78e2cafedfd` (`origin/staging` when the lane started).
Code head for these witnesses: `93ab4208432e891c9fa373231568d5030e15c3bd` (the commit that carries
the fix and the durable tests); this evidence directory is the commit after it.

## What the fix changes

`LocalSyncEngine` decided whether to notify the UI from the *remaining* queue depth
(`storeHasQueuedOrDirtyWork()`), which is not a change signal:

- a **successful final-meal drain EMPTIES** the queue, so `changed == false` and the journal was
  never reconciled — the row stayed "pending" until the user switched tabs;
- a retry that **failed the same way again** left rows in the queue, so the same phantom "change"
  was re-notified on every backoff pass (reload storm), while a failed Health upload could still
  look like a completed one.

Now:

- `SyncPassChange` carries what ONE pass actually changed — released meal ids, journal-visible
  refusal transitions (a repeated identical refusal is not news) and per-type Health upload
  counts. Only identities and counts travel: no payloads, photos, Health values or secrets.
- `runPass` **awaits** the owner's hook before the pass completes, and `startReconciling` installs
  it. A pass that finished before installation (app start, where the engine exists before the
  shell's `.task` installs anything) is buffered as ONE **merged** change and delivered on
  installation, so an immediate startup drain cannot beat callback installation and cannot be
  lost.
- `MorselApp.task` installs that hook before the first import/load and routes each event to only
  the surface it changed: the journal day is re-read for released/refused rows, the calm Health
  status is re-derived only when a Health type uploaded. A no-op pass notifies nobody.
- Durable retries, needs-attention refusals and the #112 per-type upload marks are unchanged.

## RED — the audited mechanism fails at the lane base

`app/Sources/Morsel/LocalSyncEngine.swift` + `MorselApp.swift` reverted to `94a662f`, the durable
`SyncNotify*` witnesses moved out of the target, and a base-compatible probe (it drives the real
engine over the real SQLite outbox and uses the BASE `onSyncCompleted` hook) left in.

```
-only-testing:MorselTests/SyncNotifyBaseProbeTests
Executed 3 tests, with 3 failures (0 unexpected)      RAW_EXIT=65
```

- `testProbeSuccessfulDrainReportsOneReconciliation`: **0** events where 1 is required — the
  successful drain emptied the queue, so the remaining-rows test reported nothing.
- `testProbeUnchangedRefusalDoesNotReNotify`: **2** events after two identical refusals.
- `testProbeTransientFailureDoesNotReNotify`: **2** events after two transient failures.

Raw log: `.lane-logs/issue-189/base-probe.log` (sha256 in the excerpt header) →
`excerpts/base-red-probe.txt`.

## GREEN — the durable witnesses

```
-only-testing:MorselTests/SyncNotifyReconciliationTests
-only-testing:MorselTests/SyncNotifyPassCoverageTests
Executed 10 tests, with 0 failures (0 unexpected)     ** TEST SUCCEEDED **   RAW_EXIT=0
```

`SyncNotifyReconciliationTests` (5) covers AC1 (final-meal drain emits ONE event and the model's
journal converges in place, no tab switch), AC2 (Health-only success re-derives the per-type status
from the upload marks and does NOT reload the day; a no-op pass neither notifies nor reloads), AC4
(a pending→needs-attention transition notifies once, an identical refusal does not re-notify, a
changed refusal notifies exactly once more, and a failed pass neither claims a sync nor notifies).
`SyncNotifyPassCoverageTests` (5) covers AC3 (an immediate startup drain finished before
installation is delivered once on installation; two such completions arrive as ONE bounded event;
the shipped `syncNow` driver delivers the same event) and AC5 (empty / meal-only / Health-only /
mixed passes over the real SQLite stores with their journal and status outputs).

Raw log: `.lane-logs/issue-189/head-focused-r2.log` → `excerpts/head-green-focused.txt`.

## Mutation battery — the witnesses bite

Each mutation reverts ONE defended mechanism in the fixed engine, re-runs the focused command
above, and then restores the pristine file (`sha256 b8923fb83378eaceb3fb829fad636ac531baa1f8166466525a0ffe2d2001ff5c`,
verified identical after every iteration).

| mutation | mechanism removed | result |
| --- | --- | --- |
| m1-notify-empty-change | the "empty change is never an event" guard | 10 tests / 10 failures, exit 65 |
| m2-refusal-always-notifies | the journal-visible refusal-identity guard | 10 / 3, exit 65 |
| m3-drop-startup-buffer | buffering of a completion that beat installation | 10 / 6, exit 65 |
| m4-drop-release-record | recording a released (drained) meal | 10 / 20, exit 65 |
| m5-fake-health-success | "a failed Health pass is not a success" | 10 / 3, exit 65 |

The first m4 iteration exposed an unguarded subscript in a witness (index fault instead of
assertion failures); the witnesses were hardened (`SyncNotifyEvents.change(at:)` + `XCTUnwrap`),
the GREEN leg was re-run, and m4 was re-run against the hardened bytes — the row above is that
re-run. Raw logs: `.lane-logs/issue-189/mut-*.log`; battery log → `excerpts/mutation-battery.txt`.

## Full native suite and the pre-existing reds

```
xcodebuild test (no -only-testing)   Executed 563 tests, with 3 tests skipped and 4 failures   RAW_EXIT=65
```

Failing: `PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll`,
`ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts`,
`SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping`
(two assertion lines from that one case). These are NOT this lane's: with the fix reverted
(`git checkout --` the two source files, witnesses moved out) the same three suites fail at base
(`Executed 17 tests, with 4 failures`, RAW_EXIT=65) → `excerpts/base-stashed-known-reds.txt`.
They reproduce the reds already recorded for this base in the #183 report.

## Hosted app contracts (`npm test`)

`npm ci` then `npm test` at the head: `Test Files 2 failed | 61 passed (63)`,
`Tests 2 failed | 693 passed (695)`, RAW_EXIT=1, host load 12.9–14.8.

Both failures are `Error: Test timed out in 5000ms` in `server/http.test.ts` and
`server/tool-classification.test.ts` — `grep -c AssertionError` = 0, and the failing file set moved
between runs. Diagnostic only (never gate evidence): `npx vitest run --testTimeout=60000
server/http.test.ts server/tool-classification.test.ts` → `Test Files 2 passed`, `Tests 10 passed`,
exit 0 in 8.5 s.

An earlier attempt reused a symlinked `node_modules` from the primary checkout; that tree is
missing `@resvg/resvg-js`, which produced three unrelated failures (the rasterizer falls back to
SVG). The gate above ran after a pristine `npm ci` in this worktree; that earlier run is disclosed
here rather than dropped.

## Static gates

- `swiftlint lint --strict --quiet` → exit 0 (`excerpts/swiftlint-strict.txt`).
- XcodeGen stability at the committed head: `xcodegen generate --spec app/project.yml --project app`
  → exit 0, then `git diff --exit-code -- app/Morsel.xcodeproj/project.pbxproj` → exit 0 (the
  regenerated project is byte-identical, so the regenerated file is committed as generated).
- `git diff --check` (worktree) → exit 0; `git diff --cached --check` before the code commit → 0.

## Not proven here

- No physical-device, HealthKit-entitlement, live-Supabase or TestFlight behaviour is exercised;
  the witnesses run in the simulator against scripted remote boundaries.
- No real health or meal content, tokens or signed URLs appear in these logs.
- The two `npm test` timeouts are attributed to host load; this lane did not prove the cause.
- `docs/evidence/issue-209-health-status.md` still names the pre-#189 `onSyncCompleted` hook in its
  historical write-up; that file belongs to #209 and was left untouched.

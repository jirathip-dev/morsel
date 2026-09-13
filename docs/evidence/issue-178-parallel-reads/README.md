# Issue #178 — independent dashboard and history reads run concurrently (evidence)

The native repository read graph awaited every Supabase read one after another.
Issue #178 restructures it with **bounded structured concurrency** so the
independent reads overlap while every value semantic stays identical:

- `app/Sources/Morsel/Repository.swift` — `loadToday` starts `goals`,
  `profiles`, `weight_logs` and `energy_burned_logs` as `async let` children
  (after `requireSession`) and keeps `logs → items → images` serial; the four
  independent rows are awaited with the logs chain.
- `app/Sources/Morsel/HistoryRepository.swift` — `loadHistory` overlaps
  `goals`/`profiles`/`weight_logs` around the `logs → items` chain.
- `app/Sources/Morsel/GoalPageContext.swift` — `loadGoalsContext` overlaps its
  three independent row reads.
- `Repository.swift` also declares the finite ceiling:
  `enum ReadGraph { static let maxInFlightRequests = 5 }` — Today's four
  independent reads plus its one serial `logs → items` chain request
  (History reads 3 + 1; the goals context reads 3).
- The `async let` children live in the caller's structured scope: a throw,
  an early return or task cancellation cancels and awaits them, so no request
  can be orphaned (no detached tasks, no unbounded fan-out).

## How the claims are proven (real request seams, not fakes)

`app/Tests/MorselTests/StubSupabaseReadTransport.swift` installs a
`URLProtocol` transport at the **real URLSession seam** the production
`SupabaseClient` uses (`SupabaseClientOptions(global: .init(session:))`), with a
key-scoped in-memory `AuthLocalStorage` that seeds a real `Session` (so
`requireSession` answers without a network round trip; an expired one still
forces the real `/token` refresh path). The transport records every
start/finish/cancel with a global sequence number, tracks in-flight and peak
counts, and can park chosen paths until the test releases them.

`app/Tests/MorselTests/ParallelReadsTests.swift` (7 tests) drives the
production `SupabaseDashboardRepository.loadToday/loadHistory/loadGoalsContext`:

| Claim (issue AC) | Test | Mechanism |
| --- | --- | --- |
| Held independent request, others start first; `logs → items` stays ordered | `testTodayOverlapsTheIndependentReadsAndKeepsTheLogsItemsChain` | all six Today endpoints parked; `inFlight == 5` proves overlap, `meal_items` start sequence > `meal_logs` finish sequence |
| Finite ceiling reached exactly | same test + `testTodayHeldReadGraphReachesExactlyTheDeclaredCeiling` | `peakInFlight == ReadGraph.maxInFlightRequests` (5) while five requests are parked |
| Empty day / auth expiry terminate, no orphans | `testEmptyDayAndAuthExpiryTerminateWithNoOrphanTasks` | empty tables: 0 item reads, `inFlight == 0`; expired session + 401 `/token`: 0 `/rest/v1` requests, `inFlight == 0` |
| Partial failure + cancellation, no orphans | `testPartialFailureAndCancellationLeaveNoOrphanTasks` | weight 500 with a parked sibling → read throws and the parked read is cancelled; caller cancel → all five drain to `inFlight == 0` |
| Snapshot values match the sequential baseline | `testTodaySnapshotMatchesTheSequentialBaselineValues` | populated day: manual goal 2000/150/200/60, energy 320, whole-second weight dedupe → `[81.2]`, item values; stale manual row → computed goal 2727/205/307/76 |
| History + goals-context values and overlap | `testHistoryAndGoalsContextOverlapAndKeepBaselineValues` | 7 local days, one logged day at 300 kcal, goal 2000; context stored/profile/latestWeight values |
| Local timezone / DST boundary window | `testTodayWindowFollowsTheDeviceZoneAcrossTheSpringForwardDay` | process zone → America/New_York; 2026-03-08 (23-hour local day): `eaten_at` bounds are `gte.`/`lt.` exactly the local day starts, trend bound `-29` local days |
| Deterministic measurement + request counts | `testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts` | every endpoint delayed 200 ms; records reads/peak/elapsed |

## RED → GREEN (behavioural, scratch copy)

The probe `ParallelReadsProbeTests` (kept at `.lane-logs/probe/`, never
committed) makes the same behavioural claims against base-available API only
(the ceiling is a literal there because `ReadGraph` does not exist at base):

| Leg | Sources | Command | Raw exit | Result |
| --- | --- | --- | --- | --- |
| RED | base `b3860964` | `xcodebuild test … -only-testing:MorselTests/ParallelReadsProbeTests` (`HERDR_XCODEBUILD_DIRECT=1`, lane derived data) | `redprobe=65` (`.lane-logs/red-probe.log`) | 3 tests, **4 assertion failures (0 unexpected)**: overlap claim, peak `1 != 5`, `1.288 s !< 0.600 s` |
| GREEN | head (this branch) | same command | `greenprobe=0` (`.lane-logs/green-probe.log`) | 3 tests, 0 failures, 0.466 s |

The base failures are behaviour, not compile errors: the probe compiles against
base `b3860964` and fails because the sequential graph never has a second
request in flight (`peakInFlight=1`).

## Fixture measurements (deterministic endpoints, NOT production speed)

Deterministic 200 ms delay per endpoint, same fixture on both trees — six
requests (goals, profiles, weight, energy, logs, items):

| Tree | reads | peakInFlight | critical path (fixture) |
| --- | --- | --- | --- |
| base `b3860964` (sequential) | 6 | 1 | 1.288 s |
| head (concurrent, in-suite print) | 6 | 5 | 0.423 s |
| head (probe print) | 6 | 5 | 0.448 s |

These are **fixture measurements on a simulator with synthetic delays**; they
are not a production speedup claim (a device's real duration depends on its
network, and the endpoint delay is an artifact of the stub transport).

Request counts on a populated Today read: `meal_logs` 1, `meal_items` 1,
`goals` 1, `profiles` 1, `weight_logs` 1, `energy_burned_logs` 1 (asserted in
`testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts`).

## Native run provenance

- Xcode 26.6, iOS 26.5 runtime, dedicated simulator `Morsel178-iPhone16`
  UDID `7BDC1863-87FB-4C34-BBC2-FD7B7A20A802`, unsigned Debug,
  `CODE_SIGNING_ALLOWED=NO`.
- The brief's simulator-create line names runtime
  `com.apple.CoreSimulator.SimRuntime.iOS-26.5`; that identifier is invalid on
  this host — the create used `…iOS-26-5` (the installed runtime id). The
  brief's `xcodebuild` line also cannot run as written here: the machine
  default derived-data volume (`/Volumes/NVMe2TB`) is not mounted, and herdr
  lanes have `HERDR_ENV=1` (the shim reroutes simulator actions to a throwaway
  sim), so the run adds `-derivedDataPath $HOME/Library/Developer/Xcode/
  DerivedData/Morsel178` and `HERDR_XCODEBUILD_DIRECT=1`.
- Full suite (`.lane-logs/xcodebuild-final.log`): **307 tests, 0 failures**,
  raw exit `xcodebuild_final=0`; the new suite alone runs 7 tests, 0 failures.
- Fresh-sim wedge (documented repo class): the first full-suite attempt wedged
  in `GoalsPolishTests` (frozen, 0% CPU, leaked-continuation warning); it was
  killed and re-run once on the warm sim, which passed. Log kept at
  `.lane-logs/xcodebuild-wedged.log`.

## Host-side TS suite (`npm test`) — raw exits, load-skew class

`npm test` (vitest) is load-sensitive on this host (5 s per-test budget) and
this lane's diff is native-only. Raw exits:

| Run | Command | Raw exit | Result |
| --- | --- | --- | --- |
| head | `npm test` | `npmtest=1` | 5 failed / 551 passed; 15 x "Test timed out in 5000ms", **0 AssertionError** (`.lane-logs/npm-test.log`) |
| isolation | `npx vitest run --testTimeout=60000 server/http.test.ts server/render-png.test.ts server/tool-classification.test.ts` | `isolated=0` | 12/12 pass, 3.7-4.4 s per previously-timed-out test (`.lane-logs/npm-test-isolated.log`) |
| pristine base `b3860964` | `git worktree add --detach /tmp/… ; npm ci ; npm test` | `base_npmtest=1` | 6 failed / 550 passed, same timeout class, 0 AssertionError (`.lane-logs/base-control-npm-test.log`) — the base is red under the same host load |

`typecheck=0`, `lint=0`, `npmci=0` in the same tree.

## Not verified / boundaries

- No physical-device feel or HealthKit acceptance: simulator/model evidence
  only (tracker #172 retains the physical-iPhone acceptance).
- No production performance claim (fixture timing only, see above).
- The DST window test overrides the process zone (`NSTimeZone.default`) rather
  than running with a device zone set at boot; it asserts the override took
  effect before making the claim.
- No backend migration, no raw unbounded task fan-out, no photo-signing
  critical-path work (issue #179 companion).
- NOT MERGED; not opened as PR; no deploy; no production writes.

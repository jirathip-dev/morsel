# Issue #196 — executable responsiveness and request-budget evidence

Tracker: [#172](https://github.com/jirathip-dev/morsel/issues/172) ·
Issue: [#196](https://github.com/jirathip-dev/morsel/issues/196) ·
Lane base: `659055d` (`origin/staging`).

**Simulator-only completion.** Physical-iPhone feel/HealthKit acceptance and
signed build identity stay human-gated in #172 — nothing in this evidence
claims owner-device acceptance, and no target below was loosened.

## What this is

A repo-local native test/measurement harness (XCTest only, no new telemetry
service, no production secrets, no production change) that measures the real
shell transitions and repository request budgets on deterministic fixtures:

| file | what it holds |
| --- | --- |
| `app/Tests/MorselTests/ResponsivenessTestSupport.swift` | synthetic fixture, privacy-safe metrics recorder, the counting/delaying/failing remote seam, the mounted shell rig |
| `app/Tests/MorselTests/ResponsivenessShellProbes.swift` | shell-shaped mount (REAL turner, stage, tab bar, route model, presentation owner), page probes, window pixel sampling |
| `app/Tests/MorselTests/ResponsivenessShellCycleTests.swift` | AC2: 100 mixed shell cycles + AC1 tap/gesture/paint intervals |
| `app/Tests/MorselTests/ResponsivenessBudgetTests.swift` | AC3: independent fault injection + shell-level request budgets |
| `app/Tests/MorselTests/ResponsivenessIntervalsTests.swift` | AC1: cached paint, remote refresh, image preparation, Health callback intervals |

**Privacy contract.** Recorded output is fixture IDs, call counts, in-flight
peaks and durations only. Meal names, tokens, signed URLs and real content
never enter a measurement line; the fixture is synthetic (12 meals × 3 items,
generated `8-4-4-4-12` UUIDs, fixed instants).

**Fidelity note.** `AuthenticatedDashboardView` is `private` in `MorselApp.swift`
and its initialiser builds its own services, so the harness mounts a
shell-shaped page area wired exactly like the shell (`InteractionOwnershipTests`
precedent) and drives the REAL `DashboardViewModel` + REAL `TodayRefreshOwner` +
REAL `LocalFirstDashboardRepository` over a real SQLite store. A parity witness
(`testHarnessTriggersMatchTheShellSource`) pins the harness's trigger set to the
shell's source literals so drift fails a test.

## How to run (repeatable)

```bash
cd app
HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test \
  -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=<lane UDID>' \
  -derivedDataPath /tmp/morsel-196-dd CODE_SIGNING_ALLOWED=NO \
  -only-testing:MorselTests/ResponsivenessShellCycleTests \
  -only-testing:MorselTests/ResponsivenessBudgetTests \
  -only-testing:MorselTests/ResponsivenessIntervalsTests
```

`-derivedDataPath` MUST stay under `/tmp`: the shared `/Volumes/NVMe2TB` volume
is not writable (error 513) and a bare run fails at exit 74 for that reason
alone. One heavy native leg at a time (`flock /tmp/n.lock`).

## Fixture, build config, device

- Fixture: 12 meals × 3 items per day (36 items), one 320×240 synthetic JPEG
  (2149 bytes), fixed clock `2026-09-18T20:00Z`, generated UUIDs.
- Build: `Debug`, `CODE_SIGNING_ALLOWED=NO`, Xcode 26.6 (17F113), iOS 17.0
  deployment target, XcodeGen from `app/project.yml`.
- Device: simulator `Morsel196-iPhone17` (UDID `DACB0B66-9BE1-458E-8ABF-FC74BA1C9942`),
  iPhone 17, iOS 26.5 (23F77), host macOS 26.6.2.
- Raw logs: `.lane-logs/196-*.log` (lane-local, untracked); committed excerpts
  in `excerpts/`.

## AC1 — measured intervals (base `659055d`, no production edits)

Raw: `excerpts/baseline-focused.txt` (recorded before any production edit —
there is none: the lane's diff is test-only) and `excerpts/head-focused.txt`
(the same three classes at the final lane head; both exit 0, 11 tests,
0 failures); machine-readable: `measurements/*.json`.

| interval | n | p50 ms | p95 ms | max ms |
| --- | --- | --- | --- | --- |
| `tap-to-first-response` (tap → turn committed) | 30 | 5.4 | 5.7 | 9.2 |
| `tap-to-settled` (includes the 550 ms hinge) | 30 | 563.5 | 566.0 | 573.1 |
| `retarget-to-settled` (tap, retarget, settle) | 15 | 565.2 | 569.6 | 569.6 |
| `rollback-to-settled` | 20 | 64.4 | 68.2 | 68.2 |
| `rm-tap-to-settled` (Reduce Motion, no hinge) | 10 | 5.6 | 7.3 | 7.3 |
| `paint-settle` (state-settled → painted page) | 100 | 49.3 | 69.5 | 74.3 |
| `keyboard-dismiss-to-settled` | 5 | 602.1 | 627.2 | 627.2 |
| `cache-publish-to-paint` (warm cache) | 1 | 30.5 | 30.5 | 30.5 |
| `refresh-release-to-fresh-paint` | 1 | 59.2 | 59.2 | 59.2 |
| `image-preparation` (`MealThumbnailPreparer`) | 1 | 9.5 | 9.5 | 9.5 |
| `health-observer-callback` | 1 | 0.15 | 0.15 | 0.15 |

Interpretation, stated honestly:

- The **tap→settled** numbers are dominated by the intentional 550 ms hinge
  (`JournalTurnSeam.richDuration = 0.55`). Excluding it, the non-hinge part is
  `tap-to-settled − 550 ms` ≈ **13–23 ms**, and the Reduce Motion path
  (`rm-tap-to-settled`, no hinge at all) is **5.6–7.3 ms**.
- The paint leg after the state settles is **p50 49.3 ms / p95 69.5 ms**; on a
  warm cache the app-side cache→paint leg is **30.5 ms**.
- These are in-process simulator measurements under the documented conditions,
  not physical-device frame timings: touch delivery and display refresh are not
  part of them.

## AC3 — request budgets from recorded counts

| scenario | recorded count | budget asserted |
| --- | --- | --- |
| cold mount (`.task`) | `cold-mount-day-reads = 1` | exactly 1 day read, peak in-flight 1 |
| foreground return (background → active) | `foreground-return-day-reads = 1` | exactly 1 day read per activation |
| leave Today | 0 further reads | leaving must not issue a read |
| return to Today | `tab-return-day-reads = 1` | exactly 1 day read per return |
| second activation while a read is parked | calls stay 1, peak 1 | the in-flight pass is joined, never duplicated |
| leaving Today while parked + release | no fresh publish | a cancelled pass must not publish |
| parked Storage (one image) | `parked-storage-reads = 1`, peak 1 | one requested image is one in-flight read |
| parked Health (body mass) | `parked-health-body-reads = 1` | the body-mass pass is the only Health read; energy stays 0 |
| parked network + navigation | `parked-network-reads = 2` | one read per activation, never more; reads never overlap |

Each assertion is made against the harness's counting remote, so the numbers
are counts the shell really issued.

## AC2 — mounted shell cycles

`excerpts/baseline-focused.txt`: `ISSUE196-COUNT id=cycles value=100`,
`taps = 85`, `page-activation-events = 81`, `backgroundings = 5`,
`vertical-drags = 10`. Schedule: 30 flips, 20 rollbacks, 15 retargets,
10 vertical drags, 5 keyboard dismissals, 5 sheet open/close pairs,
5 backgroundings, 10 Reduce Motion flips — deterministically shuffled
(`SplitMix64`, seed 196).

Every cycle asserts: **one settled page** (the machine at rest with
`baseTab == pager.selection` and exactly one activatable page), **matching tab**
(the painted window ground names the settled tab, sampled from real pixels) and
**one action per tap** (exactly one pager selection change and exactly one turn
operation per tap). Gestures are driven through the same machine calls the
turner's handlers make and the keyboard cycle calls the same
`JournalKeyboardDismisser.resign()` the tab bar calls: this host has no touch
synthesis (#174/#177 precedent).

## AC4 — documentation

This file plus `excerpts/` (raw exits, test counts, metric lines),
`measurements/*.json` (machine-readable), `mutations/battery.sh` (the exact
mutation recipes) and `GATES.md` (gate commands and raw exits). Before/after
legs use the identical harness, fixture, simulator and build config.

## AC5 — adopted provisional targets vs measured (simulator)

| target (declared physical test device) | measured here (simulator) | verdict |
| --- | --- | --- |
| first action feedback ≤ 100 ms | `tap-to-first-response` p95 **5.7 ms**; `rm-tap-to-settled` p95 **7.3 ms**; non-hinge settle ≈ 13–23 ms | inside, on the simulator |
| cached useful paint ≤ 200 ms | `cache-publish-to-paint` **30.5 ms** (warm cache, network parked) | inside, on the simulator |

The targets are quoted as targets, not as measured results: the declared
context is the physical test device, which stays human-gated in #172. No target
was loosened, and no measured number above is presented as device proof.

## Biting regression — per-mechanism mutation battery

`mutations/battery.sh` mutates ONE audited mechanism at a time, requires the
named harness assertion to FAIL (raw exit 65), restores the file with a
sha256-proven byte-identical copy, and re-runs the restored tree green.
RED/GREEN excerpts are in `mutations/excerpts/` (each records the exact
command, the failing assertions and `RAW_EXIT`).

See `mutations/README.md` for the per-mutation mechanism → assertion map and the
raw exits.

## What was NOT verified

- Physical-device feel, frame timing, HealthKit permission flows and signed
  build identity — human-gated in #172 (AC6). Simulator measurements only.
- Touch synthesis: gestures/keyboard are driven through the same seams the
  handlers call; no real touch injection exists on this host.
- The page reload-key advance (`HistoryView(reloadKey:)`) is *recorded*
  (`page-activation-events`) but not asserted: the in-bundle page-observation
  channel proved non-deterministic, and the reload-key contract is pinned by
  the existing pager suites (`JournalPagerRaceTests`, `PageIdentityTests`).
- The harness mounts a shell-shaped page area (see the fidelity note) rather
  than the private `AuthenticatedDashboardView` itself.
- Hosted `npm test` and the full native suite results: `GATES.md`.

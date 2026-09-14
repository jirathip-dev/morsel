# Issue #184 — load goal context without waiting for the full Today dashboard

Base `5cea5bf` (lane `issue/184-goals-context`; the issue/brief cite `2adb081` —
its parent. The only file that differs between the two for this mechanism is
`LocalFirstRepository.swift`'s #188 revision seams, which do not touch
`cachedToday`/`loadToday`). Head = this lane's single commit (exact sha in the
lane `.report.md`).

Evidence captured on the lane's dedicated simulator
**`Morsel184-iPhone16`** (UDID `D1788AC5-2BF6-499A-8638-21F0457C5DB8`, iOS 26.5
runtime `com.apple.CoreSimulator.SimRuntime.iOS-26-5` — the brief's
`…iOS-26.5` id is rejected on this host as *Invalid runtime*), unsigned Debug
build (`CODE_SIGNING_ALLOWED=NO`, simulator — **not a physical device**), one
complete full-suite invocation. Raw lines below are lifted verbatim from the
lane logs in `.lane-logs/` (untracked); the quoted ones live in
`trace/goals-open-spy.txt`.

## What changed

`GoalsEditorViewModel.load()` ran the **full Today dashboard read** (meal logs +
items, meal photo paths, profiles, 30-day weight trend, active energy) only to
sum calories into `todayCalories`, and that read gated and could fail the whole
Goals load. It now:

- paints the cached goals row first (unchanged, issue #123), then
- starts ONE **narrow** calorie read — `DashboardRepository.loadDayCalories`
  (`GoalPageContext.swift`, defaulted): the same-account/device-local-day total
  from the snapshot the local-first cache already holds, summed with the
  existing `DashboardMath.totals` (no formula, recency or backend change), then
- reads the goals context independently (`loadGoalsContext`, unchanged) and
  applies it — the narrow read never gates it, and
- applies the narrow total only when it is still the **current account + the
  device-local day it was requested for** and the load that asked for it is not
  superseded/cancelled. A failed or absent total stays `nil` → the line reads
  `Today: total pending · …` and **never** `0 eaten`; goals editing (validation,
  save) is untouched by it.

`todayCalories` is `Double?` (`nil` = pending/unavailable); the consequence
arithmetic itself is the pre-existing pinned contract (see *Boundaries*).

## AC2 — request-spy evidence (no full reload just to sum calories)

`GoalsPageRequestSpy` records every repository call the page makes and counts
full Today reads; any full read fails loudly. In one complete run:

| assertion (test) | observed |
| --- | --- |
| `fullDashboardReads == 0` while opening Goals (`testOpeningGoalsReadsTheNarrowLocalDayTotalAndNoFullDashboard`) | 0 |
| recorded calls are exactly `cachedGoals`, `cachedToday`, `loadGoalsContext` — no `loadToday`, `loadHistory`, `loadMealImage` | exact set match |
| the narrow reads yield the cached day total (993 kcal) | `todayCalories == 993` |
| REAL `LocalFirstDashboardRepository` over the real SQLite cache: the seeded full read stays at 1, opening Goals adds none and still shows 500 kcal (`testRealLocalFirstRepositoryServesTheCachedDayTotalWithNoAddedFullRead`) | `fullDashboardReads == 1` before and after |

## AC1 / AC3 / AC4 — held, late, superseded, cancelled, failing totals

| case (test) | assertion |
| --- | --- |
| held local read (`testHeldLocalReadStillPaintsTargetsAndProfileWithTheTotalPending`) | targets `2000.0` + profile line painted while the narrow read is parked; total pending; the line says `total pending` and **not** `0 eaten`; total 1_200 lands after release |
| midnight (`testDayTotalArrivingAfterMidnightIsDropped`) | a read requested at 23:50 that answers after 00:10 paints nothing (still pending) |
| superseded load (`testSupersededLoadCannotPaintItsStaleTotal`) | load 2's 222 wins; the released stale 111 read paints nothing |
| cancelled load (`testCancelledLoadNeverPaintsItsLateTotal`) | cancelled `load()` still paints the fetched targets; its late 500 kcal read paints nothing |
| unreadable total (`testUnreadableDayTotalLeavesTheLinePendingAndGoalsEditable`) | no page error, line pending, `edit` + `save` still succeed (2_100 written) |
| superseded-manual outcome (`testLateTotalLeavesTheSupersededManualOutcomeUntouched`) | computed targets + `source: computed` + chosen chip + superseded note are identical before and after the late total |

No sleeps: the parked reads are `CheckedContinuation`s and every late assertion
awaits the model's in-flight narrow read (`dayTotalTask`, internal for tests).

## RED (base `5cea5bf`) → GREEN (head)

The durable suite cannot compile at base (it uses `now:`, `dayTotalTask` and
`todayCalories` as an optional — all introduced at the head), so the behavioural
RED is a **base-compatible probe** in a scratch worktree at `5cea5bf`
(`/tmp/morsel184-red`, probe file `Issue184GoalsOpenRedProbeTests.swift`, run
`-only-testing:MorselTests/Issue184GoalsOpenRedProbeTests`):

```
Issue184GoalsOpenRedProbeTests.swift:40: error: -[MorselTests.Issue184GoalsOpenRedProbeTests testAuditedOpeningGoalsRunsTheFullTodayReadAndSurfacesItsFailure] : XCTAssertEqual failed: ("1") is not equal to ("0") - the goals page must not run the full Today read
Issue184GoalsOpenRedProbeTests.swift:41: error: -[MorselTests.Issue184GoalsOpenRedProbeTests testAuditedOpeningGoalsRunsTheFullTodayReadAndSurfacesItsFailure] : XCTAssertNil failed: "The request could not be completed. Try again." - a Today read failure must not reach the Goals page
Issue184GoalsOpenRedProbeTests.swift:57: error: -[MorselTests.Issue184GoalsOpenRedProbeTests testAuditedHeldTodayReadBlocksTheFetchedTargets] : XCTAssertEqual failed: ("") is not equal to ("2000.0") - the fetched targets must appear while the full Today read is held
	 Executed 2 tests, with 3 failures (0 unexpected) in 0.103 (0.104) seconds
red-base=65
```

So at base the Goals page really does (a) run the full Today read, (b) surface
its failure as the page error, and (c) hold the targets behind it. The same
three properties are green at the head through the tests above. The scratch
worktree was removed (`git worktree remove --force` + `prune`).

## Hosted source pin (out-of-fence edit, disclosed)

`app/issue-123-goals-polish-contract.test.ts` pinned the audited mechanism
itself (`goalsModel.indexOf('repository.loadToday(userID: userID, date: Date())')`
must follow the cached paint) and `npm test` runs it in CI. Removing the full
read therefore reddened it deterministically — raw exit **1**, one assertion
(`expected -1 to be greater than 5181`). The pin was retargeted to the same
intent (cached paint precedes the remote round-trip = `loadGoalsContext`) plus a
new #184 guard (`expect(goalsModel).not.toContain('repository.loadToday(')`), so
the pin now *forbids* the full read's return instead of requiring it. Pair:
`.lane-logs/vitest-goals-pins-BEFORE.log` = 1 → `.lane-logs/vitest-goals-pins-AFTER.log`
= 0 (2 files / 16 tests passed).

## Raw exits (this lane)

| gate | command | raw exit | log |
| --- | --- | --- | --- |
| npm ci | `npm ci --no-audit --no-fund` | 0 | `.lane-logs/npm-ci.log` |
| typecheck | `npm run typecheck` | 0 | `.lane-logs/typecheck.log` |
| lint | `npm run lint` | 0 | `.lane-logs/lint.log` |
| xcodegen | `cd app && xcodegen generate` | 0 (`project.pbxproj` +4 lines for the two new test files, committed) | — |
| swiftlint | `swiftlint --strict` | 0 (127 files, 0 violations) | `.lane-logs/swiftlint.log` |
| diff check | `git diff --check` | 0 | — |
| goals pins | `npx vitest run app/issue-123-goals-polish-contract.test.ts app/issue-113-goals-contract.test.ts` | 1 → **0** after the pin retarget | `.lane-logs/vitest-goals-pins-{BEFORE,AFTER}.log` |
| native full (gate) | `HERDR_XCODEBUILD_DIRECT=1 xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination "platform=iOS Simulator,id=D1788AC5-…" CODE_SIGNING_ALLOWED=NO` | **0** (381 tests / 0 failures, one complete invocation, no skip/only flags) | `.lane-logs/xcodebuild-full.log` |
| native full attempt 1 | same command | 65 (381 tests / 1 failure — this lane's own new test fixture, see below) | `.lane-logs/xcodebuild-run1-1failure.log` |
| RED base | base probe in scratch worktree | 65 (2 tests / 3 failures) | `.lane-logs/red-base.log` |
| npm test | `npm test` | 1 (5 × `Test timed out in 5000ms`, 0 assertion failures + 1 `vitest-worker` `onTaskUpdate` timeout under host load 28–45; the 3 red files are `server/**`, none is an app pin) | `.lane-logs/npm-test.log` |

Attempt 1 was a green build/test compile whose only failure was this lane's own
new fixture: the held-storage test used a stale manual goals row against a newer
profile, so the computed path (2137.0 kcal) legitimately won over the fixture's
2000.0. Fixed by making the manual row current (`updatedAt` after the profile);
attempt 2 is the gate above. The app pins were green inside the full `npm test`
run as well.

## Files

- `app/Sources/Morsel/GoalsEditorModel.swift` — narrow read + late/superseded/
  midnight/cancelled guards, `todayCalories: Double?`, pending copy.
- `app/Sources/Morsel/GoalPageContext.swift` — `loadDayCalories` (defaulted:
  the cached same-account/local-day total; `nil` = pending).
- `app/Tests/MorselTests/GoalsContextLazyLoadTests.swift`,
  `app/Tests/MorselTests/GoalsPageRequestSpy.swift` (new),
  `app/Morsel.xcodeproj/project.pbxproj` (xcodegen output).
- `app/issue-123-goals-polish-contract.test.ts` — pin retarget (disclosed above).
- `trace/goals-open-spy.txt` — the raw lines quoted here.

## Boundaries / not verified here

- The narrow total is the locally cached day snapshot (the last write-through of
  a Today read). A meal still in the local outbox (queued, not yet synced) is
  **not** part of that snapshot, where the old full read merged queued rows — the
  consequence line can lag the Today tab by one unsynced meal until the day
  snapshot refreshes. No new remote summary RPC was added (backend untouched), so
  a device with no cached day snapshot reads `total pending` rather than a guess.
- The *eaten* figure is what must not lie about a zero; the pre-existing pinned
  "what changes" arithmetic (`target − eaten`, `GoalsEditorTests`) is unchanged
  and evaluates against 0 while the total is unknown — disclosed here rather
  than silently re-scoped.
- No physical-device run (the tracker keeps physical feel/HealthKit acceptance).
- The view file (`GoalsEditor.swift`) is untouched; it renders `whatChangesText`,
  so both the known and the pending copy reach the page unchanged.
- `dayTotalTask` is internal (not private) so the delayed-response tests can
  await the in-flight read deterministically; it is not part of the page API.

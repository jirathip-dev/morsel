# Issue 190 — a confirmed mutation finishes on its own acknowledgement, not on a dashboard reload

Lane checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-190-write-ack`.
Base: `83010c8f4288b6c7f636fd287920dd06b1d62d59` (`origin/staging`).
Code + test commit and evidence commit: recorded in `.report.md` and in the
branch log; every gate receipt is in `GATES.md`, run receipts in `native/run.json`
and `hosted/run.json`, raw logs in the checkout's gitignored `.lane-logs/`.

## Mechanism

Before #190 every confirmed mutation awaited a FULL dashboard read before it
completed: `markReviewed` / `updateMealItem` / `attachPhoto` / `deleteMeal` ran
`try await refreshSelectedDay()` after the write, and the shipped Goals `onSaved`
wiring awaited `viewModel.invalidateDay()`. Two consequences followed: a blocked
or slow day read held the sheet/control in its saving state, and a *failed*
refresh turned an already-confirmed write into `false` plus a write-shaped error.

The fix separates the two concerns:

- **The write owns its outcome.** Each entry point writes once and then the
  acknowledged record is projected locally: only the fields that write itself
  owns are updated (`acknowledgedRow`), and only for the acknowledged record
  (`confirming` / `confirmingItem` / `confirmingMeals`). No invented confidence,
  notes, artwork, menu grouping or sync state — a queued row still reads
  `pending`, an edited row keeps the server's confidence.
- **The day read is freshness.** `confirmedWrite` (ViewModel.swift) captures the
  day on screen, starts ONE invalidating pass and returns:
  `startRefresh(invalidating: true, keepsAlive: true)` supersedes any pre-mutation
  pass (#182's refresh owner bumps its revision, so a pre-mutation response is
  discarded rather than published, and #183's generation ordering already fences
  its cache publication), admits the fresh read without ever awaiting it, and
  never hydrates that pass from the pre-mutation cache (`needsCache` is false for
  an invalidating read).
- **A repeated tap joins the write in flight.** `joinedWrite` keys one write per
  acknowledged record (`review:` / `edit:` / `photo:` / `delete:` + id): the
  second tap awaits the SAME task and shares its outcome, so a double tap issues
  no duplicate mutation and never fabricates a second result. A refused write
  still surfaces its honest copy through the shared refusal path (`refuse`),
  which keeps the base contract (a cancellation stays silent, a refusal carries
  its message).
- **Goals.** The Goals save keeps its own acknowledgement (`goal = savedGoal`,
  `didSave`), its draft ownership (#186) and the facade's goals-cache
  write-through, and the shell wiring (`MorselApp.swift`) now invalidates Today
  through `invalidateDayAfterConfirmedGoals()` instead of awaiting a full reload.
  `save()` refuses a second concurrent submission (`!isSaving`), so a double tap
  writes once.
- `refreshSelectedDay` (the awaited reload) is deleted; nothing waits on a
  dashboard read to report a write outcome.

Files:

| File | Change |
| --- | --- |
| `app/Sources/Morsel/ViewModel.swift` | the four entry points, the shared refusal path, `confirmedWrite`, `invalidateDayAfterConfirmedGoals`; `refreshSelectedDay` deleted; captured-day projection (398 lines, inside the 400-line budget) |
| `app/Sources/Morsel/WriteAcknowledgement.swift` | NEW: the write-join guard (`joinedWrite`) and the acknowledged-record projections |
| `app/Sources/Morsel/GoalsEditorModel.swift` | `save()` refuses a second concurrent submission |
| `app/Sources/Morsel/MorselApp.swift` | one-line shell wiring: the Goals save invalidates Today without awaiting it |
| `app/Tests/MorselTests/WriteAckTestSupport.swift` | NEW: scripted remote + shared fixtures/bounded waits |
| `app/Tests/MorselTests/WriteAckRegressionTests.swift` | NEW: the AC1/AC2/AC3/AC4/AC5 core suite |
| `app/Tests/MorselTests/WriteAckActionMatrixTests.swift` | NEW: every named action against refusal / double tap / failed refresh |
| `app/Tests/MorselTests/WriteAckGoalsTests.swift` | NEW: the Goals save (head-only: it drives the new entry point) |
| `app/Tests/MorselTests/TodayRefreshLifecycleTests.swift`, `TodayRefreshRegressionTests.swift`, `JournalCalendarTests.swift` | retargeted pins (#182's and two others that pinned the awaited-reload timing) |
| `app/Morsel.xcodeproj/project.pbxproj` | xcodegen output (new files + the checkout-named group rename) |
| `docs/evidence/issue-190-write-ack/**` | this package |

### Disclosed fence deviation: one new source file

`WriteAcknowledgement.swift` is a NEW source file; the brief's fence lists only
existing files. The confirmed-outcome machinery needs ~55 lines and every file
the fence names already sits at the repo's cap (`ViewModel.swift` 397 before this
change, `GoalsEditorModel.swift` 399, `MorselApp.swift` 400,
`MealItemEditSheet.swift` 395, `Views.swift` 399); `ViewModel.swift` is 398
after it. The alternatives were ~50 lines of semantics-identical compaction in
unrelated Health/first-load code, or relocating another lane's code — both worse
for review and risk than one single-purpose file. The file carries no state of
its own: the state-owning helpers (`snapshot` write, saving flags) stayed in
`ViewModel.swift`, and the internal seams are documented there.

## Acceptance

| AC | Executed regression (native XCTest, real view-model methods) | At base (`83010c8`) | At head |
| --- | --- | --- | --- |
| 1 | `WriteAckConfirmTests.testReviewFinishesWithoutWaitingForTheDashboardRead` — the confirmed review completes, the item leaves the review queue, and the invalidated read is still in flight | FAIL (the action never returned; `until` bounded at 3 s) | pass |
| 1 | `…testEditFinishes…TouchesOnlyThatItem`, `…testPhotoAttachFinishes…KeepsTheQueuedRowPending`, `…testDeleteFinishes…RemovesOnlyThatMeal` — each named action completes with the day read parked, `isSaving` false | FAIL (each awaited the parked read) | pass |
| 1 | `WriteAckActionMatrixTests.testEveryNamedActionFinishesWithTheRefreshBlocked` — the same claim for all four actions in one sweep | FAIL | pass |
| 1 | `WriteAckGoalsTests.testGoalsSaveFinishesWithoutWaitingForTheDashboardRead` — the Goals save completes with the day read blocked, `didSave` true, the Save control out of its saving state | FAIL (`base-probe/GoalsWiringBaseProbe.swift`: identical composition with the base `onSaved` wiring) | pass |
| 2 | `…testConfirmedWriteSurvivesALaterFailedRefresh` (both suites) and `WriteAckActionMatrixTests.testFailedRefreshNeverUnreportsAConfirmedWriteForEveryNamedAction` — a failed post-write refresh keeps the confirmed result and reports the READ's error | FAIL (returned `false` + a write-shaped error) | pass |
| 2 | `…testRejectedWriteKeepsTheDataAndReportsTheRefusal`, `…testRejectedGoalsSaveKeepsTheDraftAndReportsTheRefusal`, `WriteAckActionMatrixTests.testRefusedWriteKeepsTheDayAndReportsItsOwnCopyForEveryNamedAction` — a rejection keeps the draft/row and reports its own copy, invalidating nothing | pass (preserved) | pass |
| 3 | `…testEditFinishes…TouchesOnlyThatItem` — the sibling item keeps its bytes, and the acknowledged item keeps the server's confidence while its provenance becomes the one the write owns | FAIL (blocked) | pass |
| 3 | `…testPhotoAttachFinishes…KeepsTheQueuedRowPending` — the acknowledged photo lands at the canonical object path and the unsynced row still reads `pending` | FAIL (blocked) | pass |
| 4 | `…testStalePreMutationResponseCannotUndoTheConfirmedResult` — a pass started before the write, answered with the PRE-mutation payload, is superseded, publishes nothing, and the fresh pass lands; the invalidated pass reads no cache | FAIL (blocked; the base published the pre-mutation snapshot) | pass |
| 5 | `…testDoubleTapIssuesOneMutationAndSharesItsOutcome`, `…testDoubleTapOnEdit…`, `WriteAckGoalsTests.testDoubleTapOnGoalsSaveIssuesOneMutation`, `WriteAckActionMatrixTests.testHeldDoubleTapIssuesOneWriteForEveryNamedAction`, `…testALaterTapAfterTheWriteCompletesIssuesAFreshMutation` — one mutation per acknowledged record, shared outcome, retry preserved | FAIL (two writes; the join did not exist) | pass |
| preserved | `TodayRefreshLifecycleTests.testConfirmedWriteSurvivesAFailedPostWriteRefreshAndClearsFlags` (was `…testFailedPostWriteRefreshKeepsExistingFailureContractAndClearsFlags`, which pinned the audited contract) and `JournalCalendarTests.testPastDateAddAndConfirmationReloadThatDate` (the invalidated pass still relists the same day, now bounded-waited) | — | pass |

Base run: 31 test cases, 17 failed (10/10 `WriteAckConfirmTests` cases
reported, 9 failed; 3/4 matrix cases failed; the Goals probe failed with its
three AC assertions; the rest are the pre-existing reds). Head run of every lane
suite in one invocation: exit 0, 50 cases, 0 failures, 0 timeouts. Head run of
the full native suite: 568 distinct cases, 3 failed — exactly the three
pre-existing reds (see `GATES.md`).

## Mutation battery (every defended mechanism bites)

One mutation per mechanism, focused suite each, byte-identical restores with
sha256 before/after (`mutation-battery.sh`, receipts in `excerpts/mutation-battery.txt`).
Each mutation fails the suite that defends it — without them the fixed suite
would simply pass, i.e. the tests would not be discriminating.

## Reproduce

From `app/` — every lane suite at the head (one invocation):

    flock /tmp/n.lock xcodebuild test -project Morsel.xcodeproj -scheme Morsel \
      -derivedDataPath /tmp/morsel-190-dd -resultBundlePath /tmp/morsel-190-lane-suites.xcresult \
      -parallel-testing-enabled NO -jobs 2 -test-timeouts-enabled YES \
      -maximum-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO \
      -only-testing:MorselTests/WriteAckConfirmTests -only-testing:MorselTests/WriteAckActionMatrixTests \
      -only-testing:MorselTests/WriteAckGoalsTests -only-testing:MorselTests/TodayRefreshLifecycleTests \
      -only-testing:MorselTests/TodayRefreshRegressionTests -only-testing:MorselTests/MealCorrectionsTests \
      -only-testing:MorselTests/PhotoAttachOnEditRegressionTests -only-testing:MorselTests/JournalCalendarTests \
      -only-testing:MorselTests/LocalCachePublicationOrderingTests

The base leg runs the head's base-compatible suite (`WriteAckConfirmTests`,
`WriteAckActionMatrixTests`) plus `base-probe/GoalsWiringBaseProbe.swift` against
base sources in a pristine archive (`git archive origin/staging | tar -x -C
/tmp/morsel-190-base` + `xcodegen generate`), with the lane checkout untouched and
no stash. The head Goals suite calls the new entry point, so it is head-only.

## What this evidence does NOT claim

- No physical-device, HealthKit or TestFlight verification (tracker #172);
  simulator/model evidence is never presented as physical acceptance.
- No server, migration, schema, artwork, design-system or dependency change.
- A *stored* cached day row for a synced-meal mutation is refreshed by the
  follow-up read this change invalidates; a revisit while that read is blocked
  can still first paint the pre-mutation cached payload through the local-first
  facade's cached-day path (#183/#258, outside this lane's fence). What is proven
  here: the pre-mutation RESPONSE is superseded and never published, the
  invalidating pass itself reads no cache, and the acknowledged record is on
  screen without waiting for any read.
- `joinedWrite` runs the shared write in its own unstructured task: a repeated
  tap joins it (one mutation, shared outcome). A caller cancelled mid-write no
  longer cancels the HTTP write it already issued.
- The three pre-existing reds reproduced at base and head
  (`PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll`,
  `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts`,
  `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping`)
  are not addressed by this lane.
- `addMeal`'s durable-first path is unchanged (it is the reference behavior the
  brief names), and this lane's double-tap guard covers the five actions the
  brief names, not `addMeal`.

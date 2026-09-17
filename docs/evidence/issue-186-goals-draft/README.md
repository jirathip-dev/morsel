# Issue 186 — a draft revision owns background hydration and the save acknowledgement

Lane checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-186-goals-draft`.
Base: `69a81602d6be03a2c316f85270a32ede84455d2a` (`origin/staging`).
Code commit: `ff4b32d` (`fix(goals): let a draft revision own background hydration and the save acknowledgement`);
the test bytes and the generated project land in `d7cafdc` (parent). Gate receipts and raw exits: `GATES.md`.

## Mechanism

`GoalsEditorViewModel` used to let any read replace the page: the cached first
paint, the remote context and the write completion each wrote all four fields
and all four sources. Issue #186 makes the DRAFT the owner of what it wrote.

- `editedFields` (issue #123's validation set) is also the draft's ownership
  set. `edit(_:value:)` inserts the field, marks its source manual, and bumps
  `draftRevision`.
- `apply(_:source:)` — the cached paint AND the remote context — fills only the
  fields the draft does not own. A drafted field keeps its local text even when
  it is empty or invalid, and keeps its manual source. No field is written at
  all while a save is in flight (`isSaving`), so a refresh landing on top of a
  submission cannot misreport what is being stored.
- `edit` no longer invalidates an in-flight hydration: only the pending
  direction request is dropped. A stale direction result is dropped by the
  `draftRevision` it was requested under, not by the load generation — #185's
  latest-choice ownership is unchanged.
- A chosen direction still replaces the whole draft (its numbers, its sources)
  and releases the ownership it replaces.
- `save()` snapshots `submittedRevision`; when the write lands, `didSave` is set
  only while that revision is still current. Editing again during the write
  leaves the newer revision unsaved. A completed save of the current revision
  releases ownership and bumps the generation, so hydrations requested before it
  (they carry pre-save rows) cannot repaint the fields it accepted.
- Context-level provenance is untouched: the effective goal, the superseded
  note and manual payload, the profile line, `profileDirection` and the derived
  chip still follow the read. Only the four drafted text fields are protected,
  and `edit`/`save`/`choose` do not change the read graph.

The model file stays inside the repo's SwiftLint budget (399 ≤ 400 lines) by
expressing the four fields as one read/write seam table (`goalFields`) that
`edit`, `fieldError`, `apply` and `save` all iterate, replacing the two
duplicated switches.

## Acceptance

| AC | Executed regression (native XCTest, real model methods) | At base (`69a8160`) | At head |
| --- | --- | --- | --- |
| 1 | `testPagerRevisitRefreshCannotOverwriteTheDraftAndStillFillsPristineFields` — an emptied field and invalid text survive the pager-revisit refresh; sources stay manual | FAIL `"" -> "2400.0"`, `"abc" -> "170.0"`, manual -> computed | pass |
| 1 | `testLateRemoteContextCannotOverwriteAnEditedFieldAndStillFillsPristineOnes` — the emptied field keeps its text, manual source and validation error | FAIL (the delayed context was dropped wholesale) | pass |
| 1 | `testLateCachedPaintCannotOverwriteAnEditedFieldAndStillFillsPristineOnes` — same for the cached first paint | FAIL (the cached paint never landed) | pass |
| 2 | Those three cases also assert the pristine fields take the read's value and source (`200.0/70.0`, `2100.0/210.0/75.0`, `220.0/80.0`) and that `fieldError` keeps reporting #123 validation while `isValid` stays false | FAIL (no hydration at all) | pass |
| 3 | `testEditingAgainDuringSaveLeavesTheNewRevisionUnsaved` — the edit made during the write lands as its own revision and stays unsaved; the next save is acknowledged | FAIL (`didSave = true`, `save() -> true`) | pass |
| 3 | `testRefreshDuringASaveCannotRewriteTheSubmittedValues` — a refresh on top of the in-flight write cannot rewrite the numbers being stored | FAIL `"2300.0" -> "2600.0"` | pass |
| 4 | `testLateComputeCannotOverwriteAnEditedDraft` — a parked Bulk result landing after an edit cannot replace the draft (#185 + #186 together) | pass (the #185 guard alone held) | pass |
| 4 | `testAccountChangeStartsAPristineDraftAndLateReadsStayWithTheirAccount` — the app rebuilds Goals per account (`MorselApp .id(session.userID)`): the rebuilt model starts pristine, every read is stamped with its own account, and no draft or saved state leaks across | pass | pass |

Base run: 7 tests, 2 passed / 5 failed (15 assertion failures), raw exit 65.
Head run of the same class: 7 tests, 0 failures, raw exit 0.
Head run of all twelve Goals suites in one invocation: **75 tests, 0 failures**.

#113 recency/profile, #123 validation/cache paint, #164 restore and #185
direction ownership all pass unchanged in that same invocation, and the hosted
app contracts (`app/issue-113-*`, `issue-123-*`, `issue-164-*`, `issue-185-*`
included) stay green.

## Reproduce

From `app/` — the focused regression:

    xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,id=<UDID>' \
      -derivedDataPath /tmp/morsel-186-dd -resultBundlePath /tmp/morsel-186-green3.xcresult \
      -parallel-testing-enabled NO -jobs 2 -test-timeouts-enabled YES \
      -maximum-test-execution-time-allowance 30 CODE_SIGNING_ALLOWED=NO \
      -only-testing:MorselTests/GoalsDraftRevisionTests

From `app/` — all twelve Goals suites in one invocation:

    xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,id=<UDID>' \
      -derivedDataPath /tmp/morsel-186-dd -resultBundlePath /tmp/morsel-186-goals3.xcresult \
      -parallel-testing-enabled NO -jobs 2 -test-timeouts-enabled YES \
      -maximum-test-execution-time-allowance 30 CODE_SIGNING_ALLOWED=NO \
      -only-testing:MorselTests/GoalsContextLazyLoadTests -only-testing:MorselTests/GoalsDirectionOwnershipTests \
      -only-testing:MorselTests/GoalsDirectionProfileTests -only-testing:MorselTests/GoalsDirectionRaceTests \
      -only-testing:MorselTests/GoalsDraftRevisionTests -only-testing:MorselTests/GoalsEditorPrecisionTests \
      -only-testing:MorselTests/GoalsEditorRecencyTests -only-testing:MorselTests/GoalsEditorTests \
      -only-testing:MorselTests/GoalsPageCopyTests -only-testing:MorselTests/GoalsPolishTests \
      -only-testing:MorselTests/GoalsRestoreRenderingTests -only-testing:MorselTests/GoalsRestoreTests

This lane's `xcodebuild` routes simulator actions through `hermes-sim-task`
(private simulator per run, deleted afterwards) under the shared `/tmp/n.lock`
admission; the native runs were serialized, never concurrent. `native/run.json`
records the argv, raw exits, test counts and simulator UDIDs of each run.

The base-RED run substitutes only `app/Sources/Morsel/GoalsEditorModel.swift`
(`git stash push -- <that path>`, restored and verified by SHA-256); every test
byte is the committed head byte.

## What this evidence does NOT claim

- No physical-device, HealthKit or TestFlight verification (tracker #172);
  simulator/model evidence is never presented as physical acceptance.
- No server, migration, schema, artwork, design-system or dependency change.
- No hosted CI run; the hosted app contracts were executed locally with the
  CI-aligned Node (`v22.23.2`), and the full `npm test` suite (server/db) was
  not run — only the app-contract subset named in `GATES.md`.

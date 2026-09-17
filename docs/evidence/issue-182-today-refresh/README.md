# Issue #182 — Today refresh ownership

Implementation/native-tested source commit: `ef22daba5eb3f6316d5c4293b5abeb46d71e38d9`.
Audited base: `2ddba7e0443c3d05f1345a4ce178738426144781`.
The delivery tree differs from this tested commit only in evidence additions;
`proof.json` pins the production, test and generated-project bytes independently
of that commit ID.

## Acceptance evidence

The final focused native invocation executed **29 tests, 0 failures**, raw exit
**0**, including four base-compatible regressions and eight lifecycle cases.

- **F1:** four concurrent callers of the production `DashboardViewModel.load`
  await one cache read and one authoritative read: `cache=1 reads=1 returned=4`.
  Shell, Today appearance, tab return and foreground use that entry point.
- **F2:** three committed mutations while the original read is parked yield
  `writes=3 reads=2 publications=[2400.0]`. The pre-write value is never published.
  A separate queued-meal test protects optimistic local publication.
- **F3:** cancellation releases a waiter without repository cooperation;
  supersession can publish the newer read first. Tests cover late success,
  late error, independent accounts, date changes and leaving/re-entering Today.
- **F4:** ownership/loading begins before the first-cache await. Tests cover
  teardown during that await, writes during it, duplicate-waiter cancellation,
  ordinary errors, cancellation without a user-facing error, and post-write
  refresh failures retaining the existing write-result contract.
- **F5:** continuation-controlled tests exercise production ViewModel methods,
  not a duplicate coordinator implementation. A mounted production TodayView
  paints cached content while its repository read is parked. Its refresh and
  idle captures are byte-identical; a changed-content control differs. A delete
  presentation request is accepted while the read is parked.
- **F6:** the four unchanged base-compatible tests execute against the audited
  mechanism in a disposable archive: **4 tests / 16 assertion failures, exit 65**.
  Byte-restored HEAD: **4 tests / 0 failures, exit 0**. This is behavioral RED,
  not failure to compile a newly introduced API.

## Native command and discrimination protocol

All native legs ran under one admitted `/tmp/n.lock` holder and one disposable
`hermes-sim-task` simulator. Final wrapper exit: **0** (766.22 seconds, including
453 seconds waiting for admission). The wrapper ran the focused command below,
then `python3 docs/evidence/issue-182-today-refresh/prove.py`.

From `app/`:

```sh
xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,id=7348988F-F518-40A4-B226-4E91D33D5925' -derivedDataPath /tmp/morsel-182-dd -resultBundlePath /tmp/morsel-182-native-final-r5.xcresult -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -jobs 2 CODE_SIGNING_ALLOWED=NO -only-testing:MorselTests/TodayRefreshRegressionTests -only-testing:MorselTests/TodayRefreshLifecycleTests -only-testing:MorselTests/JournalDiaryLoadTests -only-testing:MorselTests/MealCorrectionsTests -only-testing:MorselTests/DayReadCompositionTests -only-testing:MorselTests/DayReadDegradeTests -only-testing:MorselTests/TrainingFuelNilGoalRegressionTests
```

Raw native exit **0**, 109.84 seconds. This is a focused invocation, not the
unfiltered native suite. The simulator was removed by its owner wrapper.

`prove.py` creates `/tmp/morsel-182-proof-*` from `git archive HEAD`. Only
ViewModel.swift, MorselApp.swift and Views.swift are replaced by their pinned-base
versions. The new-API lifecycle file is temporarily replaced by a comment so it
cannot turn the base leg into a compile failure. The unused new coordinator
remains in the archive; base ViewModel does not call it. The four behavioral
regressions and their repository harness remain byte-identical in both legs.
This is an audited-mechanism swap, not a pristine whole-repository base build.

After RED, all replaced bytes are restored and their mtimes advanced before
GREEN. `proof.json` records exact argv/cwd, raw exits, nonzero test totals and
SHA-256 bookends: archive before = restored = after GREEN; lane before = after.
The lane itself is never mutated. RED took 142.60 seconds; GREEN took 21.18.
To repeat under a newly owned simulator, from the repository root:

```sh
flock /tmp/n.lock hermes-sim-task --name Morsel182-proof -- python3 docs/evidence/issue-182-today-refresh/prove.py
```

## Other gates and the unresolved aggregate

`gate-results.json` preserves raw receipts and durations; `results.txt` contains
selected raw output (full logs remain under the implementation lane's
`.lane-logs/`). Node used the installed 22.23.2 toolchain.

| Command | Raw exit | Result |
| --- | ---: | --- |
| `npm ci` | 0 | lockfile install |
| `npm run typecheck` | 0 | typecheck |
| `npm run lint` | 0 | lint |
| `npm test` | **1** | **663 passed, 6 failed; 56 files passed, 3 failed** |
| `npx vitest run server/http.test.ts server/render-png.test.ts server/tool-classification.test.ts` | **1** | diagnostic: 2 passed, 10 failed |
| `cd app && xcodegen generate` | 0 | regenerated for new source/test files |
| `git diff --exit-code -- app/Morsel.xcodeproj/project.pbxproj` | 0 | second generation stable in this checkout's name |
| `cd app && swiftlint --strict` | 0 | final source/test revision |
| `git diff --check` | 0 | working diff check; final delivery also checks the committed range |

The six aggregate failures were all five-second timeouts in the three listed
server files, not assertion failures. The isolation diagnostic also timed out;
there is **no green aggregate claim and no proven pristine-base attribution**.
No timeout, dependency, server code or workflow was changed. No `onTaskUpdate`
error appeared. All 18 app-contract files / 136 tests passed in that aggregate
run. These npm gates preceded the final native-only test/refresh-error refinements;
no final-head npm aggregate PASS is claimed. Hosted CI was not verified.

Earlier native attempts are retained, not silently treated as green: the first
focused run passed before the paint control was strengthened; one wrapper was
interrupted (143), another native run was terminated (-15) after a failed witness
left a continuation parked. The two subsequent runs exited 65 (29 tests / one
failure each): ImageRenderer painted only paper/date-rail, and the changed-content
control correctly rejected that empty render. The final mounted-window capture
fixed the harness without removing the control. Full raw receipts are retained.

## UI artifact provenance and limits

`today-refresh-cached.png`, `today-refresh-idle.png`, and
`today-refresh-control.png` are unmodified XCTest attachments from the successful
native run. They are 1170×2532 images from a 390×844-point scene-backed
UIHostingController, light appearance, unsigned Debug simulator build. All data
are synthetic. The fixture-clock TrainingFuelModel is synchronized and injected;
no HealthKit read is needed. A 500 ms async yield allows the paint transaction;
repository ordering is controlled by continuations, not that delay.

The same mounted window is retained across refresh and idle so taking a capture
does not remount Today and trigger another load. Exported cached and idle PNGs
are each 635,774 bytes with SHA-256
`bff464e63208ce31de5eb5cfcc1dbe9c815a46379398877d3bbd1651c355e3ef`.
Control is 571,387 bytes with SHA-256
`8221d30d0ea7069a36fb7415e041c29c70f4c2717b2b37d2acedf60b28069b49`.
The cached frame visibly contains the offline notice, retry/settings/add actions,
0 kcal eaten, the 1,700 kcal usual-day value, macros and empty meal log.

This proves component paint and presentation-model acceptance while refreshing;
it is **not** touch injection, authenticated live-app acceptance, a physical-phone
responsiveness measurement, or HealthKit/device verification.

## Scope and structural check

Production changes are confined to ViewModel.swift, MorselApp.swift, Views.swift
and the new TodayRefreshOwner.swift. Focused tests, the generated project and
this evidence complete the diff. Project regeneration includes checkout-name
resource-group churn as well as the actual new file references. Forbidden files
were not needed or modified; unrelated resource loading is independent.

```sh
ast-grep run -l swift -p '$OBJ.loadToday($$$)' app/Sources/Morsel/ViewModel.swift app/Sources/Morsel/TodayRefreshOwner.swift
```

Exit 0; exactly one match: TodayRefreshOwner.swift:97. No independent
`loadToday` call remains in ViewModel.swift. Source inspection complements, and
does not replace, the native behavioral proof above.

NOT MERGED; not opened as PR; nothing pushed to staging or main; no deploy; no production writes.

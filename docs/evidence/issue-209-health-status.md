# Issue #209 — bounded Health read-prompt status

Base: `afd6d45e642aa144af1f18000c91126889e2ab2f`.

## Production contract

`HealthKitWeightReader.authorizationStatus(for:)` now races the HealthKit
completion against an unstructured Task sleeping for two seconds. Missing
completion resolves `false`: unknown, not a claim of denied or granted access.
The callback mapping is unchanged: only `.unnecessary` means prompt answered.
The caller's cancellation cannot cancel the watchdog. A winning callback
cancels its timer; the timer's cancellation handler returns without resolving.
There is no task-group join that could wait forever for the losing callback.

`HealthStatusAnswer` protects its sole optional checked continuation with an
NSLock. Each contender atomically takes and clears it, then resumes outside the
lock. Only one contender can obtain it. `@unchecked Sendable` is justified by
that lock protecting all accesses to the stored continuation. Timeout consumes
it exactly like the callback does; late callbacks find nil and cannot resume,
change the returned answer, or run the awaiting status publication again.

## Audited status chain and neighbours

- The shell's `onSyncCompleted` callback launches a MainActor Task, awaits
  `viewModel.load()`, then awaits `refreshHealthCalmStatus`. The dashboard load
  is a separate data refresh before entry into status derivation, not an await
  inside it. The initial shell task also imports Health data independently;
  this fix makes no whole-startup/import liveness claim.
- `DashboardViewModel.refreshHealthCalmStatus` and
  `handleObserverImportError` await `updateCalmStatus` directly.
- `updateCalmStatus` has exactly two async calls: importer status for body mass,
  then active energy. Both forward to the bounded production reader. Thus two
  silent callbacks cost two sequential two-second waits, plus executor latency,
  not an indefinite wait. No status mapping or per-type branch was changed.
- `HealthKitWeightImporter.authorizationStatus` only forwards to its reader.
  Its production initializer selects `HealthKitWeightReader`; the protocol's
  default implementation for mocks returns immediately. Arbitrary injected
  implementations are not a promise about the production reader.
- The reader's only status suspension is the checked continuation above. The
  watchdog's only suspension is finite `Task.sleep`. The NSLock critical
  section has no async calls, external calls or continuation resume.
- After these awaits, the status derivation reads local upload stamps,
  `syncedKinds`, pending rows and weight-row presence synchronously.
  `LocalHealthStore` / `LocalHealthStore+SQLite` have no callback continuation
  on those reads: finite SQLite queries, statement finalization and a 2,000 ms
  SQLite busy timeout. No remote/auth request lies below status derivation.
- Adjacent `requestAuthorization`, `samples`, `activeEnergyBurned`, observer
  handlers and import gates are the separate data-import path, NOT callees of
  status derivation. Their pre-existing authorization/sample continuations
  are unchanged; this change does not bound a stalled import before a status
  refresh is reached. `TrainingFuelHealthReader` likewise reads training
  samples/statistics on a separate path, not this status chain. It is unchanged.

Structural audit command (exit 0):

```
ast-grep run -l swift -p 'await $EXPR' app/Sources/Morsel/HealthKitWeightImporter.swift app/Sources/Morsel/ViewModel.swift
```

The resulting inventory is in `.lane-logs/status-await-audit.log`. Focused
continuation searches in the ViewModel/local-store files returned no matches
(exit 1); their exact read ranges were then inspected. Structural suite
inspection used `ast-grep run -l swift -k class_declaration` on
`HealthTruthfulnessTests.swift`, `HealthReliabilityTests.swift`,
`HealthSyncCopyTests.swift`, and `WeightImportTests.swift` (exit 0). The initial
exact class-pattern search matched no declarations (exit 1), so the node-kind
query replaced it; this was not a test failure.

## Behavioural tests

The existing five `HealthStatusAsyncTests` remain intact. Two new tests use the
same scripted HKHealthStore subclass and the real production reader:

- `testNeverInvokingStatusReturnsUnknownWithinBound`: no callback, result
  `false` within a three-second outer test deadline (two-second production
  timeout plus scheduling allowance). Reports elapsed monotonic time and proves
  no callback delivered the result.
- `testBothSilentTypesFinishAndLateCallbacksCannotPublish`: two silent types
  through reader → importer → ViewModel, bounded by five seconds. Asserts the
  existing `.permissionRequired` mapping and exactly one publication. A fresh,
  answered refresh then owns `.noWeightData`; firing both old callbacks must
  leave both the state and the Combine publication array unchanged.

The outer test polls are bounded. On the old implementation they fail assertions
instead of awaiting the wedged task forever. Deferred fixture cleanup releases
old callbacks only after recording the failure; it cannot supply the asserted
result. The new tests need no timeout parameter or test-only production path.

## Recorded RED proof

The disposable tree was created with `git archive HEAD` at the base above,
under `/var/folders/4k/fbv06j2j5bbd3h4wgbwk1ccm0000gn/T/morsel-209-proof-irz8qsz7/issue-209-health-seam`.
Only the final `HealthStatusAsyncTests.swift` was overlaid; the production
reader was byte-identical to base. XcodeGen generated the archive's project.

From that tree's `app/`, the behavioral RED command was:

```
hermes-sim-task --name Morsel209-RED2 --xcodebuild -- test \
  -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -derivedDataPath /tmp/morsel-209-dd \
  -resultBundlePath /Users/jirathip/.herdr/worktrees/morsel/issue-209-health-seam/.lane-logs/native-red2.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:MorselTests/HealthStatusDeadlineTests CODE_SIGNING_ALLOWED=NO
```

The wrapper allocated only this lane's simulator
`F1324F63-9578-43AB-8DAE-F33BA44EC08D`, rewrote the destination to that UDID and
cleaned it up. Raw exit **65**, no outer harness timeout; 2 tests executed with
3 assertion failures. `.lane-logs/native-red2.log` records:

```
STATUS-CHAIN[issue-209] finished=false elapsed=5.003867167 seconds publishes=0
DEADLINE[issue-209] answer=nil elapsed=3.002233292 seconds
Executed 2 tests, with 3 failures (0 unexpected) in 8.914 (8.917) seconds
** TEST FAILED **
```

This is a behavioral failure, not a compile failure or unbounded test hang.
The initial launcher attempt (`native-red.log`) supplied an extra `xcodebuild`
token after `--xcodebuild --` and exited 65 with `Unknown build action
'xcodebuild'`, before compilation. It is retained as a launcher error, NOT RED
proof. A 60-second admission wait while a sibling native gate ran exited 75
without launching any test. No sibling process was modified.

## GREEN and byte-exact restoration

The same archive and exact same tests were used for GREEN, overlaying only the
fixed reader. Under `hermes-sim-task --name Morsel209-GREEN -- python3
.lane-logs/native_finish.py`, the wrapper-owned simulator was
`E87C4B8C-1B50-4F59-B3A1-55F3EB551781`. The archive command was:

```
xcodebuild test -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=E87C4B8C-1B50-4F59-B3A1-55F3EB551781' \
  -derivedDataPath /tmp/morsel-209-dd \
  -resultBundlePath /Users/jirathip/.herdr/worktrees/morsel/issue-209-health-seam/.lane-logs/native-green.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:MorselTests/HealthStatusDeadlineTests CODE_SIGNING_ALLOWED=NO
```

Raw exit **0**, 2 tests / 0 failures, no harness timeout. Log
`.lane-logs/native-green.log`:

```
STATUS-CHAIN[issue-209] finished=true elapsed=4.017099875 seconds publishes=1
DEADLINE[issue-209] answer=Optional(false) elapsed=2.006753375 seconds
Executed 2 tests, with 0 failures (0 unexpected) in 6.143 (6.147) seconds
** TEST SUCCEEDED **
```

The driver restored the archive reader in `finally` with its saved original
bytes and asserted equality; no production source in the real worktree was
mutated for either leg. `.lane-logs/sha256-bookends.json` records:

| Bytes | SHA-256 before and after |
| --- | --- |
| Archive base reader, restored | `e53097f3639d40fb17294714c161cb586c3841c8ab578b1bd77a10963d8b2a7e` |
| Lane fixed reader, also archive GREEN | `dfa2b52593e9cd56f76cbbd18bace1be393c10da20cbb47983d552e17c956d9c` |
| Exact test file for both legs and delivery | `b5d50b478553620f00b7fd5b7b7b64d2a6016a82b09d209e36997014245ec952` |

The original #173 tests and scripted double are byte-unchanged after removing
only the new class and its Combine import from the comparison (base test-file
SHA-256 `e57ecc8cdfc4c7e44f764346b7ed4a37e469e6696c7648f57305ffc18944e5d3`).

## Focused native gate in the delivery checkout

The same owned GREEN simulator then ran ONE focused invocation from
`/Users/jirathip/.herdr/worktrees/morsel/issue-209-health-seam/app`:

```
xcodebuild test -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=E87C4B8C-1B50-4F59-B3A1-55F3EB551781' \
  -derivedDataPath /tmp/morsel-209-dd \
  -resultBundlePath /Users/jirathip/.herdr/worktrees/morsel/issue-209-health-seam/.lane-logs/native-focused.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:MorselTests/HealthStatusAsyncTests \
  -only-testing:MorselTests/HealthStatusDeadlineTests \
  -only-testing:MorselTests/HealthTruthfulnessTests \
  -only-testing:MorselTests/HealthReliabilityTests \
  -only-testing:MorselTests/HealthSyncCopyTests \
  -only-testing:MorselTests/WeightImportTests CODE_SIGNING_ALLOWED=NO
```

Raw exit **0**, **32 tests / 0 failures** in `.lane-logs/native-focused.log`:
HealthReliability 9, HealthStatusAsync 5, HealthStatusDeadline 2,
HealthSyncCopy 6, HealthTruthfulness 4, WeightImport 6. Existing #173 heartbeat:
`beats=128 elapsed=0.8115140199661255s`. Deadline traces in this checkout:
`answer=Optional(false) elapsed=2.00771275 seconds` and
`finished=true elapsed=4.002580666 seconds publishes=1`.

`df -h /` and `pgrep -fl 'xcodebuild|xctest'` receipts precede each leg in
`.lane-logs/*admission*.log`; no admission override was used. The wrapper
finished with raw exit 0. `simctl list devices --json` subsequently confirmed
all three lane-allocated simulator IDs absent. This is a focused native gate,
not a claim of running the whole app test suite.

## Package-gate limitation

`npm ci`, `npm run typecheck`, `npm run lint`, `swiftlint --strict`,
`git diff --check` and the staged diff check all exited 0. XcodeGen generation
exited 0 and re-generation in this checkout's own name had zero project drift
(exit 0 against the staged generated project).

The full `npm test` aggregate did NOT go green:

- `.lane-logs/npm-test.log`: exit 1; 650 passed / 5 failed (655), plus one
  `[vitest-worker]: Timeout calling "onTaskUpdate"` error.
- `.lane-logs/npm-test-retry.log`: exit 1; 652 passed / 3 failed (655), plus
  the same runner-level timeout.
- Unchanged-budget isolation with `npx vitest run server/http.test.ts
  server/render-png.test.ts server/tool-classification.test.ts`:
  `.lane-logs/npm-timeout-isolation.log`, exit 1; 7 passed / 5 failed (12).

Every test failure in these runs was `Test timed out in 5000ms` in those
untouched server files; no assertion failure was reported. These match the
brief's documented #277 host-effect classes. Retry launch had no native test
process, but the later diagnostic host sample showed competing native and Rust
gates, 18.20% then 33.60% CPU idle, and load 16.06/48.97/51.12. Both full runs
passed all 54 other files. No timeout, skip, assertion or dependency was changed.
After two full attempts and one isolation attempt, the three-attempt diagnostic
breaker was reached: no further retry and no claim of a green aggregate or a
green isolation control. Hosted/quiet-host full-suite confirmation is outstanding.

## Scope and limits

Only app code, tests, generated project and this evidence are changed. The
project is regenerated by XcodeGen in `issue-209-health-seam`: its pre-existing
`..` fixture group changes from the old checkout name to this checkout name and
gets regenerated IDs. No artwork files, project.yml, dependencies, schema,
server, database or UI styling are changed. The generated project is retained,
not hand-edited or restored to pretend zero generation drift.

Simulator callback-double evidence does not verify real-device HealthKit timing,
permission presentation, physical navigation/taps or device feel. The separate
physical-device acceptance gate is unchanged. Neither the status timeout nor
these tests promise a hard real-time deadline when the process/executor is not
scheduled. No production service is contacted by these native test fixtures.

# Gate receipts — issue 263 numeric voice

Run checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-263-numeric`.
Base: `05e6314f2ebd107149c5be22f2b09f003e697948`.
There is no justfile; the brief's exact commands are the entry points.
The complete raw local logs are retained in `.lane-logs/`.

## Required static gates

| Exact command | Raw exit | Real output / log |
| --- | --- | --- |
| `npm ci` | 0 | added 256 packages, audited 257; `.lane-logs/npm-ci.log` and `npm-ci.exit.log` |
| `npm run typecheck` | 0 | `tsc --noEmit`; `.lane-logs/typecheck.log` + `.exit.log` |
| `npm run lint` | 0 | `eslint .`; `.lane-logs/lint.log` + `.exit.log` |
| `npm test` | **1** | **59 files passed / 1 failed; 672 tests passed / 1 failed (673)**; `.lane-logs/npm-test.log` + `.exit.log` |
| `cd app && swiftlint --strict` | 0 | `.lane-logs/swiftlint.log` + `.exit.log` |
| `git diff --check` | 0 | `.lane-logs/diff-check.log` + `.exit.log` |

The full JS gate is **NOT GREEN**. Its only failure is the unchanged
`server/tool-classification.test.ts`, “read-only annotated tools never write:
every read-only call leaves the full user state untouched”, with
`Error: Test timed out in 5000ms.` (5258 ms). No assertion failure occurred.
Do not interpret the passing app source contracts as a passing full suite.

The pre-run process read showed a sibling Corral xcodebuild; this npm launch was
not a quiet-host run. Nothing interrupted that lane. Admission load averages
were 7.29 / 75.80 / 111.81. Under the same unchanged timeout:

1. `npx vitest run server/tool-classification.test.ts` at candidate: raw **1**,
   4 passed / 2 timed out (read-only and cross-user cases).
2. The identical command in `/tmp/morsel-263-base/issue-263-numeric` at the pinned
   base, using symlinked unchanged dependencies: raw **1**, 4 passed / 2 timed
   out (delete and cross-user cases). The whole server subtree is base bytes.

Logs: `.lane-logs/npm-timeout-isolation.log`, `npm-timeout-base.log`, and their
`.exit.log` files. `git diff --exit-code 05e6314 -- server/tool-classification.test.ts`
returned **0**. The shifting timeouts reproduce at base; this supports a host/
baseline timing classification, not a typography assertion regression. It does
NOT establish a green gate or prove the exact contention cause. The three-run
diagnostic breaker is reached: no further npm retry, no raised timeout, no skip,
no changed Vitest concurrency or test budget.

`npm ci` also reported 5 existing dependency vulnerabilities (4 moderate, 1 high)
and the existing deprecated eslint warning. Dependencies were not changed.

## Native command provenance

The three focused app-hosted XCTest runs each executed **1 test / 0 failures**:

| Leg | Raw xcodebuild exit | Seconds | Command and raw output |
| --- | --- | --- | --- |
| SwiftUI alignment | 0 | 256.42 | `alignment/run.json`, `alignment/raw-output.txt` |
| After surfaces | 0 | 287.98 | `after/run.json`, `after/raw-output.txt` |
| Pinned-base surfaces | 0 | 349.89 | `before/run.json`, `before/raw-output.txt` |

Every `run.json` records the complete actual argv and UDID. Common argv, run
from that checkout's app directory:

    xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,id=<recorded UDID>' -derivedDataPath /tmp/morsel-263-dd -resultBundlePath /tmp/morsel-263-<recorded label>.xcresult -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO -only-testing:MorselTests/<recorded class>

Each native command was inside `hermes-sim-task` after atomic `/tmp/n.lock`
admission with a 60-second bound. `pgrep -fl 'xcodebuild|xctest'` and `df -h /`
preceded the legs. No other simulator, cache, pane or host setting was modified.

Launcher diagnostics, not behavioral test failures:

- The initial `flock -w 60 /tmp/n.lock ...` launcher was rejected before native
  testing: `flock: unsupported option -w (shim accepts a lock path only)`.
  Its old background process receipt is no longer available, so no numeric raw
  exit is asserted for that launcher. `admit.py` uses the documented atomic
  directory protocol instead.
- After the AFTER capture had passed and exported its attachments, the outer
  zsh shell exited **1** on `status=$?` (`read-only variable: status`). The
  Python runner had already persisted the actual xcodebuild raw **0** receipt;
  that is the result used above. Subsequent wrappers use `rc`.
- Early SwiftLint runs found a `for_where` diagnostic in the alignment probe
  and then a long capture-helper line. Both were fixed structurally; the final
  strict run is raw **0** without rule changes or suppressions.

## Focused contracts and RED/GREEN proof

    npx vitest run app/numeric-voice-contract.test.ts app/training-day-row-contract.test.ts

Raw **0**, 2 files / 7 tests passed (`.lane-logs/contract.log`).

A one-line temporary mutation changed only the real JournalFoodRow energy font
at size 14 from `morselNumber` back to `morselMono`:

    npx vitest run app/numeric-voice-contract.test.ts

Raw **1**, 2 passed / 2 failed (`.lane-logs/mutation-mono.log`): the real consumer
pin failed and the inventory rejected the unclassified site. The saved original
was restored and `shasum -a 256 -c .lane-logs/mutation-original.sha256` returned
`app/Sources/Morsel/JournalFoodRow.swift: OK`. Re-running that exact command gave
raw **0**, 4 passed (`.lane-logs/mutation-restored.log`). This is a semantic
regression proof, not a build-failure RED.

## Evidence validation

    python3 docs/evidence/issue-263-numeric-voice/verify.py
    python3 docs/evidence/issue-263-numeric-voice/inventory.py --check

Both raw **0**. Actual output:

    PASS: 64 original PNG hashes/dimensions; 26 complete before/after pairs
    Surfaces per theme: 11; scroll frames per theme: 2
    Remaining mono inventory matches: 9 kept sites; 7 deliberate declaration/helper exceptions

`source-provenance.json` pins all 91 before/after production source files and
the identical capture driver. Exactly 17 production source files differ, all
font-only. An ICC-aware audit of all 52 before/after frames passed the Paper/
Night corner check within one quantization level; see `theme-audit.json`.

## Structural exploration (actually invoked)

- `ast-grep run -p '$BASE.font($FONT)' -l swift app/Sources/Morsel/JournalFoodRow.swift`
  exited **0**, identifying seven Text-font sites (four old mono readouts).
  Raw output: `.lane-logs/ast-row.log`.
- `ast-grep outline app/Sources/Morsel/DayDrillDown.swift app/Sources/Morsel/GoalsEditor.swift`
  exited **0**, identifying DayDrillDown, GoalDirection, GoalsView and
  GoalJournalField. Raw output: `.lane-logs/outline.log`.
- `ast-grep outline app/Sources/Morsel/HistoryLedgerViews.swift app/Sources/Morsel/Models.swift app/Sources/Morsel/WeightDelta.swift app/Sources/Morsel/MenuEditorSheet.swift`
  exited **0**; `.lane-logs/outline-capture.log`. WeightDelta.swift was not a
  matched file; the ledger/model/menu declarations supplied the fixture map.
- Initial unqualified `morselMono($$$)` found no useful output; the qualified
  `Font.morselMono(size: $SIZE)` found the token definition. No source rewrite
  was performed by ast-grep.

Frozen-surface check:

    git diff --exit-code 05e6314 -- app/Sources/Morsel/TrainingFuelViews.swift app/Sources/Morsel/FoodArtwork.swift app/Resources/FoodArt app/Sources/Morsel/MorselApp.swift app/Sources/Morsel/ViewModel.swift

Raw **0**. No production data, schema, Health policy, app behavior or artwork edits.

## Final native/regeneration receipt

The unfiltered native invocation exited **65**: xcresult reports **485 passed,
2 failed, 1 skipped / 488 total**. XCTest's text summary counts the two failed
cases as **3 assertion failures**. Exact argv/UDID: `final-native.json`; raw
failure lines: `final-native-output.txt`; machine counts: `final-native-summary.json`.
The new NumericVoiceTests passed in this whole-suite order. The opt-in screenshot
test is intentionally skipped; its separate before/after runs above passed.

The failed cases are:

- `PageIdentityTests/testRevisitKeepsHistoryRangeExpandedDayAndScroll`: seed has
  no HistoryDay after dropping its first three entries (`XCTUnwrap`, line 224).
- `SharedButtonTargetTests/testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping`:
  GoalsEditor.swift has an uncompensated button call; 14 call sites vs the pin's
  expected 13 (lines 98/103). Neither the button code nor the failing tests was
  edited by this typography lane. Changing button geometry is expressly forbidden.

This is **not a green full-native gate**, and the existing visual/scroll/perf
suite's whole-green requirement is not claimed. A focused pinned-base diagnostic
was attempted with these two filters:

    -only-testing:MorselTests/PageIdentityTests/testRevisitKeepsHistoryRangeExpandedDayAndScroll
    -only-testing:MorselTests/SharedButtonTargetTests/testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping

It did **not** reach xcodebuild: admission exited **124** after the allowed
60 seconds (`ADMISSION_TIMEOUT=60s; no native command launched`). The shared
lock remained busy with sibling work; it was not bypassed or removed. This is
an admission blocker, not a base test verdict. The runtime baseline comparison
therefore remains **UNVERIFIED**. Raw receipts:
`.lane-logs/native-base-diagnostic-wrapper.log` and its `.exit.log`.

`git diff --exit-code 05e6314 -- app/Tests/MorselTests/PageIdentityTests.swift app/Tests/MorselTests/SharedButtonTargetTests.swift app/Sources/Morsel/GoalsEditor.swift app/Sources/Morsel/HistoryViewModel.swift app/Sources/Morsel/MockRepository.swift`
returned **0**. These input bytes are unchanged, but that read-only comparison
does not substitute for a native base run. No unrelated test or geometry was
changed to turn either failure green.

Unfiltered pre-existing tests emitted their hard-coded legacy temporary evidence
paths (for example `/tmp/morsel-174-evidence`, `/tmp/morsel-175-evidence` and
`/tmp/morsel-227-evidence`). These are inherited fixture outputs, not new lane
runner paths; they were not cleaned or repurposed. All new lane tooling uses
`/tmp/morsel-263-*`.

Final regeneration: `cd app && xcodegen generate` raw **0**;
`git diff --exit-code -- app/Morsel.xcodeproj/project.pbxproj` raw **0** against
the staged generated project in this exact checkout name. The project includes
both new tests; its existing checkout-derived group IDs account for the unrelated
generator churn. `git diff --cached --check` raw **0** includes every new artifact.
Logs: `.lane-logs/xcodegen-final.log`, `xcodegen-drift.log`,
`staged-diff-check.log`, and their `.exit.log` receipts.

NOT MERGED; not opened as PR; nothing pushed to staging or main; no deploy; no production writes.

# Issue #180 — cached History and day publication

## Delivery status

Implementation and executable regressions are present. Native acceptance is NOT
verified: both bounded native admission windows refused to launch while sibling
`xcodebuild` processes were active. No simulator was created and no native build
or test was run. These refusals are not test failures or a RED proof.

Pinned base: `55f700677e3cdd010d950c68cbc7d03fce3604cf`.
Checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache`.
Branch: `issue/180-history-cache-paint`.

## Changes and scope

- History first awaits the existing cache-only read, publishes that content, then
  independently awaits remote refresh. The day drill-down does the same.
- Selection generations guard both cache and remote completions. Range changes
  synchronously clear the previous overview/day; a stale completion cannot clear
  the newer operation's loading flag. Local-day/zone request identity guards
  publication after a timezone change.
- History payloads reuse the existing optional `DayReadProvenance` representation.
  SQLite fallback marks them cached without inventing a successful-read time.
  Existing payloads remain decodable. Cancellation is not an offline failure and
  cancelled successful reads do not overwrite the cache.
- Existing History/day content now carries a saved-data/refresh notice; refresh
  errors remain visible alongside cached content rather than replacing it.
- `HistoryViewModel` moved from `HistoryView.swift` into an adjacent file to stay
  within the 400-line source budget. Its unrelated calculations are unchanged.
  The cached-History method moved into the existing repository extension to keep
  the class under its 250-line budget. No cache schema or account-store redesign.
- Regenerated `project.pbxproj` includes the new model/tests and the normal
  checkout-basename-derived group IDs. It was not hand-edited or restored after
  generation; repeated generation in this checkout produces zero unstaged drift.

Files deliberately not changed: `DesignSystem.swift`, calendar/diary surfaces,
artwork assets/resolvers, numeric-voice code, Today view model, account-service
assembly, database/server/schema/migrations, dependencies and package lock.

## Acceptance status

| AC | Implementation and intended behavioural witness | Verified status |
|---|---|---|
| F1 | `HistoryCachePaintTests.testCachedOverviewAndMealsPublishWhileRemoteIsHeld` composes the real SQLite facade and real view model; both cache assertions occur while remote continuations are parked. `HistoryCacheStateTests` covers cold-cache skeleton/error state. | Native execution blocked; not claimed PASS. |
| F2 | `HistoryCacheSelectionTests` covers range change, day switch, collapse, late cache and late remote completions, and loading ownership. | Native execution blocked; not claimed PASS. |
| F3 | `HistoryCacheStateTests` covers persisted cache reopening, offline/timeout fallback, unchanged successful-read provenance, retry success, non-cooperative cancellation and transport cancellation. | Native execution blocked; not claimed PASS. |
| F4 | `HistoryCacheScopeTests` uses distinct account SQLite files and different day/range keys; changes the process-local default timezone with restoration while remote calls are held. The production account-scoped store assembly remains unchanged. | Native execution blocked; not claimed PASS. |
| F5 | Base-compatible paint regression and disposable archive prepared. | NOT MET: no behavioural RED/GREEN result. |
| F6 | Existing `HistoryFreezeRegressionTests` is unchanged and selected in the native gate. | NOT VERIFIED. |

The new tests use synthetic content, actor-owned continuation handshakes,
bounded three-second observations/completion waits and fixture drain on teardown.
No production reads/writes, user content, tokens, signed URLs or real Health data.
No physical-iPhone feel/timing or rendered-pixel claim is made.

## Executed gates

Raw logs and per-command exit records are retained in checkout-local
`.lane-logs/`, not committed. Commands below run from the checkout root unless
an `app/` working directory is stated.

| Command | Raw exit and observed output |
|---|---|
| `npm ci` | 0; `.lane-logs/npm-ci.log` |
| `npm run typecheck` | 0; `.lane-logs/typecheck.log` |
| `npm run lint` | 0; `.lane-logs/lint.log` |
| `npm test` | 1; 57 passed / 2 failed files; 667 passed / 2 failed tests, 669 total; one unhandled `[vitest-worker]: Timeout calling "onTaskUpdate"`. Both failures were unchanged `server/http.test.ts` / `server/tool-classification.test.ts` 5000 ms timeouts. `.lane-logs/npm-test.log` |
| `npx vitest run server/http.test.ts server/tool-classification.test.ts` | 0; 2 files / 10 tests passed with unchanged budgets; diagnostic isolation only, not the aggregate gate. `.lane-logs/npm-timeout-isolation.log` |
| `npm test` (required rerun) | 1; 55 passed / 4 failed files; 663 passed / 6 failed tests, 669 total; two `onTaskUpdate` errors. Five server tests exceeded 5000 ms; one unchanged PostgreSQL test exceeded 30000 ms. `.lane-logs/npm-test-rerun.log` |
| `npx vitest run db/postgres-integration.test.ts server/http.test.ts server/render-png.test.ts server/tool-classification.test.ts` | 1; 1 passed / 3 failed files; 7 passed / 7 failed tests; one `onTaskUpdate` error. Both PostgreSQL tests passed; seven server tests still exceeded 5000 ms. `.lane-logs/npm-rerun-isolation.log` |
| `git diff --check` | 0; `.lane-logs/diff-check.log` |
| `cd app && xcodegen generate` | 0; `.lane-logs/xcodegen-app.log` and `xcodegen-stability.log` |
| `git diff --exit-code -- app/Morsel.xcodeproj/project.pbxproj` after staging generated output and regenerating | 0; `.lane-logs/xcodegen-drift.log` |
| `cd app && swiftlint --strict` | 0; `Done linting! Found 0 violations`; `.lane-logs/swiftlint-bounded-tests.log` |

The aggregate gate is NOT green. Observed failures are timeout-only and match
known runner/server host-effect classes from the brief; the PostgreSQL timeout
passed in diagnostic isolation. The first two-file isolation passed, while the
later larger isolation also timed out. This is not a waiver or a pristine-base
comparison. No assertion, budget, worker setting or test was weakened/skipped.

Initial diagnostics retained: SwiftLint first exited 2 for three introduced
format/size violations, then those were corrected and strict lint passed. An
initial XcodeGen launcher used the repository root and exited 1 (no project spec);
it was corrected to `app/`. Neither initial attempt is counted as a green gate.

## Native admission and missing RED/GREEN

Both `python3 .lane-tools/native.py base-red` and the subsequent
`python3 .lane-tools/proof.py` exited 75 before native execution. Each sampled
`pgrep -fl 'xcodebuild|xctest'` three times, with bounded 60-second waits.
The second window followed completion of the bounded-test harness edits.
The competing processes belonged to other lanes (Morsel #209 and Corral #557).
No sibling process, pane, simulator, scratch directory or admission control was
touched. Logs: `base-red-admission.log` and `battery-admission.log`.

The prepared proof driver is retained locally at `.lane-tools/proof.py`. It is
not evidence of execution. Its proposed native command is:

```sh
xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=<owned SIMULATOR_UDID>' \
  -derivedDataPath /tmp/morsel-180-dd -parallel-testing-enabled NO \
  -resultBundlePath '<lane-log>/<leg>.xcresult' CODE_SIGNING_ALLOWED=NO \
  -only-testing:MorselTests/HistoryCachePaintTests
```

The GREEN leg additionally selects `HistoryCacheStateTests`,
`HistoryCacheSelectionTests`, `HistoryCacheScopeTests`,
`HistoryFreezeRegressionTests`, `MealReliabilityTests` and
`DayReadCompositionTests`. `hermes-sim-task` owns and cleans the proposed private
simulator. It has NOT been invoked by this lane because admission never cleared.

A disposable `git archive HEAD` of the pinned base exists at
`/tmp/morsel-180-base/issue-180-history-cache`. Only base-compatible synthetic
paint-test files were overlaid. The prepared driver saves fixed bytes, restores
base sources only in that archive for RED, restores fixed bytes in `finally`,
and compares SHA-256 bookends; none of that driver mutation/native sequence has
executed. There is therefore NO byte-restore-after-test or native count claim.
The initial base SHA-256 identities were recorded in `base-bookends.json`:

- `HistoryView.swift`: `2e8391d4ca1417de9d4ab45094fcab4e368c96331be0f8dc11638f1fad5300af`
- `LocalFirstRepository.swift`: `4bc83813066d18eb3372731b0a8d84209595ca8a5f4ae047833abc6fa9220969`

## Structural exploration receipt

Preferred structural tool was actually invoked (not inferred from skill loading):

```sh
ast-grep run --pattern 'func $NAME($$$ARGS) async throws -> $RET { $$$BODY }' --lang swift app/Sources/Morsel/LocalFirstRepository.swift
```

Exit 0; matched the remote-first `loadToday`, `loadHistory`, cache and goal methods,
identifying the fallback boundary that would otherwise incorrectly appear fresh.

```sh
ast-grep run --pattern '$R.cachedToday($$$ARGS)' --lang swift app/Sources app/Tests
```

Exit 0; located the existing Dashboard cache-first consumer and reliability tests.
`cachedHistory` call search had no matches before the fix; `DayDrillDown` structural
search found the existing content-before-skeleton branch. A narrow HistoryOverview
pattern specifying only `Codable` missed its multi-protocol declaration, so the
exact named `HistoryModels.swift` file was read directly. No broad source sweep,
new dependency, global tool installation or invented just recipe was used.

NOT MERGED; not opened as PR; no deploy; no production writes.

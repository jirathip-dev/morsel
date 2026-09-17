# Gate receipts — issue 192 (observer imports are incremental)

Lane checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-192-health-delta`.
Base: `f712ce0ed73f2a75bbc2335769c92f53b37e728e` (`origin/staging`).
Code/test commit: `0610b24` (evidence commits follow it; the final head SHA is in
`.report.md`). There is no justfile; the brief's commands are the entry points.
Complete raw logs live in the checkout's `.lane-logs/` (gitignored); the
committed excerpts under `excerpts/` are the same bytes with trailing
whitespace stripped. Machine-readable receipts: `native/run.json`.

## Required gates

| Exact command | Raw exit | Actual result | Evidence |
| --- | --- | --- | --- |
| base repro: pristine `git archive origin/staging` at `/tmp/morsel-192-base` + the base-probe overlay, `flock /tmp/n.lock xcodebuild test -project Morsel.xcodeproj -scheme Morsel -derivedDataPath /tmp/morsel-192-base-dd … -only-testing:MorselTests/BoundedObserverProbeTests` | **65** | 1 test, **2 assertion failures**, `ISSUE192-PROBE windows=["nil", "nil"] rows=[1, 1]` — the shipped observer path issues another unbounded query on a no-change notification | `excerpts/base-probe-red.txt`, `native/run.json` |
| base known-reds leg (same pristine archive, no fix): `-only-testing` MealReliabilityTests PageIdentityTests ParallelReadsTests SharedButtonTargetTests | **65** | 30 tests, **5 assertion failures in 4 cases**: `PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll`, `PageIdentityTests.testRetargetMidSwingKeepsOnePagePerTab` (flaky), `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts`, `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping` (2 assertions). `MealReliabilityTests` **passed** at base | `excerpts/base-known-reds.txt` |
| head focused leg, one invocation (final bytes): HealthDeltaImportTests HealthEnergyDeltaTests WeightImportTests HealthReliabilityTests HealthStatusAsyncTests HealthTruthfulnessTests HealthSyncCopyTests LocalStoreTests MealReliabilityTests | **0** | **TEST SUCCEEDED**, 65 tests, 0 failures, 0 timeouts; `HealthDeltaImportTests` 6/6, `HealthEnergyDeltaTests` 6/6, `MealReliabilityTests` 13/13 | `excerpts/head-focused.txt`, `native/run.json` |
| head full native suite, one unfiltered invocation (final bytes), `-derivedDataPath /tmp/morsel-192-dd` | **65** | main launch **584 tests / 3 skipped / 5 assertion failures** — the three pre-existing reds above plus the `MealReliabilityTests` load flake (passes focused at head, passed at base); the lane's health suites all green. Two evidence-capture tests (`ArtworkIdentitySurfaceTests`, `TrainingFuelEvidenceTests`) exceeded the 60 s allowance but **PASSED**; the runner restarted and re-ran a 49-test subset green | `excerpts/head-full-native.txt`, `native/run.json` |
| `swiftlint lint --strict` (repo root; SwiftLint 0.65.1, config `included: app`) | **0** | 0 violations | `excerpts/swiftlint.txt` |
| `cd app && xcodegen generate` then `git diff --exit-code` (run AFTER committing the regenerated project) | **0** / **0** | regenerated project byte-stable in this checkout | `excerpts/xcodegen-stability.txt` |
| `git diff --check` (worktree) and `git diff --check <base>..HEAD` | **0** / **0** | no whitespace errors in the worktree or the committed range | `excerpts/diff-check.txt` |
| `mise exec node@22 -- npm ci` | **0** | dependencies installed from the committed lockfile | `excerpts/npm-ci.txt` |
| `mise exec node@22 -- npx vitest run app` (node `v22.23.2`) | **0** | 21 files / **153 tests**, hosted app contracts green (including the ViewModel/MorselApp source pins and the ≤400-line pin) | `excerpts/hosted-app-contracts.txt` |
| mutation battery — one structural mutation per defended mechanism, focused suite each, every file restored byte-identically (sha256) | **65** each | 4 mutations, every one bites its focused suite; restores verified | `excerpts/mutation-battery.txt` |

## Pre-existing reds (base-with-fix-out evidence)

Reproduced in the pristine base archive and again at head in the same class list:

| Test | base | head |
| --- | --- | --- |
| `PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll` | fail | fail |
| `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts` | fail | fail |
| `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping` | fail (2 assertions) | fail (2 assertions) |
| `PageIdentityTests.testRetargetMidSwingKeepsOnePagePerTab` | fail (flaky, order-dependent) | pass |
| `MealReliabilityTests.testOfflineAddMealCommitsLocallyAndPaintsPendingRow` | pass | pass focused; fails only inside the full run (load flake) |

## Native artifacts

`xcodebuild` test actions route through `hermes-sim-task` (a private throwaway
simulator per invocation, deleted after the run) under the shared `/tmp/n.lock`
admission, so the native runs above were serialized, never concurrent.
`native/run.json` records each invocation's argv, raw exit, main-launch summary,
assertion-failure count, allowance warnings and failing cases.

The head legs use `-derivedDataPath /tmp/morsel-192-dd` as the brief requires.
The base archive legs use `/tmp/morsel-192-base-dd`: the same target/scheme
names in a second project would otherwise share build products inside one
derived-data directory, and a base leg could silently run head-built bundles.

## Generated project note

`app/Morsel.xcodeproj/project.pbxproj` is xcodegen output. Besides the four new
files (one source, three test), the regenerated diff renames the group that
represents the `..` resource path
(`../docs/evidence/issue-241-artwork-native/fixtures`): xcodegen names that group
after the **checkout directory**, so the committed base carried an earlier lane's
name and this lane's regeneration carries `issue-192-health-delta`. Nothing under
that group changed, and the stability gate above re-ran `xcodegen generate` in
this checkout with `git diff --exit-code` = 0.

## Superseded intermediate legs (not evidence)

While the lane was converging, earlier head legs ran on intermediate bytes
(`head-focused1`/`head-focused2`: test-target compile errors; `head-focused3`:
one expectation on the first energy test, fixed before the final bytes;
`head-full-native`: the pre-split test bytes). Their logs stay in the gitignored
`.lane-logs/`; none of them is cited by `native/run.json` or packaged here. The
cited runs are `base-probe-red`, `base-known-reds`, `head-focused`,
`head-full-native` and the mutation battery.

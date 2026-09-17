# Gate receipts — issue 190 (a confirmed mutation finishes on its own acknowledgement)

Lane checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-190-write-ack`.
Base: `83010c8f4288b6c7f636fd287920dd06b1d62d59` (`origin/staging`).
Code commit / test+evidence commit: see `README.md`.
There is no justfile; the brief's commands are the entry points. Complete raw logs
live in the checkout's `.lane-logs/` (gitignored); the committed excerpts under
`excerpts/` are the same bytes with trailing whitespace stripped. Machine-readable
receipts (argv, raw exits, counts, simulators): `native/run.json`, `hosted/run.json`.

## Required gates

| Exact command | Raw exit | Actual result | Evidence |
| --- | --- | --- | --- |
| base leg: the head's base-compatible suite + Goals probe + the three known-red suites, built against base sources in a pristine archive (`git archive origin/staging \| tar -x -C /tmp/morsel-190-base`) | **65** | 31 test cases, **17 failed**, 70 assertion-level failures: `WriteAckConfirmTests` 9/10 cases failed, `WriteAckActionMatrixTests` 3/4, `GoalsWiringBaseProbeTests` 1/1 — every named action awaited the parked dashboard read and every confirmed write was reported `false`; the remaining failures are the three pre-existing reds | `excerpts/base-red-final.txt` |
| focused head leg, one invocation: `WriteAckConfirmTests WriteAckActionMatrixTests WriteAckGoalsTests TodayRefreshLifecycleTests TodayRefreshRegressionTests MealCorrectionsTests PhotoAttachOnEditRegressionTests JournalCalendarTests LocalCachePublicationOrderingTests` | **0** | **TEST SUCCEEDED**, 50 test cases, 0 failures, 0 timeouts — every lane suite green | `excerpts/head-lane-suites.txt`, `native/run.json` |
| the same leg extended with `PageIdentityTests ParallelReadsTests SharedButtonTargetTests` (the three known pre-existing reds) | **65** | 67 test cases, 64 passed / 3 failed, **0 failures outside the three pre-existing reds** | `excerpts/head-canonical.txt` |
| full unfiltered native suite, one invocation (no `-only-testing`) | **65** | **568 distinct test cases, 3 failed** (the same three pre-existing reds); two evidence-capture tests passed beyond the 60 s allowance (91.6 s / 67.7 s) and the runner re-ran a 49-test subset green | `excerpts/head-full-native.txt` |
| `swiftlint lint --strict` (repo root; SwiftLint 0.65.1, config `included: app`) | **0** | 0 violations (190 Swift files) | `excerpts/swiftlint.txt` |
| `cd app && xcodegen generate` then `git diff --exit-code` | **0** / **0** | regenerated project byte-stable in this checkout | `excerpts/xcodegen-stability.txt` |
| `git diff --check` (worktree) and `git diff --check <base>..HEAD` (final head) | **0** / **0** | no whitespace errors in the worktree or the committed range | `excerpts/diff-check.txt` |
| `mise exec node@22 -- npm ci` | **0** | dependencies installed from the committed lockfile | `excerpts/npm-ci.txt` |
| `mise exec node@22 -- npx vitest run app` (node `v22.23.2`) | **0** | 21 files / **153 tests**, hosted app contracts green (including the ViewModel/MorselApp source pins and the ≤400-line pin) | `excerpts/hosted-app-contracts.txt` |
| mutation battery — one mutation per defended mechanism, focused suite each, every file restored byte-identically (sha256) | **65** each | every mutated mechanism fails its suite; see `excerpts/mutation-battery.txt` | `excerpts/mutation-battery.txt` |

## Pre-existing reds (base-with-fix-out evidence, not caused by this lane)

Reproduced at base in the pristine archive and at head in the same invocations:

| Test | base | head |
| --- | --- | --- |
| `PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll` | fail | fail |
| `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts` | fail | fail |
| `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping` | fail (2 assertions) | fail (2 assertions) |
| `ParallelReadsTests.testHistoryAndGoalsContextOverlapAndKeepBaselineValues` | exceeded the 1-minute allowance (infrastructure hang, pre-existing) | not hit |
| `PageIdentityTests.testRetargetMidSwingKeepsOnePagePerTab` | fail (flaky, order-dependent; absent in the head leg) | pass |

## Native artifacts

The lane's `xcodebuild` runs route simulator actions through `hermes-sim-task`
(a private simulator per invocation, deleted after the run) under the shared
`/tmp/n.lock` admission: the native runs above were serialized, never concurrent.
`native/run.json` records the argv, raw exits, test counts and the simulator
UDIDs each invocation used, with the host load average recorded either side.

## Generated project note

`app/Morsel.xcodeproj/project.pbxproj` is xcodegen output. Besides the four new
test files and the one new source file, the regenerated diff renames the group
that represents the `..` resource path
(`../docs/evidence/issue-241-artwork-native/fixtures`): xcodegen names that group
after the **checkout directory**, so the committed base carried
`issue-186-goals-draft` (the lane that last regenerated it) and this lane's
regeneration carries `issue-190-write-ack`. Nothing under that group changed —
its only referenced files are the unchanged `issue-241-artwork-native/fixtures`
PNGs — and the stability gate above re-ran `xcodegen generate` in this checkout
with `git diff --exit-code` = 0.

## Superseded intermediate legs (not evidence)

While the lane was converging, earlier head legs ran on intermediate bytes
(`head-focused1` compile error, `head-focused2` the regressions that rewrote
`confirmedWrite` and two retargets, `head-focused3` / `head-focused-final` /
`head-matrix` green on pre-split test bytes) and `red1-base-focused` was killed
mid-build on purpose. Their logs stay in the gitignored `.lane-logs/`; none of
them is cited by `native/run.json` or packaged here. The five cited runs — and
only those — are `base-red-final`, `base-red-focused`, `head-lane-suites`,
`head-canonical`, `head-full-native`.

## Evidence-recovery invocation (disclosed)

The first base leg (`excerpts/base-red-diagnostic.txt`) used the pre-split test
bytes: its tenth case awaited the base mechanism directly and therefore hit the
runner's 1-minute allowance instead of failing an assertion. The case was
rewritten around the same bounded waits as the rest of the suite (timeouts are
infrastructure, never assertions) and the canonical base leg above re-ran the
final bytes — 10/10 cases reported, all failures assertion-level, no timeouts in
the lane's own suites.

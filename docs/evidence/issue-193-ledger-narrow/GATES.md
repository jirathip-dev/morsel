# Gate receipts — issue 193 (narrow typed ledger read)

Lane checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-193-ledger-narrow`.
Base: `a79491186f29e44de7adb1a447d9dee254d3379a` (`origin/staging`).
Test commit (the RED bytes): `e3130003e98edfc15f6917875374a6fe16880fff`.
Fix commit: `04bef2e12d6efdb53ac3f26de7138d5e663be7ae` (evidence commits follow;
the final head SHA is in `.report.md`).
There is no justfile; the brief's commands are the entry points. Complete raw
logs live in the checkout's `.lane-logs/` (gitignored); the committed excerpts
under `excerpts/` are the same bytes with trailing whitespace stripped.
Machine-readable receipts: `native/run.json`.

## Required gates

| Exact command | Raw exit | Actual result | Evidence |
| --- | --- | --- | --- |
| RED — base production code, committed test bytes: `flock /tmp/n.lock xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/morsel-193-dd -only-testing:MorselTests/LedgerNarrowReadTests` | **65** | 6 tests, **8 assertion failures**, all inside the two transfer tests: the base requests `["id","eaten_at","meal_type","source","image_path"]` and the 16-column `mealItemColumns`; the byte receipts are narrow==baseline (561/561, 1763/1763) | `excerpts/red-base-narrow-tests.txt` |
| GREEN — same command at head | **0** | **TEST SUCCEEDED**, 6 tests, 0 failures; `ISSUE193-BYTES` receipts: multiple meals 337/561 and 378/1763; named-menu 85/141 and 151/863 | `excerpts/green-head-narrow-tests.txt`, `native/run.json` |
| head focused leg, one invocation: the same command with `-only-testing` LedgerNarrowReadTests ParallelReadsTests HistoryCachePaintTests HistoryCacheScopeTests HistoryCacheStateTests HistoryFreezeRegressionTests LocalDayBucketTests | **65** | 32 tests, **1 failure** — the pre-existing `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts`; 31/32 green including all 6 new tests and `ParallelReadsTests.testHistoryAndGoalsContextOverlapAndKeepBaselineValues` | `excerpts/head-focused-history-ledger.txt` |
| base-with-fix-out leg — same class list, base `HistoryRepository.swift` restored (`git show e313000:…`), sha256 recorded before/after and verified | **65** | 32 tests, **14 failures in 3 cases**: the two RED transfer cases **plus** the same pre-existing `ParallelReadsTests` red — the fix removes the two transfer failures and changes nothing else | `excerpts/base-known-reds.txt` |
| `swiftlint lint --strict` (repo root; SwiftLint 0.65.1, config `included: app`) | **0** | 0 violations in 205 files | `excerpts/swiftlint.txt` |
| `cd app && xcodegen generate` then `git diff --exit-code app/Morsel.xcodeproj/project.pbxproj` (run AFTER committing the regenerated project) | **0** / **0** | regenerated project byte-stable in this checkout | `excerpts/xcodegen-stability.txt` |
| `git diff --check` (worktree) and `git diff --check a794911..HEAD` | **0** / **0** | no whitespace errors in the worktree or the committed range | `excerpts/diff-check.txt` |
| `mise exec node@22 -- npm ci` | **0** | dependencies installed from the committed lockfile | `excerpts/npm-ci.txt` |
| `mise exec node@22 -- npx vitest run app` (node v22.23.2) | **0** | 21 files / **153 tests**, hosted app contracts green | `excerpts/hosted-app-contracts.txt` |
| mutation battery — one structural mutation per defended mechanism, focused suite each, every file restored byte-identically (sha256) | **65** each | M1 (`ledgerMealItemColumns = mealItemColumns`): 6 failures, bites both transfer tests. M2 (`ledgerMealItemColumns = "meal_log_id"`): 8 failures, bites the parity + DST tests. Restores verified, tree clean vs HEAD | `excerpts/mutation-battery.txt` |

## Pre-existing red (base-with-fix-out evidence)

| Test | base (fix out) | head |
| --- | --- | --- |
| `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts` | fail | fail |

Reproduced with the lane's production file reverted to the base content in the
same checkout (sha256-verified restore), same class list, separate derived-data
path (`/tmp/morsel-193-base-dd`). #192's `GATES.md` recorded the same red at
that base. Not caused by this lane; not fixed here (out of fence).

## Native artifacts

`xcodebuild` test actions route through `hermes-sim-task` (a private throwaway
simulator per invocation, deleted after the run) under the shared
`/tmp/n.lock` admission, so the native runs above were serialized and never
concurrent with another heavy native gate. Head legs use
`-derivedDataPath /tmp/morsel-193-dd` as the brief requires; the base leg uses
`/tmp/morsel-193-base-dd` so base-built products can never be confused with
head-built ones. `native/run.json` records each invocation's raw exit, test
count, failure count and failing cases.

## Generated project note

`app/Morsel.xcodeproj/project.pbxproj` is xcodegen output. Besides the two new
test files, the regenerated diff renames the group that represents the `..`
resource path (`../docs/evidence/issue-241-artwork-native/fixtures`): xcodegen
names that group after the **checkout directory**, so the committed base
carried `issue-192-health-delta` and this lane's regeneration carries
`issue-193-ledger-narrow`; one resource file reference (`coffee-photo.png`)
also normalised to the id xcodegen derives today. Nothing under those groups
changed, and the stability gate re-ran `xcodegen generate` in this checkout
with `git diff --exit-code` = 0.

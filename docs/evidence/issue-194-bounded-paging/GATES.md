# Gate receipts — issue 194 (bounded paging for dense collection reads)

Lane checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-194-bounded-paging`.
Base: `1cf9ecc26b56037b53b34cc611425043bf21a36d` (`origin/staging`).
Test commit (the RED bytes) and fix commit: see `.report.md` (evidence commits
follow the fix commit; the head that includes this file is in `.report.md` too).
There is no justfile; the brief's commands are the entry points. Complete raw
logs live in the checkout's `.lane-logs/` (gitignored); the committed excerpts
under `excerpts/` are the same bytes with trailing whitespace stripped.
Machine-readable receipts: `native/run.json`.
Every native action runs through the shared `/tmp/n.lock` admission (never
concurrent with another lane's heavy native gate) with
`-derivedDataPath /tmp/morsel-194-dd` (the shared derived-data volume is not
writable on this host).

## Required gates

| Exact command | Raw exit | Actual result | Evidence |
| --- | --- | --- | --- |
| RED — base production code (fix stashed), final committed test bytes: `flock /tmp/n.lock xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/morsel-194-dd -only-testing:MorselTests/BoundedPagingTests -only-testing:MorselTests/BoundedPagingBoundaryTests` | **65** | 16 tests, **51 failures** — the capped server answers 3 of 7 meals, the 120-id list goes out as one request, no read pages | `excerpts/red-base-paging.txt` |
| GREEN — head, the same focused command | **0** | 16 tests, 0 failures | `excerpts/green-head-paging.txt` |
| Head repository/menu classes, one invocation (18 `-only-testing` classes incl. both new suites) | **65** | 92 tests, 1 skipped, **1 failure** — the pre-existing `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts` | `excerpts/head-focused-repository-menus.txt` |
| Base leg, same classes, `git stash` of the three seam files | **65** | 76 tests, 1 skipped, **the same single failure** with the fix out of the tree (pre-existing, not this lane's) | `excerpts/base-known-reds.txt` |
| Full unfiltered native suite (one complete invocation) | **65** | 630 tests, 3 skipped, **4 assertion failures in 3 tests**, all pre-existing reds (`PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll`, `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts`, `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping`); both new suites pass inside it | `excerpts/head-full-native.txt` |
| Mutation battery (head): M1 drop the `id` tie-break, M2 drop the clamp adoption, M3 drop the identity dedupe | **65 / 65 / 65** | M1 bites `testPageRequestsCarryStableOrderingAndTieBreakers`; M2 bites 14 completeness/boundary cases; M3 bites `testBoundaryDuplicateIsDeduplicatedAndNotDoubleCounted`; every file restored byte-identically (sha256 before/after) | `excerpts/mutation-battery.txt` |
| `swiftlint lint --strict --quiet` | **0** | 0 violations | `excerpts/swiftlint.txt` |
| `cd app && xcodegen generate` then `git diff --exit-code -- app/Morsel.xcodeproj/project.pbxproj` | **0** | the committed project already carries the four new files; regeneration is byte-stable in this worktree | `excerpts/xcodegen-stability.txt` |
| `git diff --check 1cf9ecc..HEAD` and `git diff --cached --check` | **0** | no whitespace errors in any commit (including the committed evidence logs) | `excerpts/diff-check.txt` |
| `npm ci` (lane worktree) | **0** | dependency install for the hosted gates | `excerpts/npm-ci.txt` |
| `npx vitest run app` | **0** | 21 files, 153 tests, 0 failures (incl. the retargeted raw-token contract, `BoundedReadPaging.swift` allowlisted with the documented rationale) | `excerpts/hosted-app-contracts.txt` |

## Not a gate (recorded for honesty)

- The first RED attempt (`.lane-logs/red-base-paging-pre-fixture-fix.txt`) is
  kept: it exposed a fixture id-format bug (a 9-character first UUID group for
  numbers ≥ 10). The fixture was fixed and both recorded legs re-run with the
  final bytes.
- Hosted timeouts under sibling-lane load are not asserted here: the native
  suite ran through the shared lock, and `npx vitest run app` passed 153/153.

# Gates — raw commands and exits

Lane worktree: `/Users/jirathip/.herdr/worktrees/morsel/issue-196-responsiveness`
Base: `659055d` (`origin/staging`). Simulator `Morsel196-iPhone17`
(`DACB0B66-9BE1-458E-8ABF-FC74BA1C9942`), iOS 26.5 (23F77). Derived data
`/tmp/morsel-196-dd`.

| gate | command | raw exit | evidence |
| --- | --- | --- | --- |
| focused native classes | `HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath /tmp/morsel-196-dd CODE_SIGNING_ALLOWED=NO -only-testing:MorselTests/ResponsivenessShellCycleTests -only-testing:MorselTests/ResponsivenessBudgetTests -only-testing:MorselTests/ResponsivenessIntervalsTests` | **0** (11 tests, 0 failures) | `excerpts/baseline-focused.txt`, `mutations/excerpts/green-*.txt`, `.lane-logs/196-final-focused.log` |
| SwiftLint strict | `swiftlint lint --strict` (repo root; config `.swiftlint.yml`, `included: app`) | **0** (0 violations, 219 files) | `.lane-logs/196-final-swiftlint.log` |
| XcodeGen stability | `cd app && xcodegen generate && git diff --exit-code -- Morsel.xcodeproj/project.pbxproj` | **0** (empty diff after the regenerated project is committed) | this file |
| `git diff --check` (own commits) | `git diff --check 659055d..HEAD` | **0** (empty) | this file |
| hosted app contract suite | `npx vitest run app/` | **0** (20 files, 142 tests, 0 failures) | `.lane-logs/196-final-app-contracts.log` |
| full hosted suite (context) | `npm test` | see the log; Docker/colima is not running on this host, so the Postgres-backed suites cannot execute here | `.lane-logs/196-npm-test.log` |
| full native suite (context) | `… xcodebuild test …` without `-only-testing` | **65** — 651 tests, 3 skipped, **5 failures, all pre-existing** (see below) | `.lane-logs/196-full-native-2.log` |

## Pre-existing native reds (base-reproduced, not caused by this lane)

The lane's diff adds only NEW test files and the generated project; no
production file is touched (`git status --short app/Sources/` is empty at the
delivered head, and the mutation-battery sha256 receipts prove the audited
files are byte-identical to the committed bytes). The full-suite failures were
reproduced in a PRISTINE detached worktree at the lane base `659055d`, with the
same four assertion failures and exit 65:

| test | base worktree (`659055d`) | head |
| --- | --- | --- |
| `PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll` | fails | fails |
| `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts` | fails | fails |
| `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping` | fails (2 assertions) | fails (2 assertions) |
| `MealReliabilityTests.testOfflineAddMealCommitsLocallyAndPaintsPendingRow` | load-sensitive | fails in the full run, **passes** in a focused re-run (`.lane-logs/196-preexisting-focused.log`) |

Commands: base leg `git worktree add --detach /tmp/morsel-196-base 659055d` +
the same four `-only-testing` filters (log `.lane-logs/196-base-preexisting.log`,
exit 65, 4 tests / 4 failures); head focused leg the same way (exit 65, 4
failures in the same three deterministic tests, `MealReliabilityTests` passing).

## Notes

- The regenerated `app/Morsel.xcodeproj/project.pbxproj` carries the new test
  files plus the documented `..`-rooted evidence-group rename (the group is
  named after the checkout directory). It is committed so the XcodeGen gate is
  empty in this worktree; `xcodegen generate` is byte-stable within a worktree.
- `-derivedDataPath` MUST stay under `/tmp`: the shared `/Volumes/NVMe2TB`
  volume is not writable (error 513) and a bare run fails at exit 74 for that
  reason alone, not for a code reason.
- One heavy native leg at a time (`flock /tmp/n.lock`).

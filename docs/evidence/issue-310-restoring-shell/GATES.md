# Issue 310 — gate ledger (raw exits and where the logs are)

Every command below ran inside
`/Users/jirathip/.herdr/worktrees/morsel/issue-310-restoring-shell` (worktree `pwd` verified first),
under `flock /tmp/n.lock` for the native legs, with `-derivedDataPath /tmp/morsel-310-dd`. Full logs
stay in the lane's gitignored `.lane-logs/`; the committed receipts are in `excerpts/`.

| gate | command | raw exit | log |
|---|---|---|---|
| focused native family | `xcodebuild test … -only-testing:RestoringShell{Routing,Phase,Render,SkeletonPaint,Evidence}Tests` | **0** (19 tests, 0 failures) | `.lane-logs/310-focused-r5.log`, `excerpts/focused-family.txt` |
| AC6 capture run | `xcodebuild test … -resultBundlePath /tmp/morsel-310-evidence.xcresult -only-testing:MorselTests/RestoringShellEvidenceTests` | **0** (1 test, 0 failures; 12 attachments exported) | `.lane-logs/310-evidence-run.log`, `excerpts/evidence-run.txt` |
| one complete unfiltered native run | `xcodebuild test …` (no filter), head | **65** (643 tests / 3 skipped / 5 failures — 4 distinct tests, all pre-existing or load-sensitive) | `.lane-logs/310-native-full-head.log`, `excerpts/native-full-head.txt` |
| load-sensitive candidate, focused | `-only-testing:MorselTests/MealReliabilityTests` | **0** (13 tests, 0 failures) | `.lane-logs/310-mealreliability-focused.log` |
| base RED (compile) | base worktree `f1d657b` + all new test files | **65** (`'Phase' is not a member type of class 'Morsel.SessionStore'`) | `.lane-logs/310-base-compile-red.log`, `excerpts/red-base-compile.txt` |
| base RED (assertion) | base worktree, `-only-testing:MorselTests/RestoringShellRoutingTests` | **65** (5 tests / 10 failures) | `.lane-logs/310-base-routing-red.log`, `excerpts/red-base-routing.txt` |
| pre-existing reds, fix absent | base worktree, the three documented reds | **65** (3 tests / 4 failures) | `.lane-logs/310-base-preexisting-reds.log`, `excerpts/base-with-fix-absent.txt` |
| mutation (route on the session alone) | head worktree, restoring branch removed, `RestoringShellRoutingTests` + `RestoringShellRenderTests` | **65** (routing 1 failure, render 6 failures) | `.lane-logs/310-mutation-session-only.log`, `excerpts/mutation-session-only.txt` |
| mutation restore, re-run | same classes after the byte-identical restore (`sha256 cd900bd4…`) | **0** (8 tests, 0 failures) | `.lane-logs/310-mutation-session-only-rerun.log`, `excerpts/mutation-restored-green.txt` |
| retargeted hosted probe | `npx eslint app/unauth-action-tint.test.ts` / `npx vitest run …` | **0** / **0** (7 tests) | `.lane-logs/310-hosted-focused.log`, `excerpts/hosted-probe.txt` |
| hosted suite | `npm test` | **1** (701 tests, 2 failures — both `Test timed out in 5000ms`, `grep -c AssertionError` = 0; both files pass 10/10 with `--testTimeout=60000`, diagnostic only) | `.lane-logs/310-npmtest-full.log` |
| lint / typecheck | `npm run lint` / `npm run typecheck` | **0** / **0** | `.lane-logs/310-lint-typecheck.log` |
| swiftlint | `swiftlint lint --strict` | **0** (no findings) | `.lane-logs/310-swiftlint.log`, `excerpts/gates.txt` |
| XcodeGen stability | `cd app && xcodegen generate` then `git diff --exit-code app/Morsel.xcodeproj` | **0** (regenerated project committed; no drift afterwards) | `excerpts/gates.txt` |
| whitespace / EOF hygiene | `git diff --check <base>..HEAD` | **0** | `excerpts/gates.txt` |

The three pre-existing native reds at this base are
`PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll`,
`ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts` and
`SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping`; they
fail identically with the fix absent (`base-with-fix-absent.txt`), so this lane neither caused nor
weakened them.

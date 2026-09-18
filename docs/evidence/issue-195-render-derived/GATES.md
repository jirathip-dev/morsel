# Issue #195 — gates, exact commands and raw exits

All commands run inside `/Users/jirathip/.herdr/worktrees/morsel/issue-195-render-derived`.
Native runs used `-derivedDataPath /tmp/morsel-195-dd`, one heavy native leg at a time
(`flock /tmp/n.lock`) because a sibling lane (issue-194) ran native gates concurrently.
Lane simulator: `morsel-195-render` = `D792C926-779C-4B5C-B54F-E7BC49464282`
(iPhone 17, iOS 26.5 runtime, Debug build). The shared `/Volumes/NVMe2TB` derived-data volume is
not writable in this lane (error 513 / exit 74), hence the `/tmp` path.

| # | gate | command | raw exit | excerpt |
| --- | --- | --- | --- | --- |
| 1 | baseline probe (pre-change) | `HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath /tmp/morsel-195-dd -only-testing:MorselTests/RenderDerivedProbeTests` | 0 (4 tests / 0 failures) | `excerpts/195-baseline-probe.txt` |
| 2 | focused head (probe + durable suite) | same, `-only-testing:MorselTests/RenderDerivedProbeTests -only-testing:MorselTests/RenderDerivedReuseTests` | 0 (10 tests / 0 failures) | `excerpts/195-head-probe.txt` |
| 3 | base leg — durable suite at base | `bash docs/evidence/issue-195-render-derived/tools/base-legs.sh $UDID` (scratch worktree `/tmp/m195-base-leg` at `1cf9ecc`) | 65 (compile: `no member 'derivedScanCount'`) | `excerpts/195-base-durable.txt` |
| 4 | base leg — probe at base | same driver, second leg | 0 (4 tests / 0 failures) | `excerpts/195-base-probe.txt` |
| 5 | mutation battery | `bash docs/evidence/issue-195-render-derived/tools/mutation-battery.sh $UDID` | m1 65 / m2 65 / m3 65 / m4 65 (each leg fails) | `excerpts/195-mutation-battery.txt` |
| 6 | full native suite (one complete unfiltered invocation) | `HERDR_XCODEBUILD_DIRECT=1 flock /tmp/n.lock xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath /tmp/morsel-195-dd` | 65 (624 tests / 3 skipped / 5 failures — all pre-existing or the documented full-run flake; the lane's own suites are green) | `excerpts/195-full-native.txt` |
| 7 | SwiftLint strict (whole repo) | `swiftlint lint --strict` | 0 (208 files, 0 violations) | `excerpts/195-swiftlint.txt` |
| 8 | hosted app contracts | `npx vitest run app/` | 0 (20 files / 142 tests) | `excerpts/195-contracts.txt` |
| 9 | XcodeGen stability | `(cd app && xcodegen generate)` then `git diff --exit-code -- app/Morsel.xcodeproj/project.pbxproj` | 0 (no diff) | `excerpts/195-xcodegen.txt` |
| 10 | whitespace gate | `git diff --check <base>..HEAD` | 0 | `excerpts/195-diffcheck.txt` |
| 11 | Time Profiler attempt | `xcrun xctrace record --attach <test-host pid> --template 'Time Profiler' ...` | 21 twice ("Cannot find process for provided pid"); no trace | `excerpts/195-xctrace.txt` |

# Issue #180 — verification round 3: behavioural RED/GREEN and #136 regressions

## Verdict and scope

**#180 is now F1–F6 AC-complete.** The previously accepted implementation was
not changed. F5 now has an assertion-level base RED and a fixed-source GREEN;
F6's two required classes executed successfully. This is not a physical-device
performance claim or a claim that the previously red JavaScript aggregate has
become green.

- Pinned base: `55f700677e3cdd010d950c68cbc7d03fce3604cf`.
- Tested head: `8b4852c988aaf244c198ad2a8805022ff479fbf7`.
- Implementation commit: `4216a223c607acebd87e87edf4c6c891203fcf04`.
- Branch: `issue/180-history-cache-paint`.
- Checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache`.
- This delivery adds only this evidence file. Its resulting tip is recorded in
  the untracked round-3 report and verified against the remote after push.

All production, test, and generated-project bytes remained unchanged in the
lane. All test overlays and XcodeGen operations happened in disposable archive
trees, never in the lane checkout. Previous reports and evidence were preserved.

## Results from actual native invocations

| Acceptance leg | Raw native exit | Actual XCTest result | Command duration |
|---|---:|---|---:|
| F5 base RED | 65 | 1 failing test case; 2 expected assertion failures | 264.82 s |
| F5 fixed GREEN and F1–F4 coverage | 0 | 11 tests; 0 failures | 147.01 s |
| F6 existing #136 regressions | 0 | 10 tests; 0 failures | 11.77 s |

Every invocation above recorded `timed_out=false`. No build failure, admission
refusal, filtered-out test run, or wrapper result is counted as behavioural RED.

### Exact base-RED command

Working directory: `/tmp/morsel-180-verify-r3/issue-180-history-cache`.

```sh
xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=A9E032FF-B905-4F55-9041-9916C7794161' \
  -derivedDataPath /tmp/morsel-180-verify-r3/derived-data \
  -parallel-testing-enabled NO \
  -resultBundlePath /Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache/.lane-logs/verify-r3/base-red.xcresult \
  CODE_SIGNING_ALLOWED=NO -only-testing:MorselTests/HistoryCachePaintTests
```

Raw log: `.lane-logs/verify-r3/base-red.log`; raw exit **65**.

The unchanged base-compatible test uses the real local-first repository and
cache, seeds both overview and meals, holds the remote continuations, and
asserts publication before releasing those continuations. The base compiled
and reached the two intended assertions in
`testCachedOverviewAndMealsPublishWhileRemoteIsHeld`:

```text
HistoryCachePaintTests.swift:17: XCTAssertEqual failed: ("nil") is not equal to ("Optional(7)") - cache must paint before remote completion
HistoryCachePaintTests.swift:18: XCTAssertEqual failed: ("nil") is not equal to ("Optional(100.0)") - cached meals must paint before remote completion
Executed 1 test, with 2 failures (0 unexpected) in 0.584 (0.585) seconds
** TEST FAILED **
```

These are two failed assertions in **one failing test case**, not two failing
test cases. They establish the audited remote-first publication mechanism for
both the overview and selected-day meals. Only `HistoryCacheTestSupport.swift`
and `HistoryCachePaintTests.swift` were added to base; base production sources
were unchanged. The other three cache test classes are fixed-source coverage,
not additional base-RED witnesses.

### Exact fixed-GREEN command

Working directory: `/tmp/morsel-180-verify-r3-resume/issue-180-history-cache`.

```sh
xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=CF17DFBA-A8EC-4A51-B019-1F7336E54D7D' \
  -derivedDataPath /tmp/morsel-180-verify-r3/derived-data \
  -parallel-testing-enabled NO \
  -resultBundlePath /Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache/.lane-logs/verify-r3-resume/fixed-green.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MorselTests/HistoryCachePaintTests \
  -only-testing:MorselTests/HistoryCacheStateTests \
  -only-testing:MorselTests/HistoryCacheSelectionTests \
  -only-testing:MorselTests/HistoryCacheScopeTests
```

Raw log: `.lane-logs/verify-r3-resume/fixed-green.log`; raw exit **0**.

```text
Test Suite 'MorselTests.xctest' passed
Executed 11 tests, with 0 failures (0 unexpected) in 0.159 (0.163) seconds
** TEST SUCCEEDED **
```

Class counts: paint 1, scope 3, selection 3, state 4. The same cache-before-remote
test that failed at base passed unchanged. The other tests cover cold-cache
skeleton/error states, refresh failures and truthful freshness, cancellation,
range/day/collapse supersession, account/day/range scoping, and timezone change.

### Exact F6 command

Working directory: `/tmp/morsel-180-verify-r3-resume/issue-180-history-cache`.
After GREEN, the full archive was restored and its SHA-256 bookends verified.
The identical fixed app inventory was then reapplied for F6.

```sh
xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=CF17DFBA-A8EC-4A51-B019-1F7336E54D7D' \
  -derivedDataPath /tmp/morsel-180-verify-r3/derived-data \
  -parallel-testing-enabled NO \
  -resultBundlePath /Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache/.lane-logs/verify-r3-resume/f6-regressions.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MorselTests/HistoryFreezeRegressionTests \
  -only-testing:MorselTests/PaperDeleteAndSkeletonTests
```

Raw log: `.lane-logs/verify-r3-resume/f6-regressions.log`; raw exit **0**.

```text
Test Suite 'HistoryFreezeRegressionTests' passed at 2569-09-17 4:46:49.780 AM.
Executed 4 tests, with 0 failures (0 unexpected) in 0.012 (0.013) seconds
Test Suite 'PaperDeleteAndSkeletonTests' passed at 2569-09-17 4:46:49.823 AM.
Executed 6 tests, with 0 failures (0 unexpected) in 0.011 (0.043) seconds
Test Suite 'MorselTests.xctest' passed at 2569-09-17 4:46:49.823 AM.
Executed 10 tests, with 0 failures (0 unexpected) in 0.023 (0.057) seconds
** TEST SUCCEEDED **
```

The four History tests actually executed were:

- `testCancelledLedgerReadIsSupersededWithinTwoSeconds`
- `testCollapseSupersedesInFlightDayRead`
- `testStaleDayReadCannotOverwriteNewerDaySelection`
- `testTenFastTabSwitchesNeverStickOnLoadingState`

The six paper-dialog/skeleton tests also executed, rather than merely being
left unchanged. Counts above use the target-level XCTest summary; nested
summaries were not added together.

## Admission, interruption, and bounded resumption

This was **not one uninterrupted battery**. The native task was queued before
other verification work. The requested window had already been taken by a
Corral gate when the first lock acquisition ran. No competing build was started.

First driver, from the lane checkout:

```sh
python3 .lane-tools/verify_r3.py
```

It executed this lock-owned chain:

```sh
flock /tmp/n.lock python3 /Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache/.lane-tools/verify_r3.py --locked
hermes-sim-task --name morsel-180-verify-r3 -- python3 /Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache/.lane-tools/verify_r3.py --locked
```

Lock acquired after **744 s**. The base RED executed, but the first fixed-GREEN
and F6 admission cycles each returned **75** after three samples with 60-second
waits. Neither refused leg launched XCTest. Driver/lock raw exit **1**, duration
**1342.38 s**, no timeout. Those refusals remain recorded in
`.lane-logs/verify-r3/legs.json` and their admission logs.

Cause: raw `pgrep -fl 'xcodebuild|xctest'` matched Corral's queued flock command
text containing future xcodebuild commands. At the diagnostic sample, our
lock owner was PID `92060`; matched sibling PID `65450` had only `sleep 5`
PID `22601` beneath it. It was waiting for our lock, not running a native gate.
The full process evidence is `.lane-logs/verify-r3/waiter-classification.json`.
No sibling process was signalled and no lock was removed to obtain admission.

After the first driver completed its archive restoration and simulator cleanup,
the missing GREEN/F6 legs were resumed, preserving the valid base RED:

```sh
python3 .lane-tools/verify_r3_resume.py
flock /tmp/n.lock python3 /Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache/.lane-tools/verify_r3_resume.py --locked
hermes-sim-task --name morsel-180-verify-r3-resume -- python3 /Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache/.lane-tools/verify_r3_resume.py --locked
```

The local admission classifier was made descendant-aware only for a proven
same-lock waiter with exclusively sleep descendants; unknown matches remain
blocking. **No classifier exception was needed for the successful resumed
runs:** the raw pgrep exit was **1** at wrapper admission, fixed-GREEN admission,
and F6 admission; each record has `ignored_waiters=[]`, `blockers=[]`, and
`ADMISSION=PASS`. Each also ran `df -h /` with raw exit 0 and exceeded the
unchanged 3 GiB free-space guard.

Resume lock acquired after **567 s**. Lock/driver raw exit **0**, duration
**787.95 s**; simulator wrapper raw exit **0**, duration **220.89 s**. The lock
covered the complete resumed battery, not separate unprotected commands.
The native child deadline remained 1200 s per invocation; no deadline expired.

Both simulators were private, created and removed by `hermes-sim-task`.
Independent post-run `xcrun simctl list devices --json` readback confirmed
both recorded UDIDs absent. All scratch trees and DerivedData were confined
to this lane's `/tmp/morsel-180-*` directories. The resume reused only the
completed first run's own DerivedData; the two runs did not overlap.

## Archive provenance and byte-exact restoration

Actual archive command, raw exit **0**:

```sh
git archive --format=tar --output=/tmp/morsel-180-verify-r3/base.tar 55f700677e3cdd010d950c68cbc7d03fce3604cf
```

The resume copied that saved base tar, extracted a fresh disposable tree, and
required its original inventory digest to match the first run's base digest.
Both runs verified all 496 tracked fixed app entries against the lane bytes,
not merely the intentionally changed files. `xcodegen generate` ran in each
disposable app directory; base, initial fixed, and resumed fixed raw exits were
**0**, **0**, **0**. Both fixed generations were required to preserve the
complete fixed app inventory, including the generated project.

Each inventory records relative paths, individual file SHA-256 values and
modes, or symlink targets. Inventory SHA-256 is over UTF-8 JSON serialized with
`sort_keys=True, separators=(',', ':')`.

| Inventory | Entries | Identical before/after SHA-256 |
|---|---:|---|
| Entire base archive, in both runs | 1905 | `2d3d7db7f1a51ec27cd52180af088639618d83270dcd51ca0a3def301ae58429` |
| Fixed archive app and untouched lane app | 496 | `457e0dc454a68b79e69af45222d90277aeed7426913a1ff1485537ac7961e3be` |

Base production `app/Sources` also remained unchanged during RED:
`53c029383744bd2015e499a23244beef97e80748b9c6ff4099deca6db127c323` at both bookends.

The complete archive, including removal of added tests and generated changes,
was restored after fixed GREEN **before F6**, then restored again in `finally`
after F6. Deletion required each run's ownership marker. Both final bookend
records say `archive_restored_exact=true` and `lane_unchanged=true`.
An independent after-run inventory comparison also passed, raw exit **0**.

Evidence directories, relative to the lane checkout:

- `.lane-logs/verify-r3/`: base RED log/result bundle, initial refusals,
  process-classification receipt, archive/app manifests, bookends and raw exits.
- `.lane-logs/verify-r3-resume/`: GREEN/F6 logs/result bundles, admission logs,
  manifests, `f5-restoration.json`, final bookends, `exits.jsonl`, and
  `independent-verification.json`.

The original README, `verification-r2.md`, and round-1/round-2 reports were
independently SHA-256 checked and stayed byte-identical. Their historical
blocker statements are retained as historical results, not rewritten.

## Acceptance and limits

- F1: PASS — seeded cached overview/meals publish while remote is held;
  the same witness fails at base and passes at fixed sources. Cold-cache state
  coverage passes in the fixed-state suite.
- F2: PASS — cache and remote supersession tests pass for range, day and collapse.
- F3: PASS — failure/cancellation/freshness tests pass without hiding cached data.
- F4: PASS — account/day/range and timezone tests pass.
- F5: PASS — behavioural base RED, fixed GREEN, full archive restore and SHA-256
  bookends executed; distinct simulator/run identities are disclosed above.
- F6: PASS — the four History freeze regressions and six paper/skeleton tests pass.

No production/test/project changes, test weakening, dependency changes,
physical-device capture, PR, merge, deploy, or production writes occurred.
Protected diary/calendar, design-system, artwork and server/DB files were not
touched. `npm test` was deliberately not rerun: #277 owns its known runner
flake class. The previous nonzero JavaScript aggregate remains disclosed;
this native evidence does not convert it into a passing aggregate. Hosted CI
and physical-iPhone feel/timing were not verified in this round.

NOT MERGED; not opened as PR; no deploy; no production writes.

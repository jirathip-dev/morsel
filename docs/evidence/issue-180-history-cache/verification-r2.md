# Issue #180 — verification round 2: admission blocked

## Verdict

**#180 is NOT AC-complete and is not mergeable.** F1–F4 remain accepted as
implemented at code commit `4216a223c607acebd87e87edf4c6c891203fcf04`. F5 has no
behavioural RED or GREEN result, and F6 has no executed regression result.
Every native leg was refused before `xcodebuild` launched.

This is a new verification record, not a replacement for the original README
or round-1 report. No production source, test, project, dependency, or gate
policy changed. This round adds only this evidence file.

Base: `55f700677e3cdd010d950c68cbc7d03fce3604cf`.
Branch: `issue/180-history-cache-paint`.
Checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache`.
The final delivery tip is an evidence-only descendant of the code commit;
its exact SHA is in the untracked round-2 report and remote readback.

## Actual execution and raw exits

The verification-only local driver reuses `.lane-tools/run.py` to retain raw
child exit codes, timeouts, exact argv, working directories, and durations.
It never substitutes a pipeline exit for a command exit.

From the lane checkout:

```sh
python3 .lane-tools/verify_r2.py
```

Driver exit: **1**, not a native-test failure. The child wrapper ran:

```sh
hermes-sim-task --name morsel-180-verify-r2 -- python3 /Users/jirathip/.herdr/worktrees/morsel/issue-180-history-cache/.lane-tools/verify_r2.py
```

Wrapper raw exit: **1**, `timed_out=false`, duration **433.63 seconds**.
The wrapper created private simulator `B33F88A8-1DA0-4B06-9185-36ED0099B3CB`.
A post-run `xcrun simctl list devices --json` readback returned
`owned_simulator_present=False`: wrapper cleanup removed it.

| Step actually executed | Working directory | Raw exit |
|---|---|---:|
| `git archive --format=tar --output=/tmp/morsel-180-verify-r2/base.tar 55f700677e3cdd010d950c68cbc7d03fce3604cf` | Lane checkout | 0 |
| `xcodegen generate` for the base plus unchanged paint tests | `/tmp/morsel-180-verify-r2/issue-180-history-cache/app` | 0 |
| F5 base-RED admission cycle | Same disposable tree | 75; native not launched |
| `xcodegen generate` for fixed sources | Same disposable app directory | 0 |
| F5 fixed-GREEN admission cycle | Same disposable tree | 75; native not launched |
| F6 regression admission cycle | Same disposable tree | 75; native not launched |

Test counts: **no XCTest execution in any of the three legs**. A nonzero failing
test count, behavioural assertion failure, and passing native count cannot be
reported. Admission exit 75 is neither RED nor GREEN.

All raw records are in checkout-local `.lane-logs/verify-r2/`:
`exits.jsonl`, `wrapper.log`, `archive.log`, `base-xcodegen.log`,
`fixed-xcodegen.log`, `legs.json`, and the four `*-admission.log` files.
The three `*-refused.json` records each say
`{"raw_exit": 75, "native_executed": false}`. Logs remain untracked.

## Bounded admission observations

Before simulator setup and before each native leg, the driver executed:

```sh
df -h /
pgrep -fl 'xcodebuild|xctest'
```

Each cycle sampled at most three times with 60-second waits. There were
**12 samples total**: three for wrapper admission and three for each native
leg. Wrapper admission passed on its third sample (`pgrep` raw exit 1), but
another sibling invocation started before base-RED admission. Every native
leg's three samples returned `pgrep` raw exit 0 with a competing process.
No admission bypass, sibling signal, shared-simulator use, or concurrent
lane-local `xcodebuild` occurred. The three refused native cycles exhaust
this round's bounded retries; no indefinite watcher was left running.

Raw representative competing process from the base-RED admission log:

```text
88232 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project ios/FleetNotifier.xcodeproj -scheme FleetNotifier -configuration Debug -destination platform=iOS Simulator,id=F224BA44-7A1B-4720-AEEB-FF9D40FF7188 -derivedDataPath /tmp/rev557-dd CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -only-testing:FleetNotifierTests/HerdTests/testHorseCaptionLabelWiresPositiveGitMarkers test
```

The fixed-GREEN cycle observed that invocation and then this successor; F6
observed this successor on all three samples:

```text
96006 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project ios/FleetNotifier.xcodeproj -scheme FleetNotifier -configuration Debug -destination platform=iOS Simulator,id=186A5759-6F2F-48F0-BED5-E7FFE9C14FA8 -derivedDataPath /tmp/rev557-dd CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -only-testing:FleetNotifierTests/HerdTests/testHorseGitAccessibilityWordsAndAbsence test
```

Each native admission log ended with these raw lines:

```text
ADMISSION=WAIT (competing native process or less than 3 GiB free)
ADMISSION=REFUSED raw_exit=75
```

Disk was checked throughout; the refusal cause was competing native processes,
not the driver's 3 GiB free-space guard. All recorded free-byte values exceeded
that guard. No other lane's files or scratch directories were reclaimed.

## Prepared commands — NOT executed

The following is the resolved native command the driver would have issued
only after admission. It is recorded for reproducibility, not as a run claim:

```sh
xcodebuild test -project app/Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=B33F88A8-1DA0-4B06-9185-36ED0099B3CB' \
  -derivedDataPath /tmp/morsel-180-verify-r2/derived-data \
  -parallel-testing-enabled NO \
  -resultBundlePath '<checkout>/.lane-logs/verify-r2/<leg>.xcresult' \
  CODE_SIGNING_ALLOWED=NO <selection>
```

Working directory for every leg was the disposable archive tree, never the
lane checkout. A future run needs a new owned simulator because this one was
deleted. Selection was prepared as follows:

- `base-red`: `-only-testing:MorselTests/HistoryCachePaintTests`.
- `fixed-green`: the same paint class, plus
  `-only-testing:MorselTests/HistoryCacheStateTests`,
  `-only-testing:MorselTests/HistoryCacheSelectionTests`, and
  `-only-testing:MorselTests/HistoryCacheScopeTests`.
- `f6-regressions`: `-only-testing:MorselTests/HistoryFreezeRegressionTests`
  and `-only-testing:MorselTests/PaperDeleteAndSkeletonTests`.

The existing History freeze class includes the four required behaviours:
cancelled-ledger supersession within two seconds, ten rapid tab switches,
stale-day suppression, and collapse supersession. These files were not edited.
No assertion was weakened, no timeout was increased, and no test was skipped
to manufacture an acceptance result.

## Archive restoration and SHA-256 bookends — executed

Unlike the refused round-1 proof, archive preparation and restoration did run:

1. Extract the pinned base's `git archive` into the fresh owned directory
   `/tmp/morsel-180-verify-r2/issue-180-history-cache`.
2. Record every archive file's SHA-256/mode (or symlink target).
3. Copy only unchanged `HistoryCacheTestSupport.swift` and
   `HistoryCachePaintTests.swift` for base compatibility, then regenerate the
   disposable project. Base production bytes remain unmodified.
4. After base admission refused, overlay the reviewed head's app delta only in
   the archive. Assert all **496 tracked app entries** equal the lane's bytes;
   regenerate and assert zero project drift. Fixed-GREEN and F6 admission then
   refused without test execution.
5. In `finally`, verify the run-created ownership marker, remove only the
   disposable checkout, and extract the same saved base archive again.
   Compare the entire restored inventory with the original.
6. Verify all tracked lane app entries remained byte-identical throughout.

The inventory digest is SHA-256 of the UTF-8 JSON manifest serialized with
`sort_keys=True, separators=(',', ':')`. Each ordinary-file entry contains its
own SHA-256 and mode. Bookends are in `.lane-logs/verify-r2/bookends.json`;
full before/after manifests are alongside it.

| Inventory | Entries | Before and after SHA-256 (identical) |
|---|---:|---|
| Complete base archive | 1905 | `2d3d7db7f1a51ec27cd52180af088639618d83270dcd51ca0a3def301ae58429` |
| Base `app/Sources` | 90 | `53c029383744bd2015e499a23244beef97e80748b9c6ff4099deca6db127c323` |
| Fixed archive tracked app entries | 496 | `457e0dc454a68b79e69af45222d90277aeed7426913a1ff1485537ac7961e3be` |
| Lane tracked app entries | 496 | `457e0dc454a68b79e69af45222d90277aeed7426913a1ff1485537ac7961e3be` |

Recorded assertions: `archive_restored_exact=true`, `lane_unchanged=true`.
This proves restoration and source isolation only; it does not prove native
compilation, test compatibility, cache publication, or #136 regression success.

Original records were preserved byte-for-byte:

- `.report-180-history-cache-r1.md`:
  `be2cbbfb830f9f96dbda643f1770b716534692e2e1e2893975cf0509db2def12`.
- `docs/evidence/issue-180-history-cache/README.md`:
  `d29b882bded7459ea3aa9b4d75bd63c5405d5e995a6240df68dbe0f4e7528358`.

## Structural inspection receipt

Actual command (raw exit 0):

```sh
ast-grep run --pattern 'func $NAME($$$ARGS) async { $$$BODY }' --lang swift --json=compact app/Tests/MorselTests/HistoryFreezeRegressionTests.swift app/Tests/MorselTests/MealReliabilityTests.swift
```

Filtering returned function names to the `test` prefix identified 17 test
methods: four in `HistoryFreezeRegressionTests`, 13 in `MealReliabilityTests`.
The four History methods were read to verify the F6 generation-supersession
selection. `git show --stat da0afeb -- app/Tests` confirmed the #136 commit
introduced `HistoryFreezeRegressionTests` and `PaperDeleteAndSkeletonTests`.
No repository justfile exists; no recipe or alternative runner was invented.

## Remaining acceptance

F5 remains NOT MET; F6 remains NOT VERIFIED. The orchestrator needs an
uncontended native window for these exact behavioural legs. This round did
not rerun `npm test`: issue #277 owns that known runner flake, and the earlier
nonzero aggregate results remain disclosed in the untouched original README.
No physical-device feel/timing or hosted-CI success is claimed.

NOT MERGED; not opened as PR; no deploy; no production writes.

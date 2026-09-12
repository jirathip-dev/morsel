# Issue #175 — page identity and models across hinge settlement (evidence)

Bounded repair for the pager-identity defect tracked under #172: the journal
pager no longer builds a throwaway page per turn. Each primary tab owns ONE
page — view, view model, draft and scroll state — created by that tab's first
*accepted* navigation and kept for the signed-in session.

## What changed

- `app/Sources/Morsel/MorselApp.swift` — `JournalPageStage`: the page area.
  It owns the page set (`@State`), renders one page per visited tab, records
  each *accepted* navigation as that page's activation event, and shows a
  pending sheet while a turn heads for a tab that was never accepted.
  It also declares `JournalPageLifecycleEvent` / `JournalPageObserver`, the
  lifecycle seam the mounted suites observe, and keeps the page factory
  (`journalPrimaryPage(for:activation:)`).
- `app/Sources/Morsel/JournalPageTurner.swift` — the turner now renders the
  retained stage the turn machine poses through the environment, instead of
  building a per-turn second page. `HingeTurnPose` gained `isIncoming` /
  `isActive`, so the pose changes WITHOUT changing the page's structural
  branch (a branch change rebuilt the page — the audited defect).
- `app/Sources/Morsel/HistoryView.swift` — `HistoryViewModel.observer`, a
  nonisolated test seam (nil in the app) reporting model init/deinit; the
  History page reports its activation from the `.task(id:)` entry.
- `app/Tests/MorselTests/PageIdentityTests.swift` — new mounted suite (7
  tests); `app/Morsel.xcodeproj/project.pbxproj` carries only its
  registration (+4 lines, `xcodegen generate`).

## Acceptance mapping

| Acceptance | Evidence |
| --- | --- |
| Settling a committed turn reuses the previewed page (one model, one read) | `testCommittedTurnKeepsTheHistoryPageAndNeverReReadsAtSettlement` |
| An abandoned preview creates no page and starts no read | `testAbandonedPreviewsNeverCreateOrReadAndTheReentryCommitsOnce` |
| Re-entry settles exactly once | same test (rollback then re-entry: 1 create, 1 activation) |
| Revisit keeps model, date range, drill-down and scroll | `testRevisitKeepsHistoryRangeExpandedDayAndScroll` |
| Retarget settles one page per tab, one activation each | `testRetargetMidSwingKeepsOnePagePerTab` |
| Reduce Motion shares the same page ownership | `testReduceMotionSharesTheSamePageOwnership` |
| Bounded to the primary tabs, none started eagerly, released with the shell | `testPagesAreBoundedToThePrimaryTabsAndReleasedWithTheShell` |
| Phone-sized Paper/Night captures of a settled and a revisited page | `testPhoneSizedSettledAndRevisitCaptures` + PNGs below |

## Mounted suite

    cd app && HERDR_XCODEBUILD_DIRECT=1 xcodebuild test -project Morsel.xcodeproj \
      -scheme Morsel -destination "platform=iOS Simulator,id=<lane UDID>" \
      CODE_SIGNING_ALLOWED=NO -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Morsel175" \
      -only-testing:MorselTests/PageIdentityTests

    Executed 7 tests, with 0 failures (0 unexpected) in 5.5 seconds   -> exit 0
    (lane log: .lane-logs/focused-175.log, focused=0)

Each test mounts the REAL retained stage in a 390x844 pt `UIWindow(windowScene:)`
and drives the SAME `JournalTurnMachine` seam the gesture drives: page-model
init/deinit, activation task starts and repository reads are counted through the
lifecycle observer, and page mounts through per-tab `onAppear`/`onDisappear`
counters.

## Behavioural RED at the base mechanism

    git worktree add --detach /tmp/morsel-175-red 904fc47     # base head
    # + scratch probe PageIdentityProbeTests.swift (NOT committed) carrying the
    #   same three core claims against the base mechanism
    cd /tmp/morsel-175-red/app && HERDR_XCODEBUILD_DIRECT=1 xcodebuild test ... \
      -only-testing:MorselTests/PageIdentityProbeTests

    Executed 3 tests, with 9 failures (0 unexpected) in 10.7 seconds  -> exit 65
    (lane log: /tmp/morsel-175-red/.lane-logs/red.log, "red=65"; the same
    probe is GREEN on the fixed tree: "focused=0")

At the base the same claims fail: a committed Today→History turn mounts a
SECOND History page and reads the ledger twice (preview mount + settle mount),
an abandoned preview mounts and reads anyway, and a revisit rebuilds the page.

## Mounted captures (phone-sized, 1170x2532 px)

| file | state | sha256 |
| --- | --- | --- |
| `175-01-history-settled-paper.png` | History settled by a committed drag turn, Paper ink | `60972e5232ddef31dbd636d1564f465ffdfac5103c319ac02d7bf08d35ef1368` |
| `175-02-history-revisit-paper.png` | the same page after Today → History, Paper ink | `3d08db774bcaa2646bcfa09572f309c211108c93bbd05b1e4025cdd149e28c81` |
| `175-03-history-revisit-night.png` | the same revisited page, Night ink | `dc13ce33214d6306f4d46aefe387ec40b5d432887365e75d7cbc8a5779f6b4c3` |

Captured in-process by `UIGraphicsImageRenderer(bounds:)` +
`window.drawHierarchy(in:afterScreenUpdates:)`; Night/Paper ink resolves through
the window's `overrideUserInterfaceStyle`. PNG bytes are NOT reproducible run
to run (a rendered date and rasterisation): the hashes identify the committed
files, not a rerun.

## Gates (raw exits, lane tree)

| command | raw exit |
| --- | --- |
| `mise exec node@22 -- npm ci` | 0 (256 packages) |
| `npm run typecheck` | 0 |
| `npm run lint` | 0 |
| `npm test` (vitest, default 5 s per-test budget) | 1 — 2 timeouts (`server/http.test.ts`, `server/tool-classification.test.ts`), 0 assertions, 554/556 passed, host load 10.7; the load-skew class (no iOS file is reachable from the JS suite) |
| `npx vitest run --testTimeout=60000 <those two files>` (diagnostic only) | 0 — 10/10 passed |
| `swiftlint lint --strict` (app/) | 0 — 0 violations, 0 serious in 100 files |
| `xcodegen generate` | 0 — `project.pbxproj` +4 lines (the new test file's registration only) |
| `git diff --check` | 0 |
| `xcodebuild test` (full native suite, lane sim, THREE runs) | 0 — 291 tests, 0 failures, 14.8 s (runs 1-2 wedged in `GoalsPolishTests` with no test signal → sim shutdown/boot → run 3: the lane log `.lane-logs/xcodebuild-test.log`, `xctest=0`) |

## Provenance

- Worktree `/Users/jirathip/.herdr/worktrees/morsel/issue-175-pager-identity`,
  branch `issue-175-pager-identity`, base `904fc47` (the audited mechanism);
  the committed head SHA is recorded in the lane report and `git ls-remote`.
- Host: macOS 26.6.2, Xcode 26.5; iPhone 16 simulator (iOS 26.5), UDID
  `3811399E-A3D7-4C44-8E7B-FBE34CBD69AE` (lane-dedicated, created for this
  lane), unsigned Debug build (`CODE_SIGNING_ALLOWED=NO`).
- `HERDR_XCODEBUILD_DIRECT=1`: the herdr xcodebuild shim otherwise reroutes
  simulator actions through a throwaway `hermes-sim-task` simulator.
- Lane-local derived data: the host default `/Volumes/NVMe2TB/DerivedData` is
  unmounted, so both runs passed
  `-derivedDataPath $HOME/Library/Developer/Xcode/DerivedData/Morsel175[-RED]`.
- The unit-test bundle is hosted by the app, so `MorselApp.init` font
  registration is live and the dynamic palette resolves through the window's
  trait collection.
- NOT verified: physical-device behaviour; synthesized touches (the bundle
  exposes 0 accessibility elements and `hitTest` returns `_UIHostingView`
  everywhere — the machine seam stands in, as in #174); the hinge's 3D pose in
  captures (`drawHierarchy` cannot reproduce `rotation3DEffect`, so the pose is
  pinned by `JournalHingeSeamTests` + `issue-111-hinged-turn-contract.test.ts`
  and the captures show settled/revisited pages); a mid-session change of the
  system Reduce Motion setting (the suite instantiates the Reduce Motion path
  directly, mirroring #174).

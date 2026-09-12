# Issue #174 — page-turn cancellation and rollback re-entry (evidence)

The journal pager (`app/Sources/Morsel/JournalPageTurner.swift`) now turns
pages through an explicit state machine (`JournalTurnMachine`:
idle / dragging / committing / rollingBack) instead of the #111 implicit
optional. The bounded repair (issue #174, child of tracker #172):

- **Axis ownership.** The drag axis is decided by the direction that first
  dominates; a vertical takeover CLEARS any live preview and owns the gesture
  to the end, so a horizontal → vertical intent change can no longer leave an
  abandoned preview and a scroll is never converted into a commit.
- **Fresh turn identity per gesture.** The preview-reuse path is gated on the
  `dragging` phase, so a new same-direction drag during an in-flight rollback
  starts a NEW turn (fresh UUID) — the previous completion can neither clear
  nor settle it.
- **Per-operation tokens.** Every gesture/animation operation bumps a
  monotonic token; `complete(operation:)` (and the pose `apply`) are honoured
  only while their token is current, so stale callbacks and cancelled tasks
  cannot mutate newer state. Drag ends and selection changes carry phase
  guards too (a stale end cannot re-settle a turn that is already animating).
- **Interruption.** Scene inactivity (`scenePhase != .active`) and removal of
  the pager (presentation interruption) settle exactly one page: a commit
  lands on its destination, everything else returns to the settled base.

Hinge geometry, duration, backward mirror, adjacency/no-wrap, and Reduce
Motion are unchanged from #111 (`JournalTurnSeam` untouched).

## Test evidence

| suite | what it drives | result |
| --- | --- | --- |
| `JournalTurnMachineRaceTests` (10 tests) | the extracted state seam with controllable completions (no wall-clock waits) | 10/10 pass |
| `JournalPagerMountedRaceTests` (4 tests) | the REAL `JournalPageTurner` mounted in a 390×844 `UIWindow`, driven through the real `JournalTurnDriver` (model pivot, animation, completion scheduling) | 4/4 pass |
| `JournalPagerWiringContractTests` (2 tests, in `JournalFollowUpTests.swift`) | source contract for the thin drag-gesture / scene-lifecycle plumbing | 2/2 pass |

Native run (unsigned Debug, simulator only):

```
xcrun simctl create "Morsel174-iPhone16" "iPhone 16" com.apple.CoreSimulator.SimRuntime.iOS-26-5
UDID 7A449F2D-4952-43F0-B63C-B34F549B3060  (iOS 26.5 runtime, Xcode 26.6)
HERDR_XCODEBUILD_DIRECT=1 xcodebuild test -project Morsel.xcodeproj -scheme Morsel \
  -destination "platform=iOS Simulator,id=$UDID" CODE_SIGNING_ALLOWED=NO
```

RED/GREEN: every new race assertion was shown to fail on the unfixed
mechanism before the fixed file passed — the audited staging file itself
(compile-time RED: the seam does not exist at base, raw exit 65) plus one
mechanism mutation per defended race (raw exit 65 for each; the FIXED file is
green). Raw exits and log paths live in the lane `.report.md`.

## Mounted captures (phone-sized, simulator)

These three PNGs are written by `JournalPagerMountedRaceTests` from the test
host window (390×844 pt, 1170×2532 px, iPhone 16 @3x):

| frame | state |
| --- | --- |
| `174-01-preview-history.png` | drag preview in flight: the base Today page + the incoming History page (opacity 0.2 → 1 at progress 130/390) |
| `174-02-cleared-one-settled-page.png` | after the drag turns vertical: the preview is cleared — exactly ONE settled page (Today), no abandoned preview |
| `174-03-commit-settled-history.png` | after a half-page commit completes through the driver: exactly ONE settled page, the newly committed History selection |

**Provenance and limitations (unverified stays unverified):**

- Captured from the iOS Simulator (not a physical device), unsigned Debug
  build, test-host window of `MorselTests`; the mounted-shell evidence the
  issue asks for, not an on-device acceptance run.
- The snapshot path available to the test host (`drawHierarchy`/
  `CALayer.render`) renders the incoming page's opacity and pose progress but
  does NOT reproduce the 3D hinge projection, so these frames must not be
  read as pose-geometry evidence. The pose math is pinned by
  `JournalHingeSeamTests` + `app/issue-111-hinged-turn-contract.test.ts`, and
  the machine suite asserts the exact progress values (100/390, 120/390,
  320/390).
- No OS-level touch-cancellation sequence (a real finger drag interrupted by
  scroll arbitration, or a system-interrupted gesture stream) could be
  injected from a unit-test target — the host has no touch-injection tool —
  so that sequence is **recorded as unverified**, not as a reproduced defect.
  The tests drive the same `dragChanged`/`dragEnded` entry points the gesture
  forwards to, and the source contract pins that forwarding.

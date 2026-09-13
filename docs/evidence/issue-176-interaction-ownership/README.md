# Issue #176 — interaction ownership: one interactive page and a stable sheet owner

Bounded repair for the ownership defect tracked under #172. After #174
(race-safe page turns) and #175 (one page per visited tab) the journal shell
still stacked full-area layers — the retained primary pages, the hinge's
preview/outgoing sheet and the route overlays — and its ownership policy named
the *settle source*, so a layer that was only animating, or was already
covered, could still activate controls and stayed in the accessibility tree
beside the layer the user saw.

## What changed

- `app/Sources/Morsel/MorselApp.swift` — `JournalPageStage` now owns
  interaction through ONE predicate, `!routeCoversPages && tab == pager.selection`,
  applied on all three channels (`.allowsHitTesting`, `.disabled`,
  `.accessibilityHidden`): the declared active page is the pager's selection —
  a committed swing declares its destination at once, while a drag preview or
  a rollback leaves the settled page in charge. The animation-only placeholder
  (a swing toward a never-visited tab) takes `.allowsHitTesting(false)`. The
  shell passes `routeCoversPages: routeModel.route != .tabPages`, so Add Meal /
  Menus silence every page layer while they cover them. The tab bar is not
  behind the ownership, so retargeting never locks.
- `app/Sources/Morsel/Views.swift` — `JournalPresentationModel`: the shell owns
  Today's presentations (item edit, meal delete) outside the transient page and
  keeps AT MOST one; `TodayView` only requests (`requestEdit` / `requestDelete`)
  and no longer holds `@State` presentation vars or `.sheet`s.
  `View.journalPresentations(_:viewModel:)` anchors the sheets at the shell.
- `app/Tests/MorselTests/InteractionOwnershipTests.swift` (new, mounted) plus
  `JournalFollowUpTests.swift` additions (presentation-owner semantics and the
  applied-channel/wiring source pins).
- `app/Morsel.xcodeproj/project.pbxproj` — XcodeGen registration of the new
  test file only (+4 lines).

`app/Sources/Morsel/JournalPageTurner.swift` was re-audited and left
UNTOUCHED: with #174's state machine + #175's retained stage the turn pose and
geometry are owned, and the remaining ownership hole was the predicate/sheet
anchoring above, not the turner.

## Acceptance mapping

| Acceptance | Evidence |
| --- | --- |
| During drag/commit/rollback only the declared active page activates | `testOnlyTheDeclaredActivePageCanActivateAcrossDragCommitAndRollback` |
| Offscreen/outgoing/decorative layers activate nothing | same test + the pinned `.allowsHitTesting(false)` on the placeholder |
| One presentation; settlement never dismisses/duplicates/orphans it | `testPresentationRequestSurvivesAPageTurnAndNeverDuplicates`, `JournalPresentationOwnershipTests` |
| Add Meal/Menus prevent underlying actions + hidden tab content; Cancel/back usable; retargeting responsive | `testRouteOverlayOwnsInteractionWhileItCoversThePages` |
| Coordinate + keyboard-visible case | `testOverlayLayersOwnEveryPageCoordinateIncludingTheKeyboardCase` |
| Reduce Motion case | `testReduceMotionPathKeepsTheSameInteractionOwnership` |
| Touch + accessibility channels | `JournalInteractionOwnershipWiringTests` source pins (see "Not verified") |

## Mounted suite (lane simulator, unsigned Debug)

    UDID A4355F56-E261-45C2-B9A1-3B4376A2D558  (Morsel176-iPhone16, iOS 26.5, simulator — not a device)
    cd app && HERDR_XCODEBUILD_DIRECT=1 xcodebuild test -project Morsel.xcodeproj -scheme Morsel \
      -destination "platform=iOS Simulator,id=$UDID" CODE_SIGNING_ALLOWED=NO \
      -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Morsel176" \
      -only-testing:MorselTests/JournalInteractionOwnershipTests \
      -only-testing:MorselTests/JournalPresentationOwnershipTests \
      -only-testing:MorselTests/JournalInteractionOwnershipWiringTests

    Executed 9 tests, with 0 failures (0 unexpected) in 8.8 seconds   -> exit 0
    (lane log: .lane-logs/focused-176e.log)

Each test mounts the REAL stage/turner/turn machine (and the real route model +
presentation owner) in a 390x844 pt `UIWindow(windowScene:)`. A page stand-in
reports the environment its layer really receives, so the tests observe the
control-activation channel (`isEnabled`) per layer while the same machine seam
the gesture drives is stepped through drag, commit, rollback and retarget.

## Behavioural RED at the base mechanism

    git worktree add --detach /tmp/morsel-176-red 06f610c      # base head
    # + scratch probe OwnershipProbeTests.swift (NOT committed) carrying the same
    #   ownership assertions against the base shell shape
    cd /tmp/morsel-176-red/app && HERDR_XCODEBUILD_DIRECT=1 xcodebuild test ... \
      -only-testing:MorselTests/OwnershipProbeTests

    Executed 3 tests, with 5 failures (0 unexpected) in 17.7 seconds   -> exit 65
    (/tmp/morsel-176-red/.lane-logs/red.log)

At the base the same assertions fail behaviourally: during a drag preview and
after a commit every mounted page layer is still activatable (`[today, history,
goals]`), the pages stay activatable while Add Meal covers them
(`[today, history]`), and Today owns its presentation state
(`.sheet(item: $mealToDelete)`, `@State editingItem`/`mealToDelete`).

## Captures (phone-sized, 1170x2532 px, simulator)

| file | state | sha256 |
| --- | --- | --- |
| `176-01-pages-owned-today-paper.png` | the settled page the user owns: Today (Paper ink) with its log row, delete strike and tab bar, over the mock snapshot 228/2,100 kcal | `9aaf1aabbad2ffe7e2c7d5fa66f44557094c60a5acade7794cec2cd5738a4f85` |
| `176-02-add-meal-owns-paper.png` | the Add Meal overlay owning the whole area (its Cancel/Save header included) over the same pages, Paper ink | `a43b62f5a5616cc4f8d5bea687cdca42efbee59498d85983796764cad567c151` |
| `176-03-menus-owns-night-ink.png` | the Menus overlay owning the area, Night ink (empty library: the mock repository serves no menus) | `e41e8aeac380e21b4c5440a25d90aac3fde0da313b79d9f4c3d7ff8b705b8d0e` |

Captured in-process by `UIGraphicsImageRenderer(bounds:)` +
`window.drawHierarchy(in:afterScreenUpdates:)`. PNG bytes are NOT reproducible
run to run (rasterisation and a rendered date — the simulator's calendar is the
device Buddhist calendar, hence "13 Sep BE 2569" in the captures); the hashes
identify the committed files, not a rerun. The stills show composition, not the
hinge's 3D pose (`drawHierarchy` cannot reproduce `rotation3DEffect`, as #174
recorded) and not the ownership itself: ownership is asserted by the tests, not
visible in a still.

## Provenance

- Worktree `/Users/jirathip/.herdr/worktrees/morsel/issue-176-interaction-ownership`,
  branch `issue/176-interaction-ownership`, base `06f610c` (#175); the head SHA
  is recorded in the lane report and `git ls-remote`.
- Host macOS 26.6.2, Xcode 26.5, iOS 26.5 simulator, unsigned Debug
  (`CODE_SIGNING_ALLOWED=NO`); `HERDR_XCODEBUILD_DIRECT=1` because the herdr
  `xcodebuild` shim otherwise reroutes simulator actions through a throwaway
  simulator; lane-local `-derivedDataPath` (the host default
  `/Volumes/NVMe2TB/DerivedData` is unmounted).
- NOT verified: physical-device behaviour; **synthesized touches** (this host
  has no touch injection: the unit bundle exposes 0 accessibility elements and
  `hitTest` answers `_UIHostingView` everywhere — #174/#177); accordingly the
  touch and accessibility channels are pinned where they are declared (one
  predicate, three channels) and the control-activation channel is observed in
  the mounted hierarchy; a mid-session change of the system Reduce Motion
  setting (the suite instantiates the Reduce Motion path directly).
- One-shot appearance diagnostic (not a durable gate): enabling vs disabling a
  real Today layer rendered byte-identical PNGs, while a same-state render pair
  differed — the bundle's PNG bytes are not run-to-run stable, so the
  comparison is reported as a diagnostic and the appearance claim rests on the
  untouched pose code plus the pinned ownership channels.

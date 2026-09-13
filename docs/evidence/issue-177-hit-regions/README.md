# Issue #177 — compact journal actions expand to reliable hit regions (evidence)

The journal shell's compact actions were glyph-sized hit targets: the Settings
cog label measured 24×24 pt, the Add Meal paper tab 38×38 pt, the meal-delete
ink strike 34×34 pt (issue #198 / tracker #172 audit at `30232f2`), and each
tab cell carried its equal-width frame OUTSIDE the plain `Button` label with no
full-cell `contentShape`, so the cell's blank space and corners were dead.
This change enlarges the interactive label geometry to ≥44×44 pt without
touching the approved artwork, palette or navigation rhythm:

- `ToothedCog` / `AddMealTab` (`app/Sources/Morsel/JournalUI.swift`) are the
  header's action labels: each approved glyph now sits in a 44×44 target
  anchored to the same top-trailing corner it used before (the target grows
  into the header's free space).
- `InkStrikeX` is the delete action's label: the approved 16 pt ink strike
  stays centred in a 44×44 target.
- `JournalTabCellLabel` (`app/Sources/Morsel/JournalShellChrome.swift`) is the
  tab cell: the V1 word + marker stretch to the cell's whole allocated region
  (full column width × 44 pt) with `contentShape(Rectangle())`, so blank space
  and corners activate that tab. The word keeps the exact hand type, colours
  and 2 pt hand offset the approved bar already used.
- `VerifyActionLabel` / `PhotoPromptActionLabel`
  (`app/Sources/Morsel/TodayLogViews.swift`) give the review pill and the
  empty-log photo prompt the same ≥44 pt treatment.

## Native run (unsigned Debug, simulator only)

```
xcrun simctl create "Morsel177-iPhone16" "iPhone 16" com.apple.CoreSimulator.SimRuntime.iOS-26-5
UDID 6C1770C1-3B12-431B-9564-1C0A00C73CE0   (iOS 26.5 runtime, Xcode 26.6)
HERDR_XCODEBUILD_DIRECT=1 xcodebuild test -project Morsel.xcodeproj -scheme Morsel \
  -destination "platform=iOS Simulator,id=$UDID" CODE_SIGNING_ALLOWED=NO
```

This is the iOS Simulator, not a physical device. Physical-device feel and
VoiceOver acceptance stay in the tracker.

## Measured interactive geometry (`JournalHitRegionTests`)

The native suite hosts the REAL label views at the 390 pt phone width and
measures the laid-out geometry (`UIHostingController.sizeThatFits`) — never a
source-string proxy. Base column = the audit's measurement on the same views
before the change (recorded from the lane's unfixed-tree run and its mutation
log); head column = the fixed tree.

| action | label view | base | head |
| --- | --- | --- | --- |
| Settings | `ToothedCog` | 24×24 | 44×44 |
| Add Meal | `AddMealTab` | 38×38 | 44×44 |
| meal delete | `InkStrikeX` | 34×34 label (16 pt glyph) | 44×44 |
| review pill | `VerifyActionLabel` | 51.7×18.3 | 51.7×44 |
| photo prompt | `PhotoPromptActionLabel` | 190×20.7 | 190×44 |
| tab cell (×3) | `JournalTabCellLabel` | word-sized box (40.3 pt tall) | 130×44 |

The tab cells tile the 390 pt bar exactly (3 × 130 pt) and the suite asserts
they do not intersect, that cell corners/blank-space points belong to exactly
one tab, and that the 1 pt rule above the cells is not a target. The same
measurements are re-asserted with the keyboard inset in place (reduced-height
proposal) and at `accessibilityExtraExtraExtraLarge`.

## Mounted captures (phone-sized, simulator)

| frame | shows |
| --- | --- |
| `issue-177-shell-paper.png` | Paper: the shell surface (Today page + the real tab bar) with the approved cog, paper add-tab, delete strike and tab words in place |
| `issue-177-shell-night-ink.png` | Night ink: the same surface through the dual tokens |
| `issue-177-shell-targets-paper.png` | Paper + the MEASURED tab-cell targets stroked over the bar (three thirds × the measured 44 pt row) |
| `issue-177-shell-targets-night-ink.png` | Night ink + the same measured targets |

## Provenance and limitations (unverified stays unverified)

- Written by `JournalHitRegionTests` from the test host window (390×844 pt,
  1170×2532 px @3x) — a composed journal shell surface (`TodayView` + the real
  `JournalTabBar`), not a signed-in app run and not a physical device.
- The host has no touch-injection tool for a unit-test target, so a tap is
  verified as **measured frame containment**: the labels that carry the
  `Button`s are measured at cell size and the tap points are asserted to fall
  in exactly one cell. A real gesture sequence, and VoiceOver's own
  activation, are **recorded as unverified** here (the unit bundle does not
  vend a SwiftUI accessibility tree — the lane measured 0 accessibility
  elements in-process).
- The stroke overlay on the `-targets-` frames is the measured cell strip;
  the position comes from the window's real safe-area bottom inset and the
  measured bar row, not from hand-written coordinates.
- The delete strike's 44×44 target grows around the approved 16 pt glyph, so
  in the trailing-anchored log rows the glyph sits 5 pt further leading; the
  header's Add Meal artwork is unchanged and the Settings cog moves 6 pt
  leading (its 44 pt target keeps the top-trailing anchor). The tab bar itself
  renders **byte-identically** before and after the change (captures compared
  in the lane).

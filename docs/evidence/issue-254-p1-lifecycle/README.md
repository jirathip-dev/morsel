# Issue 254 — P1 lifecycle day-ownership native simulator evidence

These are simulator fixtures, not a physical-device or live-Health acceptance run. All meal,
goal, Movement, workout and adjustment values are fictional test inputs. No amount is a
suggestion, preset or shipped recommendation. Production fields start blank.

## What these captures test

Issue #254 rounds the shipped P1 day-only adjustment out to day *ownership*:

- the confirmed addition and the observed baseline belong to ONE diary date — a day rollover
  hides the previous day's note instead of presenting it as the new day's (see the `rollover`
  pair and the `undo` pair), and a past date never borrows today's adjustment;
- a goal observed for TODAY is a baseline revision: it takes effect today, keeps a confirmed
  addition, and the revised total is shown (unit-tested in `app/Tests/MorselTests/TrainingFuelTests.swift`);
- a draft alone never changes the totals; a pending or failed confirmation retains the draft and
  the previous totals; undo never touches saved goals, meals or Health context;
- Movement and workout stay separate dated readings; a true zero is rendered as `0 kcal`, never
  as missing/denied/unavailable Health, and Health never feeds the food target.

Persistence across relaunch/devices and the authenticated agent read are owned by the shared
dated-provenance contract (sibling issue #253). These fixtures do not claim it.

## Captures

`captures/` holds 18 images (9 states × Paper/Night). `manifest.json` records the SHA-256,
pixel size and inspection state of each file.

| state | proves |
| --- | --- |
| `normal` | blank-by-default adjustment: 2,000 kcal target, "Not confirmed", no suggested amount |
| `hard-confirmed` | explicit confirm applies +271.5 (target 2,271.5) and offers edit/undo |
| `unconfirmed` | typing is not confirmation: the editor holds a value with the confirm gate closed |
| `missing` | no readable Health: Movement and Workout read `Unavailable` (never `0 kcal`) |
| `stale` | real earlier sample date + separate checked time: "Last known · not today's total" |
| `manual` | manual-goal consent is unchecked and required on every confirmation |
| `save-failure` | a failed confirmation retains the draft and the old target and offers retry |
| `undo` | undo returns the unchanged state — byte-identical to the `normal` capture in both themes |
| `rollover` | after midnight the new day shows no confirmed note and the usual target |

`254-paper-normal.png`/`254-paper-undo.png` and their Night counterparts are byte-identical by
design: after undo the rendered pixels are the no-adjustment state. The identity is the proof.

## Reproduction

The evidence test mounts the production `TodayView`/`TrainingFuelEditor` in a simulator
`UIWindow` with fictional models, uses the real journal tab bar and tokens, explicitly applies
Paper/Night to both UIKit and SwiftUI, and scrolls Today to the context section. The editor is
mounted directly rather than reached by a tap; these images do not prove sheet gestures, keyboard
input, page-turn interaction, authentication or Health authorization.

```sh
cd app && xcodegen generate && swiftlint --strict
HERDR_XCODEBUILD_DIRECT=1 xcodebuild test \
  -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=10D1FB53-7D7D-44C2-A3CF-DF1ACFDACC33' \
  -derivedDataPath /tmp/morsel-254-dd -resultBundlePath /tmp/morsel254-evidence.xcresult \
  CODE_SIGNING_ALLOWED=NO -only-testing:MorselTests/TrainingFuelEvidenceTests
xcrun xcresulttool export attachments --path /tmp/morsel254-evidence.xcresult \
  --output-path /tmp/morsel254-attachments
```

The committed PNGs are the exported XCTest attachments of that run. Each attachment is written
by the test process at the moment the state is rendered, so a capture cannot drift onto another
state. The full gate is the separate **one complete unfiltered** invocation documented in the
lane report; it passed 427 tests with raw exit 0.

An earlier version of the lane's capture driver took `xcrun simctl io … screenshot` on the
`FUEL_CAPTURE_READY` markers as they arrived on the xcodebuild stdout pipe. Under host load that
stream is not frame-synchronous, and one state's file held a later state's screen (the lane
report records the defect and the discarded files). The attachment path replaced it; the
`FUEL_CAPTURE_READY` markers stay in the test as the driver hooks for a future framebuffer run.

## Observed runs

- Full unfiltered native invocation (`.lane-logs/native-full.log`): 427 tests, 0 failures,
  raw exit 0, `** TEST SUCCEEDED **`, on Morsel254-iPhone16 / iOS 26.5.
- Focused evidence leg (`.lane-logs/native-evidence-captures.log`): raw exit 0, attachments
  exported, 18 PNGs, all 1179 × 2556, visually inspected (plus a per-theme 3×3 proof sheet).
- The local `npm test` attempt exited 1: 2 failures, both the brief's known HOST-SIDE 5000 ms
  timeout class in the untouched `server/http.test.ts` and `server/tool-classification.test.ts`.
  All 6 tests of the touched `app/training-fuel-contract.test.ts` passed. No budget, skip or
  retry sweep was used; the hosted `quality` job is authoritative.

## Explicitly unverified

Physical devices and real Health samples/permissions; the device-only HealthKit inventory in the
lane report; relaunch/cross-device/agent persistence of the confirmed adjustment (shared contract
#253); release signing and TestFlight; any clinical or fuelling adequacy claim. Journal
page-turn/navigation/focus/Reduce-Motion source files are unchanged.

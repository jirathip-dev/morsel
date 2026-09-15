# Issue 226 — P1 native simulator evidence

These are simulator fixtures, not a physical-device or live-Health acceptance run. All meal, goal, Movement, workout and adjustment values are fictional test inputs. No amount is a recommendation or a shipped preset. Production fields start blank.

## Implementation boundary

P1 is a user-authored, date-scoped note in the signed-in app session. It is not durable or synced; the UI says so. Only explicit confirmation changes today's food-target comparison. Movement is separate read-only context, never an input to that target. Baseline and source remain captured through editing and confirmation; edit replaces the addition, undo removes it. Manual goals require fresh unchecked day-only consent. No meal, Health, saved goal or historical target is written.

The longer/harder-day toggle is explicit user context, not a duration/energy threshold. Missing reads are Unavailable; readings from other dates show Last known, not today's total, with their real sample dates and separate checked timestamps. A ring cannot assess adequate fuelling. Professional planning guidance is in About this context.

## Reproduction

The committed `app/Tests/MorselTests/TrainingFuelEvidenceTests.swift` hosts production `TodayView`/`TrainingFuelEditor` in a simulator UIWindow with fictional models. It uses the actual journal tab bar and tokens, explicitly applies Paper/Night to both UIKit and SwiftUI, and scrolls Today to expose the new context section. The editor is mounted directly rather than reached by a tap; these images do not prove sheet gestures, authentication, Health authorization, or page-turn interaction.

Run from `app/`, after XcodeGen and host-wide native arbitration:

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=10D1FB53-7D7D-44C2-A3CF-DF1ACFDACC33' \
  -derivedDataPath /tmp/xc-dd-226 \
  -resultBundlePath /tmp/morsel226-evidence.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

This is the complete native suite, not a filtered gate. The evidence test keeps named image attachments in the result bundle (`xcrun xcresulttool export attachments --path /tmp/morsel226-evidence.xcresult --output-path /tmp/morsel226-attachments`). It also emits `FUEL_CAPTURE_READY 226-<theme>-<state>` and holds each state for three seconds. The lane driver takes `xcrun simctl io <UDID> screenshot <name>.png` at these markers.

Captured states, for both Paper and Night: normal; hard-confirmed; unconfirmed (blank input); missing; stale (real earlier sample date); manual (unchecked acknowledgement); save-failure (retained draft, unchanged target). The pending/failure completion seam is injected by tests: production applies only an ephemeral local note, not a fabricated server save.

The final capture inventory and SHA-256 values are in `manifest.json`. Raw native logs, complete-run count, admission waits and gate results are recorded in the lane's untracked `.report.md` and `.lane-logs/`.

## Observed run

The single complete native invocation passed: 389 tests, zero failures, raw exit 0, `** TEST SUCCEEDED **`, on Morsel226-iPhone16 / iOS 26.5. All 14 unmodified simctl PNGs are 1179 × 2556 pixels and have distinct SHA-256 values. All were visually inspected.

Normal shows the unchanged computed target; hard-confirmed shows the fixture's typed +271.5 and resulting 2,271.5 with edit/undo. Unconfirmed has a blank input. Missing shows two Unavailable readings. Stale displays 12 September samples separately from 13 September checked times. Manual shows a 125 draft, unchecked consent and unchanged manual target. Failure retains 271.5 beside an explicit error, retry/cancel and unchanged target. The fixture clock is fixed, not the capture wall clock; the simulator renders localized Buddhist-era years (2569 BE).

These are intentionally scrolled content captures. The predecessor macro row remains partly visible behind status chrome, and the longer-day label ellipsizes in the missing-data frame. The existing custom primary-button style stays orange even when disabled: native behavioral tests and the source binding, not the button color, prove the confirmation gate. The mounted content does not include every shell-level tint/safe-area modifier; the green enabled toggle is native system chrome. No pixel-perfect full-shell, tap, keyboard, Dynamic Type or gesture claim is made.

The full local `npm test` attempt exited 1: 573 passed, four 5000 ms timeouts across the three untouched `server/http.test.ts`, `server/render-png.test.ts`, and `server/tool-classification.test.ts` files, plus a Vitest worker `onTaskUpdate` timeout. This matches the brief's named host-timeout class; it is not a local full-suite PASS. No retry sweep, skip or timeout-budget change was made. Hosted quality remains authoritative and was not run in this lane.

## Explicitly unverified

Physical devices, real Health permissions and real workout/Movement records; release signing/TestFlight; backend persistence; historical-target provenance; clinical appropriateness or nutritional adequacy. Eligibility, clinical bounds, automatic freshness/hard-day thresholds, macro adjustments, professional-plan contracts, durable audit semantics and any numerical algorithm remain separate owner/clinical decisions. Journal page-turn/navigation/focus/Reduce Motion source files are unchanged.

# Issue 303 — cached notice gated on refresh failure, native simulator evidence

These are simulator fixtures, not a physical-device or live-data acceptance run. Every meal, item,
goal and target value is a fictional test input. No amount is a suggestion, preset or shipped
recommendation.

## What these captures test

The reported defect: the "Cached — last updated …" notice **flashed on every normal load**, because
it was gated on *the visible snapshot being a cached copy* rather than on *the refresh having
failed*. Today deliberately paints from the local cache first and refreshes behind it (#180/#290),
so during that in-flight window the visible snapshot is the cached one — the notice painted and
then vanished. The fix carries the read outcome (`fresh` / `pending` / `failed`) in the day-read
provenance; the notice renders only for `cached + failed`.

Both captures are minted through the shipped composition — `DashboardViewModel` →
`LocalFirstDashboardRepository` (temporary account-scoped SQLite) → `SupabaseDashboardRepository`
→ controlled URL transport — with the same fixture day and read path as the #258 states. No
production auth or data is used.

- **normal** — a healthy re-open over an existing cache: the cached pre-paint is followed by a
  successful refresh. The settled page shows **no** notice. The in-flight window itself is
  asserted in state (`DayReadCompositionTests.testHealthyLoadNeverShowsTheCachedNoticeThroughTheInFlightWindow`
  parks the refresh and asserts the notice flag is false throughout); a screenshot cannot capture
  a window that no longer renders a notice.
- **failed** — the refresh failed (`meal_logs` 500 after a successful 11:00 AM load), so the day on
  screen is the last saved copy. It is announced: "Cached — last updated 11:00 AM" +
  "Couldn't refresh today's log. The values below are the last saved copy." + **Try again**
  (the #258/#270 announcement is preserved, not weakened).

## Captures

`captures/` holds 4 images (2 states × Paper/Night) at 1179×2556 pixels. All four are byte-distinct
(the state difference is the notice; the theme difference is the ground). `manifest.json` records
the SHA-256, pixel size and inspection state of each file.

| state | proves |
| --- | --- |
| `normal` | a healthy load after the cached pre-paint settles with **no** notice and no retry — the reported flash is gone |
| `failed` | "Cached — last updated 11:00 AM" + "Couldn't refresh today's log…" + `Try again` over the last saved day, in both themes |

All four attachments were visually inspected and are 1179×2556 pixels. Raw corner RGB values are
`(254,248,234)` Paper / `(41,38,31)` Night in the exported PNG profile (Display P3, not
color-managed sRGB token measurements); converted to sRGB they read `(255,248,232)` / `(42,38,30)`.
The meal rows are below this viewport; the native tests assert their identities and counts.

## Reproduction

The evidence test mounts the production `TodayView` (with the real journal tab bar and tokens) in a
simulator `UIWindow`, applies Paper/Night to both UIKit and SwiftUI, drives the day read through the
shared `StubTransport`, and writes one XCTest attachment per state at the moment it is rendered —
so a capture cannot drift onto another state. It also asserts the state it captured
(`isShowingCachedDay` / `isRefreshingCachedDay` / `readProvenance.outcome`), so a wrong-state image
fails the test rather than shipping.

```sh
cd app && xcodegen generate && swiftlint --strict
HERDR_XCODEBUILD_DIRECT=1 xcodebuild test \
  -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=3B215DFD-EA49-4EE9-A861-9A4A241B8A93' \
  -derivedDataPath /tmp/morsel-303-dd -resultBundlePath /tmp/morsel-303-evidence.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:MorselTests/DayReadCompositionTests \
  -only-testing:MorselTests/DayReadDegradeTests \
  -only-testing:MorselTests/DayReadDegradeEvidenceTests
xcrun xcresulttool export attachments --path /tmp/morsel-303-evidence.xcresult \
  --output-path /tmp/morsel-303-attachments
```

The committed PNGs are the exported attachments of that run (`.lane-logs/evidence-run.log`, raw
exit 0, 14 tests / 0 failures). The #258 states are re-minted by the same run
(`testCachedAndIncompleteDayReadStatesInPaperAndNight`) and were left untouched.

## Evidence receipts

`excerpts/` carries the exact command, the raw exit and the selected raw lines of every gate run
for this lane — `red-base-focused.txt` (the pre-fix RED: the flash), `green-focused-family.txt`
(the affected test families at head), `evidence-run.txt` (the capture run), `mutation-battery.txt`
(all four mutations exit 65 and every restore is sha256-verified), `native-full-head.txt` (the one
complete unfiltered run: 608 tests / 3 skipped / 5 failures = the four pre-existing reds plus one
load-sensitive pager flake), `base-with-fix-stashed.txt` (the pre-existing-reds leg) and
`pageidentity-rerun.txt` (the flake's focused rerun: green). Full logs stay in `.lane-logs/`
(ignored).

The behaviour half of the issue is asserted in `app/Tests/MorselTests/DayReadCompositionTests.swift`
(no notice through the parked in-flight window; the pending↔failed state distinction; the failed
refresh still announced with the last successful time) and in
`app/Tests/MorselTests/DayReadDegradeTests.swift` (degraded reads unchanged; failure/retry states).

## Explicitly unverified

Physical devices; a real failed Supabase read against production; the app's own refresh scheduling
and the History read path (History keeps its own provenance gate — unchanged by this lane); the
staleness-threshold arm of the issue's fix direction is not implemented (every cached paint in the
load path is followed by a concluded refresh, so the outcome state covers the visible paths);
authentication, gestures, and Health authorization. The notice copy here is the lane's fixture day
(5 Sep 2026, device clock), not a user's real day.

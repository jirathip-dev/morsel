# Issue 258 — day read degradation + honest cached/stale day, native simulator evidence

These are simulator fixtures, not a physical-device or live-data acceptance run. Every meal, item,
goal and target value is a fictional test input. No amount is a suggestion, preset or shipped
recommendation.

## What these captures test

Issue #258 has two user-visible halves, and both are rendered here from the PRODUCTION read path
(`SupabaseDashboardRepository.loadToday` through the controlled URL transport — the rendered state
is the real read's outcome, not a hand-built view model):

- **stale** — a refresh failed, so the day on screen is the last saved copy. It stays visible, but
  it is labelled as cached with the last successful load time and a retry: it is never presented as
  current (before this change a failed refresh was indistinguishable from "those meals don't
  exist"). The fixture loads the day successfully once, then the next `meal_logs` read fails.
- **degraded** — the day read degraded instead of aborting: one item row could not be read, so that
  meal says so while every other meal, its items and the day's totals still render. `meals: []` is
  never the presentation of a read error. The fixture returns three item rows for two meals where
  the dinner's curry row carries an unreadable unit.

Values visible in the captures prove the two states are genuinely different reads: the degraded day
renders 570 kcal (the readable rows only — the unreadable row is missing, and the notice says the
totals are short) while the stale day renders the full 1,180 kcal last saved copy.

## Captures

`captures/` holds 4 images (2 states x Paper/Night). `manifest.json` records the SHA-256, pixel
size and inspection state of each file. All four are distinct by design: the stale and degraded
states differ in banner copy and in the values they render.

| state | proves |
| --- | --- |
| `stale` | "Cached — last updated 11:00 AM" + "Couldn't refresh today's log…" + `Try again`, over the last saved day (1,180 kcal) |
| `degraded` | "1 meal couldn't be fully read" + "Some items are missing from today's log and the totals are short. Nothing was deleted — try again." over the meals that WERE read (570 kcal, one unread meal) |

Per-theme ground colours were verified from the committed PNGs (corner pixel `#FEF8EA` Paper /
`#29261F` Night — the paper-texture overlay over the design grounds), so the theme really resolved
in both directions.

## Reproduction

The evidence test mounts the production `TodayView` (with the real journal tab bar and tokens) in
a simulator `UIWindow`, applies Paper/Night to both UIKit and SwiftUI, drives the day read through
the shared `StubTransport`, and writes one XCTest attachment per state at the moment it is
rendered — so a capture cannot drift onto another state. It also asserts the state it captured
(`isShowingCachedDay` / `incompleteMealCount`), so a wrong-state image fails the test rather than
silently shipping.

```sh
cd app && xcodegen generate && swiftlint --strict
HERDR_XCODEBUILD_DIRECT=1 xcodebuild test \
  -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=152E7AA9-8BC5-41D0-AD74-F73C7C69A3EB' \
  -derivedDataPath /tmp/morsel-258-dd -resultBundlePath /tmp/morsel258-focused.xcresult \
  CODE_SIGNING_ALLOWED=NO -only-testing:MorselTests/DayReadDegradeTests \
  -only-testing:MorselTests/DayReadDegradeEvidenceTests
xcrun xcresulttool export attachments --path /tmp/morsel258-focused.xcresult \
  --output-path /tmp/morsel258-attachments
```

The committed PNGs are the exported attachments of that run (`.lane-logs/native-focused-5.log`,
raw exit 0, 7 tests / 0 failures). The full gate is the separate **one complete unfiltered**
invocation documented in the lane report.

The behaviour half of the issue — the read degrades, one unreadable row flags only its own meal,
and a failed refresh marks the cached day stale with a retry — is asserted in
`app/Tests/MorselTests/DayReadDegradeTests.swift`; the server-side day/dashboard contract is
asserted in `server/day-read-degrade.test.ts`.

## Explicitly unverified

Physical devices; a real failed Supabase read against production; the local-first cache's own
refresh scheduling and the History read path (sibling issues #180–#183 / #194 — the History read
is unchanged by this lane); authentication, gestures, and Health authorization. The notice copy
here is the lane's fixture day (5 Sep 2026, device clock), not a user's real day.

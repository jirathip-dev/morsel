# Issue 258 — day read degradation + honest cached/stale day, native simulator evidence

These are simulator fixtures, not a physical-device or live-data acceptance run. Every meal, item,
goal and target value is a fictional test input. No amount is a suggestion, preset or shipped
recommendation.

## What these captures test

Fix round 1 re-mints both states through the shipped repository composition:
`DashboardViewModel` → `LocalFirstDashboardRepository` (temporary account-scoped SQLite) →
`SupabaseDashboardRepository.loadToday` → controlled URL transport. The old stale captures at
`72a004b` used the bare remote repository and did NOT prove reachability through the local-first
facade. These captures replace that evidence; no production auth or data is used.

- **stale** — a refresh failed, so the day on screen is the last saved copy. It stays visible, but
  it is labelled as cached with the last successful load time and a retry: it is never presented as
  current (before this change a failed refresh was indistinguishable from "those meals don't
  exist"). The fixture loads the day successfully at 11:00 AM, then the `meal_logs` read fails at
  1:00 PM. The local-first facade returns the cached day with its original successful-read time.
- **degraded** — the day read degraded instead of aborting: one item row could not be read, so that
  read reports that one meal is incomplete while the day's partial totals still render. `meals: []` is
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

All four attachments were visually inspected and independently checked at 1179×2556 pixels.
Raw corner RGB values are `[254,248,234]` Paper / `[41,38,31]` Night in the exported PNG profile
(not color-managed sRGB token measurements). Both themes resolve and all four hashes are distinct.
The meal rows are below this viewport; the native tests assert their identities and completeness.
The two degraded attachments reproduce their earlier bytes exactly; both stale attachments changed.

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
  -derivedDataPath /tmp/morsel-258-fix1/dd -resultBundlePath /tmp/morsel-258-fix1/native-green.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:MorselTests/DayReadDegradeTests \
  -only-testing:MorselTests/DayReadCompositionTests \
  -only-testing:MorselTests/DayReadDegradeEvidenceTests
xcrun xcresulttool export attachments --path /tmp/morsel-258-fix1/native-green.xcresult \
  --output-path /tmp/morsel-258-fix1/attachments
```

The committed PNGs are the exported attachments of the fix-round run
(`.lane-logs/fix-1/native-green.log`, raw exit 0, 10 tests / 0 failures).
The receipt and selected raw output are committed in `fix-1/`. This is the round's focused native
gate; the previous unfiltered gate was NOT repeated and is not a claim about the repaired head.
Scratch DerivedData, result bundles and the replay tree are deleted after exporting evidence.

The behaviour half of the issue — the read degrades, one unreadable row flags only its own meal,
and a failed refresh marks the cached day stale with a retry — is asserted in
`app/Tests/MorselTests/DayReadDegradeTests.swift`; the server-side day/dashboard contract is
asserted in `server/day-read-degrade.test.ts`.

## Explicitly unverified

Physical devices; a real failed Supabase read against production; the local-first cache's own
refresh scheduling and the History read path (sibling issues #180–#183 / #194 — the History read
is unchanged by this lane); authentication, gestures, and Health authorization. The notice copy
here is the lane's fixture day (5 Sep 2026, device clock), not a user's real day.

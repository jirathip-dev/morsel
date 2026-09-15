# Issue #165 — unavailable-first aligned bands

This is a view-only port of approved Option 1 (aligned bands), within Variant A.
It adds a food-record comparison band below the existing weight trace. The
weight samples, whole-second dedupe, line/area/point marks, interpolation and
weight-change calculation are not changed. Both bands use the same Date domain
and horizontal plot insets. The lower band owns the shared date labels.

## What the production payload actually supports

Delta means recorded eaten calories minus that date's available food target.
It is a comparison of food-record values, not expenditure or a causal account
of weight change. A logged day means at least one meal, not complete intake.
Today is explicitly partial.

The production adapter intentionally supplies NO dated targets, including for
today. `HistoryOverview.goal` is one current goal, not dated provenance, and
`LocalFirstDashboardRepository.loadHistory` may silently return a cached
payload. A new read's invocation time therefore cannot establish target
freshness. No goal is borrowed from the ledger, current profile, today's screen
or a cached current-goal value. Missing targets appear as `?` with the explicit
“food target unavailable” key and receipt state. No numerical production
historical deltas are claimed by this V1.

The existing 7-day food window and fixed 30-day weight window are preserved.
When weights extend beyond the food query, `· food log unavailable` represents
those dates; that is different from a loaded day's `logged: false` (`× no food
log`). Missing logs have no eaten value and no delta, never zero intake.
An available real zero delta is `○`. Signed bars use the actual difference,
not the ledger's ±50-kcal classification tolerance, and the symmetric scale
expands rather than clipping. Missing weights are never manufactured; a
selected date without a sample says “no weight recorded”.

The existing separate ledger remains an against-current-goal comparison. Its
rows, summary math and source semantics are intentionally not redefined here.
`HistoryModels.swift` is unchanged. No backend, schema, RPC, resources, theme
tokens, journal navigation or calendar machinery is changed.

## Deferred contract decisions / escalation

Showing real historical numeric bars requires a separately approved dated
food-target/provenance contract. This lane does NOT decide:

- Storage/schema/RPC/tool ownership, snapshots versus an effective-dated history,
  or whether/when a target is captured.
- Goal edits, backdating, computed versus manual recency across old dates, or
  retroactive weight/profile recomputation.
- Day-only adjustments, baseline/source provenance, confirmation/edit/undo
  history, or integration with #226.
- Account timezone changes, day boundaries for target attribution, cache age,
  offline freshness, or how a dated current target survives midnight.
- Migration/backfill, missing-history inference, or target-history permissions.

`WeightDeltaDay` is an internal presentation value, not a new payload or
persistence format. The renderer's optional target/source values are exercised
only with explicitly fictional dated values in the tests; there is no
production resolver for them.

## Simulator evidence

`WeightDeltaCaptureTests` mounts the real chart in a simulator UIWindow at
393×852 points (iPhone 16), with the existing fonts and Paper/Night tokens.
The four frames separate the actual unavailable-first payload behavior from
explicitly illustrative dated-target renderer examples. The illustrative
frames are NOT evidence that the current API can supply those targets.

These are simulator-hosted component captures, not a physical device or a
signed-in live-account session. The base-compatible
`WeightDeltaSurfaceTests` additionally mounts the real History page with a
seeded repository and reads its rendered text with Apple Vision. Its tall
393×2400-point test window is a visibility probe, not phone-size evidence.
No app-entrypoint/auth bypass or production data write is used.

Reproduction: generate the Xcode project, boot a dedicated simulator, then run
`xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination
'platform=iOS Simulator,id=<UDID>' -derivedDataPath /tmp/xc-dd-165
CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO` from `app/` (on this
host set `HERDR_XCODEBUILD_DIRECT=1`). Run the complete scheme for the gate;
`-only-testing:MorselTests/WeightDeltaCaptureTests` is only a capture driver.
PNG output is `/tmp/morsel-165-captures/`. Serialize native invocations using
the brief's bounded process arbitration. Physical-device, VoiceOver and
real-touch selection/gesture acceptance remain unverified.

### Recorded verification

Final complete invocation (no skip/only filters): 404 tests, 0 failures,
0 skipped, raw exit 0. Simulator: `Morsel165-iPhone16`, iOS 26.5,
UDID `B12A09BE-2808-41C4-A25F-EEA3D0E3A44C`. All four captures are
1179×2556 pixels at 3×, produced by that invocation's capture test.

The base-compatible History paint probe failed by assertion at
`6f87585d2a8c1bac49237a7a4ac6654297619dbb`: missing comparison copy,
unavailable-target state and no-log key (raw exit 65). The same test passes
in the final native suite. Existing health truthfulness/dedupe and ledger
semantics passed in the base run and remain green at head. New model tests
cover signed/zero/unavailable values, missing-log exclusion, the full weight
window, calendar-day alignment across DST and non-clipping scales. Hosted
source probes separately prove shared plot-domain wiring; removing either
axis binding, food-day wiring or the unavailable-first adapter fails them.

An initial 403-test pass did NOT establish visible nonzero bars: pixel review
found that relative bar widths on continuous dates rendered no bars. The
added chart-only positive-versus-negative PNG test then failed (equal 1889-byte
images, raw exit 65; repeat-render control passed). Explicit point widths
fixed the renderer, and the final 404-test invocation passed that test and
recaptured both themes. Complete disclaimer text is now OCR-asserted too.
No initial failed-render captures are presented here as final evidence.

The full local `npm test` invocation returned 1: 566 passed, 8 timed out in
5000 ms across the three untouched server files named by the brief's known
host-load class (`http`, `render-png`, `tool-classification`), plus one unhandled
Vitest worker `Timeout calling "onTaskUpdate"` error. No retries,
timeout increases or skipped files were used. Hosted CI quality is NOT
verified by this lane. Typecheck, ESLint, strict SwiftLint and XcodeGen passed.
Raw local logs and command details are retained in `.lane-logs/` and the
untracked `.report.md` at the implementation checkout.

### Capture inventory (SHA-256)

- `payload-paper.png` — unavailable-first Paper:
  `31c1a8b3e8c77e734604574eacb121e3a56c35c8c080bb3f7a5c43c5bf9bab6e`
- `payload-night.png` — unavailable-first Night:
  `0700a2ef06cf31ad403f0b491b500703e4b6231faeca16b11fc1bbfeb02492f8`
- `illustrative-paper.png` — fictional dated-target Paper:
  `16d9280e1a73b21991d7bd817b5601d1d43b237c23a701d37a07595a4b42fbf9`
- `illustrative-night.png` — fictional dated-target Night:
  `ec50cc3f80c62267722e20cc2eb6e15fa9305636b64f1ace456be5c5842601f4`

The illustrative frames visibly include positive/negative bars, a real zero
circle, a target-unavailable question mark and an unlogged cross. Payload
frames contain no fabricated numeric delta. Both themes show the full
selected-day receipt and disclaimer. The pre-existing weight header's integer
rounding and fixed “over 30 days” caption remain unchanged; the added receipt
shows weight to one decimal place.

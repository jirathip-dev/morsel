# Warm-palette evidence — issue #32 (Guy-approved 2026-08-31)

Fresh iPhone 16 Simulator captures of the warm-orange palette build at this
commit. Guy's approval was based on a real warm-palette simulator run; these
captures reproduce that rendering on the shipped token set.

## Locked token map (this change)

| Role | Old (cool) | New (locked warm) |
| --- | --- | --- |
| accent / energy | `#3E63E8` cobalt | `#F08A2E` |
| accentSoft / energySoft | `#E9EEFC` cobalt tint | `#F6E8D8` |
| protein / coral / over / correction | `#6C5CE7` violet | `#C0483F` |
| carbs | `#F0A63C` | `#F0A63C` (unchanged) |
| carbsStart / underStart | `#FFC24B` | `#FFC24B` (unchanged) |
| fat | `#0FA6A0` teal | `#D46A2E` |
| low confidence | `#8A5514` | `#8A5514` (unchanged) |
| protein gradient | `#9C8BF5 → #6C5CE7` violet | `#C0483F → #C0483F` |
| fat gradient | `#37D5C2 → #0FA6A0` teal | `#F0A63C → #D46A2E` |
| under gradient | `#5BD8E6 → #1FA3C4` cyan | `#FFC24B → #F08A2E` |
| on gradient | `#3BC8A8 → #12A98E` emerald | `#F0A63C → #D46A2E` |
| over gradient | `#F7A98C → #E0765F` copper-rose | `#F7A98C → #C0483F` |

Neutrals are byte-for-byte unchanged (ink `#20231E`, inkTwo `#666A60`,
inkThree `#9BA095`, bg `#FBFAF6`, surface `#FFFFFF`, surfaceTwo `#F3F1EA`,
line `#E7E3D8`, cardEnd `#FBF9F2`); see `docs/DESIGN.md` for the normative
token table.

## Capture method (DEBUG-only, temporary)

- Device: iPhone 16 Simulator, id `59DDC0C5-891E-4EC0-91AF-4F50DF68D793`
  (iOS 26.x), booted fresh.
- Build: `xcodebuild build -project app/Morsel.xcodeproj -scheme Morsel
  -destination 'platform=iOS Simulator,id=<id>' -derivedDataPath .build/xc-dd
  CODE_SIGNING_ALLOWED=NO` (unsigned, Debug configuration).
- The capture harness was a TEMPORARY `#if DEBUG` block in `MorselApp.swift`,
  gated on `ProcessInfo.processInfo.environment["MORSEL_CAPTURE_DEMO"] == "1"`.
  When set, it rendered the real `TodayView` / `SettingsView` surfaces backed
  by the existing DEBUG `MockDashboardRepository` + `PreviewData` snapshot,
  and the real `OnboardingView` (sign-in step) — no Supabase client is created
  on that path, no credentials are involved, and Release builds are untouched.
  The harness was removed before commit; `git diff <base> -- app/Sources/Morsel/MorselApp.swift`
  is empty at the final SHA (see "Harness removal proof").
- Screens: `xcrun simctl io <id> screenshot <file>` after UI automation taps.

## Captures

| File | State |
| --- | --- |
| `today-warm.png` | Today dashboard — DEBUG PreviewData/MockRepository snapshot (breakfast + lunch incl. low-confidence "Stir-fried veg", computed goal 2,077 kcal), warm gauge ring + macro gradients |
| `settings-warm.png` | Settings screen (Goals / Agent sections) with warm accent |
| `onboarding-warm.png` | Onboarding first step ("Set up your food logger") with warm accent |

## Pixel inspection findings

Verified programmatically (PIL) on the raw PNGs after visual review:

- No cool pixels: fewer than 0.01% of pixels have hue in the blue/cyan/teal
  bands (180–260°) on any capture; dominant non-neutral hues are 20–45°.
- Warm accent present: 10th-percentile saturated-orange sample ≈ `#F08A2E`
  (±JPEG-free PNG sampling tolerance).
- Legible contrast: text regions (Today headline, tag rows, onboarding copy)
  measure ≥ 4.5:1 mean luminance contrast against their local background.
- No white/black full-frame outliers; backgrounds match `#FBFAF6` bg family.

## Limitations

- Simulator renders (not device): colors are sRGB; no Night-shift/True-Tone
  variance. No accessibility zoom/Dynamic-Type-large states captured.
- The low-confidence row tint and review flows use the same tokens; only the
  three states above were captured.
- The capture harness is not part of the commit; re-capturing requires the
  temporary DEBUG hook again (documented above).

## Harness removal proof

`git diff b7effa2d0fe10c16542ef2013f756aa3ab9925da <HEAD> --
app/Sources/Morsel/MorselApp.swift` is EMPTY at the final commit, and
`git log --oneline -- app/Sources/Morsel/MorselApp.swift` over the branch
shows no commit touching that file.

# Warm-palette evidence — issue #32 (Guy-approved 2026-08-31)

Fresh iPhone 16 Simulator captures of the warm-orange palette build,
**re-captured after fix round 1** (accessible ink/soft component pairs) on top
of `origin/main` `45d58ba`. Guy's approval was based on a real warm-palette
simulator run; these captures reproduce that rendering with the final
accessible component states.

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

## Component contrast (fix round 1, WCAG 2.x relative luminance)

| Pair | Ratio |
| --- | --- |
| high-confidence tag: ink `#20231E` on accentSoft `#F6E8D8` | **13.22:1** |
| low-confidence tag: low `#8A5514` on energySoft `#F6E8D8` | **5.15:1** |
| btn-confirm label: ink `#20231E` on accent `#F08A2E` | **6.35:1** |
| btn-confirm hover: ink `#20231E` on accentSoft `#F6E8D8` | **13.22:1** |
| source tag: inkTwo `#666A60` on surface `#FFFFFF` (unchanged) | 5.53:1 |

These are computed by the executable helpers in `app/warm-palette.test.ts`,
which fail if any covered pair drops below WCAG AA 4.5:1. (Previous round's
incorrect "tag rows ≥ 4.5:1" claim for accent-on-soft, which measured 2.08:1,
was corrected here; high confidence now uses ink on accentSoft.)

## Capture method (DEBUG-only, temporary)

- Device: iPhone 16 Simulator, id `59DDC0C5-891E-4EC0-91AF-4F50DF68D793`,
  booted.
- Build: `xcodebuild build -project app/Morsel.xcodeproj -scheme Morsel
  -destination 'platform=iOS Simulator,id=<id>' -derivedDataPath .build/xc-dd
  CODE_SIGNING_ALLOWED=NO` (unsigned, Debug configuration).
- The capture harness was a TEMPORARY `#if DEBUG` block in `MorselApp.swift`,
  gated on `ProcessInfo.processInfo.environment["MORSEL_CAPTURE_DEMO"]`.
  When set, it rendered the real `TodayView` / `SettingsView` surfaces backed
  by the existing DEBUG `MockDashboardRepository` + Preview-style snapshot,
  and the real `OnboardingView` (sign-in step) — no Supabase client is created
  on that path, no credentials are involved, and Release builds are untouched.
  The harness was removed before commit; at the final SHA
  `git diff 45d58ba -- app/Sources/Morsel/MorselApp.swift` is empty
  (byte-identical), so no capture hook is committed.
- Screens: `xcrun simctl io <id> screenshot <file>` after launching with the
  capture environment variable; no UI automation required.

## Captures

| File | State |
| --- | --- |
| `today-warm.png` | Today dashboard — DEBUG PreviewData/MockRepository snapshot (breakfast + lunch incl. high-confidence `0.90` tag now ink-on-cream, low-confidence "Stir-fried veg" with `verify` tag, computed goal 2,077 kcal) |
| `settings-warm.png` | Settings screen (Goals / Agent sections) with warm accent |
| `onboarding-warm.png` | Onboarding first step ("Set up your food logger") with warm accent |

## Pixel inspection findings (final images)

Verified programmatically (PIL) on the raw PNGs after visual review:

- No cool pixels: cool-hue share (saturation > 0.15, hue 180–260°) is
  **0.0000%** on all three captures; the only green pixels are the iOS
  status-bar battery glyph (identical across captures — OS chrome, not app).
- Warm accent present throughout (gauge ring, kcal figures, macro bars, brand
  text, progress capsule, selected tab).
- Background samples match locked `#FBFAF6`.
- Overall ink-vs-background luminance contrast on all three screens is high
  (≈19:1 modal-background vs darkest-ink estimate); per-component WCAG values
  are the authoritative numbers in the table above.

## Limitations

- Simulator renders (not device): colors are sRGB; no Night-shift/True-Tone
  variance. No accessibility zoom/Dynamic-Type-large states captured.
- The low-confidence row tint and review flows use the same tokens; only the
  three states above were captured.
- The capture harness is not part of the commit; re-capturing requires the
  temporary DEBUG hook again (documented above).

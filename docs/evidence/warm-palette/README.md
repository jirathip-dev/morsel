# Warm-palette evidence — issue #32 (approved V1 "Orange Hearth + Sage")

Fresh iPhone 16 Simulator captures of the **approved V1 palette**
(`accent #E66A2C`, `bg #FFF7E8`, forest/leaf support, mustard highlights)
on top of `origin/main` `45d58ba`, **re-captured after the V1 review-r1 AA
fixes** (the six small warm-ground wordmark/label sites moved from accent to
compliant forest `#2F654B` on their ground; 6.39:1). These re-place the
earlier warm-orange (r1) captures; the r1 locked values
(#F08A2E / #F6E8D8 / #C0483F family) are retired everywhere.

## V1 token map (this change)

| Role | r1 warm-orange (removed) | Approved V1 |
| --- | --- | --- |
| bg | `#FBFAF6` | `#FFF7E8` |
| surface | `#FFFFFF` | `#FFFCF5` |
| surface2 | `#F3F1EA` | `#F2E9D9` |
| line | `#E7E3D8` | `#E3D2BA` |
| ink | `#20231E` | `#2A261F` |
| ink2 | `#666A60` | `#655A4B` |
| ink3 | `#9BA095` | `#756955` |
| accent / energy | `#F08A2E` | `#E66A2C` |
| accentSoft / energySoft | `#F6E8D8` | `#FBE1C9` |
| leaf / leafSoft | — | `#5E7E57` / `#E1E9D7` |
| forest | — | `#2F654B` |
| coral | `#C0483F` | `#B94738` |
| mustard / mustardDeep | — | `#D6A62C` / `#A5750B` |
| review / low-confidence text | `#8A5514` | `#7A3D2B` |
| over | `#C0483F` | `#9C3A2F` |
| protein gradient | `#C0483F → #C0483F` | `#C9513D → #A63A32` (measured) |
| carbs gradient | `#FFC24B → #F0A63C` | `#B07A13 → #875A02` (measured) |
| fat gradient | `#F0A63C → #D46A2E` | `#6B8B60 → #3F6745` (measured) |
| gauge gradient | accent-based | `#6B8B60 → #2F654B` (measured) |
| cardEnd | `#FBF9F2` | `#FFF5E5` |

Measured-data gradient stops are the documented measured-data treatment from
the approved `TOKENS.md`/`GRADIENTS.md`; never scalar/background decoration.

## Component contrast (approved V1, WCAG 2.x relative luminance)

| Pair | Ratio |
| --- | --- |
| primary text: ink `#2A261F` on bg `#FFF7E8` | **14.13:1** |
| btn-confirm label: ink `#2A261F` on accent `#E66A2C` | **4.63:1** |
| high-confidence tag: forest `#2F654B` on leafSoft `#E1E9D7` | **5.46:1** |
| needs-review/low tag: review `#7A3D2B` on accentSoft `#FBE1C9` | **6.61:1** |
| btn-confirm hover: ink `#2A261F` on accentSoft `#FBE1C9` | **11.98:1** |
| over-goal text: over `#9C3A2F` on bg `#FFF7E8` | **6.45:1** |

All pairs computed by the executable helpers in `app/warm-palette.test.ts`,
which fail if any covered pair drops below WCAG AA 4.5:1 and pin the exact
call sites (SwiftUI `ConfidenceTag`, primary button style, prototype rules).

## Capture method (DEBUG-only, temporary)

- Device: iPhone 16 Simulator, id `59DDC0C5-891E-4EC0-91AF-4F50DF68D793`,
  booted; unsigned Debug build via `xcodebuild build … CODE_SIGNING_ALLOWED=NO`.
- The capture harness was a TEMPORARY `#if DEBUG` block in `MorselApp.swift`
  (it temporarily replaced the `@main` entry point because Swift allows only
  one `@main` per module), gated on
  `ProcessInfo.processInfo.environment["MORSEL_CAPTURE_DEMO"]`. It rendered
  the real `TodayView` (backed by the DEBUG `MockDashboardRepository` +
  Preview-style snapshot) and the real `OnboardingView` sign-in step — no
  Supabase client is created on that path, no credentials involved, Release
  builds untouched. The harness was removed after capture; at the final SHA
  `git diff 45d58ba -- app/Sources/Morsel/MorselApp.swift` is empty
  (byte-identical, SHA-256 `bed9e9f1…`), so no capture hook is committed.
- Screens: `xcrun simctl io <id> screenshot <file>` after launching with the
  capture environment variable; no UI automation required.

## Captures

| File | State |
| --- | --- |
| `today-warm.png` | Today dashboard — real `TodayView` with DEBUG mock snapshot (forest `morsel` wordmark, high-confidence `0.90` tag forest-on-leafSoft, low-confidence "Stir-fried veg" row with accentSoft tint + `0.70`/`verify` review tags above the fold, forest ring, orange kcal anchors, measured macro gradients) |
| `onboarding-warm.png` | Onboarding first step ("Let's set up your food logger.") with forest `morsel` wordmarks, orange progress capsule, orange `Send email code` button |
| `settings-warm.png` | **Known limitation:** captured from the real private `SettingsView` inside the temporary harness — but the bare harness context omits the production TabView-level `.tint(Color.morselAccent)`, so the Form renders its rows with Apple's system-blue tint (`#007AFF`) instead of V1 accent. The shipped app wraps `SettingsView` in the tinted TabView (`.tint(Color.morselAccent)` in `MorselApp.swift`), so production renders orange. Replacing this capture 1:1 requires a harness that reproduces the production tint context, which was out of scope for this round; the V1 contract for this screen is enforced by the token + call-site tests, not by this PNG. |

## Pixel inspection findings (final images)

Verified programmatically (PIL) on the raw PNGs after visual review:

- `today-warm.png`: cool-hue share (saturation > 0.15, hue 180–260°) is
  **0.0000%**; dominant background `RGB(248,240,232)` ≈ V1 `bg` `#FFF7E8`
  (255,247,232) — the small offset is the gauge card's surface tint plus
  anti-aliasing; visually and numerically the warm-paper V1 ground.
- `onboarding-warm.png`: cool share **0.1830%**, all of it one bbox around
  the EMAIL field placeholder `RGB(0,122,255)` — Apple's system-blue
  UITextField placeholder color (OS chrome, same class as the black
  Sign-in-with-Apple button), not an app-drawn palette color.
- `settings-warm.png`: captured outside the production tint context (see
  limitation above); rows show the iOS system tint instead of accent.
- Warm V1 accent present throughout Today (forest ring, orange kcal figures,
  macro gradient bars, brand text, progress capsule).
- Per-component WCAG values are the authoritative numbers in the contrast
  table above.

## Limitations

- Simulator renders (not device): sRGB; no Night Shift/True-Tone variance.
  No accessibility zoom/Dynamic-Type-large states captured.
- Settings capture carries the documented harness-context limitation above.
- The capture harness is not part of the commit; re-capturing requires the
  temporary DEBUG hook again (documented above).

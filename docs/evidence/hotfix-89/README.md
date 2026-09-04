# Hotfix #89 evidence — v0.4 dark-mode leak, '+' halo, HealthKit copy, goals inset

Screenshots proving the v0.4 hotfix on **issue #89** (device/simulator in
**Dark appearance**): Today, Settings, and Daily goals all render the warm
paper palette with ink text (the app is LIGHT-ONLY until night-ink #90), the
`+` control carries exactly one background, and the goals editor keeps a
bottom inset clear of the floating tab bar.

## Mechanism (item 1 — forced light)

- Chosen: root `.preferredColorScheme(MorselAppearance.scheme)` on the
  `WindowGroup` content in `MorselApp.swift`, where `MorselAppearance.scheme`
  (app/Sources/Morsel/MorselAppearance.swift) is the small internal seam
  asserting `.light` (issue-spec-sanctioned alternative). r1 review added the
  seam so an XCTest can compile against the real mechanism.
- The plist route was tried first and rejected with proof: this target uses
  `INFOPLIST_FILE: ../fastlane/Morsel-Info.plist` (a custom template that
  references every runtime key explicitly via `$(INFOPLIST_KEY_*)`
  placeholders). `INFOPLIST_KEY_UIUserInterfaceStyle: Light` in project.yml
  **does not land in the built Info.plist** (verified on the built
  `Morsel.app/Info.plist` after a full xcodebuild — key absent while the
  template-referenced keys are present). Making the plist route work would
  require editing the fastlane plist template = release tooling = STOP-and-
  report per the brief fences, so the root modifier (pure `app/` source) is
  the fix. The screenshots below are the runtime proof that the modifier
  forces every system surface light under a Dark device; hosted
  `app/hotfix-89-contract.test.ts` pins the modifier so it cannot regress
  silently (native XCTest cannot observe it: the unhosted unit-test bundle
  has no rendered scene and no source path).

## Item fixes

| Item | Fix | Proof |
| --- | --- | --- |
| 1 light-only app | `.preferredColorScheme(.light)` on the root scene content | today/settings/goals captures below, device appearance **Dark** |
| 2 Settings paper + ink | `Form` gets `.scrollContentBackground(.hidden)` + `Color.morselBackground` background; rows ink (`Color.morselInk` / `inkTwo`), headers `morselSectionLabel` | `settings-dark.png` |
| 3 `+` one background | iOS 26 draws its glass container around **every** ToolbarItem (verified: `.plain`, `.borderless`, and even icon-only plain buttons all keep the glass circle), so the accent pill lives in the Today content header: `.buttonStyle(.plain)`, ONE `.background(Color.morselAccent, in: RoundedRectangle(cornerRadius: 8))`, ink label | `today-dark.png` (no ring); contrast table below; probe asserts no `ToolbarItem` + exactly one background |
| 4 HealthKit human copy | `HealthSyncUserMessage.userMessage(for:)` — entitlement/domain/`HKError` text can never reach UI; both `weightImportError` paths map | `HealthSyncCopyTests` (5 XCTest) + hosted probe |
| 5 goals bottom inset | GoalsEditorView content bottom padding 96pt (same clearance as Today) | `goals-dark.png` — "See it" fully visible, tab bar below it |

## Contrast (measured, WCAG 2.x relative luminance — same helper math as
`app/warm-palette.test.ts`, re-asserted in `hotfix-89-contract.test.ts`)

| Pair | Ratio | Requirement |
| --- | --- | --- |
| ink `#2A261F` on accent `#E66A2C` (`+` label) | **4.63:1** | ≥ 3:1 ✓ (also AA ≥ 4.5) |
| ink `#2A261F` on bg `#FFF7E8` (label vs page) | **14.13:1** | ≥ 3:1 ✓ |
| accent `#E66A2C` on bg `#FFF7E8` (pill vs page) | **3.05:1** | ≥ 3:1 ✓ (WCAG 1.4.11 non-text boundary) |

The ink label is the DESIGN.md btn-confirm pair ("orange never carries a
white label"); the old surface2 ghost pill measured ~1.1:1 against the page
(only the halo made it findable), and the forbidden white label on accent is
3.25:1 — both reasons the filled accent + ink treatment is correct here.

## Capture method (DEBUG-only, temporary — nothing committed)

- Device: iPhone 16 Simulator, UDID `59DDC0C5-891E-4EC0-91AF-4F50DF68D793`,
  booted; unsigned Debug via `xcodebuild build … CODE_SIGNING_ALLOWED=NO`.
- Temporary `MORSEL_CAPTURE_TAB`-gated harness replaced the production `@main`
  in `MorselApp.swift` (`CAPTURE-HARNESS-ACTIVE`), mirroring the production
  root `.preferredColorScheme(.light)` and tab shell (TabView +
  `MorselActionTint` + floating bar) with the REAL `TodayView`,
  `SettingsView`, and `GoalsEditorView` backed by the DEBUG
  MockDashboardRepository` — no Supabase client, no credentials, no network.
  Harness removed after capture: the code-vs-evidence commit split proves it —
  `git diff 754dfdc 8618731 -- app/Sources/Morsel/MorselApp.swift` is empty
  (the source fix itself lives in 754dfdc, so comparing against the issue
  base 44e77f8 is NOT empty) and no `CAPTURE-HARNESS-ACTIVE`/
  `MorselCaptureApp` string remains.
- `xcrun simctl ui <UDID> appearance dark` before each launch;
  `xcrun simctl io <UDID> screenshot <file>` after launch settle; appearance
  restored to light afterwards.

## Captures

| File | State | Data state |
| --- | --- | --- |
| `today-dark.png` | Today — cream paper + ink; `+ Add meal` accent pill top-right with **no halo ring**; light tab bar; forest ring/orange kcal/macro gradients; floating tab bar | DEBUG mock snapshot: breakfast "Greek yogurt & granola" (0.90 high), lunch "Jasmine rice" + "Stir-fried veg" (0.70 needs-review style row), computed goal 2,077 kcal |
| `settings-dark.png` | Settings — cream page, light system cells, ink rows, taupe GOALS/AGENT headers, orange "Replay onboarding" | Same mock repository; MCP endpoint shows the unconfigured copy (Debug unsigned build has empty `MORSEL_MCP_URL`) |
| `goals-dark.png` | Daily goals — cream + ink everywhere; bottom 96pt inset keeps "See it" clear of the floating tab bar | Computed goal 2,077 / 156 / 233 / 58 pre-filled (`source: computed`), zero meals eaten today |

Harness-context notes (honest): the goals screen is presented as the real
`GoalsEditorView` at the Settings tab's stack root (production pushes it from
Settings — identical chrome minus the back chevron); mock meal timestamps are
the launch time (all `Date()`); Today shows the provenance/confidence tags as
the app always renders them (mono data vocabulary).

## Pixel inspection (final PNGs)

Programmatic checks (PIL): settings/goals/today page fields sample the cream
token (`RGB(255,247,232)` ≈ `#FFF7E8`) around the light cells; the Settings
form cells sample `RGB(255,255,255)` (system light inset-grouped cell — no
`#1C1C1E`/`#000` dark cells anywhere); no pure-black app surfaces beyond the
hardware Dynamic Island. Contrast numbers above are the authoritative
figures.

## Scope scan

Changed: `app/project.yml` (unmodified at final commit — mechanism is source-
level), `app/Sources/Morsel/{MorselApp,Views,GoalsEditor,HealthKitWeightImporter,ViewModel}.swift`,
`app/Morsel.xcodeproj/project.pbxproj` (xcodegen regen for the new test file;
byte-stable on re-run), `app/Tests/MorselTests/HealthSyncCopyTests.swift`
(new), `app/hotfix-89-contract.test.ts` (new hosted probe), this directory.
No server/supabase/fastlane/workflow/lockfile changes; no DESIGN.md edit
needed (btn-confirm wording already matches the accent+ink control).

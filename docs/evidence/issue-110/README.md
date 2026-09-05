# Issue #110 evidence — Settings re-inks immediately on Paper/Night switch

Repo-local evidence for the issue #110 implementation lane
(issue/110-settings-theme). Proves AC1/AC2: tapping Night ink inside the
presented Settings page re-inks the Settings page itself immediately —
ground, text, rules, grain, controls — without closing Settings, and Paper /
Follow system resolve through the same seam.

## The seam and the fix (summary)

`MorselApp.swift` applies `.preferredColorScheme(MorselAppearance.scheme(for:))`
to the WindowGroup root, but Settings is presented with `.fullScreenCover`
(MorselApp.swift, `AuthenticatedDashboardView`) — a separate UIKit
presentation that does not re-resolve the presenting hierarchy's
`preferredColorScheme` change while it is up. The fix (Option A, minimal)
re-asserts the same preference-derived scheme on EACH presented cover root:
`AuthenticatedDashboardView` reads the same `@AppStorage` key
(`morsel.appearance.theme`) and its Settings and Onboarding
`fullScreenCover` contents each carry
`.preferredColorScheme(coverColorScheme)`. When the Night-ink button writes
the key inside Settings, the shell re-renders and the presented cover
re-resolves its traits immediately.

Pinned by: `app/issue-110-settings-theme-contract.test.ts` (hosted probe —
one anchored slice per cover root; deleting either site's modifier fails its
own slice; mutation-RED 2 failed / exit 1 verified) + existing
`JournalThemeImmediacyTests` and the hotfix-89 root-seam probe stay green.

## Captures (393×852 pt @3x = 1179×2556 px, iPhone 16 simulator)

UDID `59DDC0C5-891E-4EC0-91AF-4F50DF68D793`, unsigned Debug
(`CODE_SIGNING_ALLOWED=NO`), iOS 26.5 sim, no TestFlight, no network, no
Supabase client (local-first SQLite stack with an empty account store).

| file | what it shows |
| --- | --- |
| `settings-paper.png` | Settings fullScreenCover presented over the journal — Paper ground `#FFF7E8`, warm copy/rules/grain, Appearance row with Night ink unselected |
| `settings-night.png` | the SAME still-presented Settings cover after the stored theme preference flipped Paper → Night ink — ground `#2A261F`, cream copy, marker strokes, no system-black Form/bar leak |

### Capture method and honest limitation

- A temporary `CAPTURE-HARNESS-ACTIVE` entry point replaced the production
  `@main` in `MorselApp.swift` and drove the REAL shell: `SessionStore`
  seeded with a fixture `AuthenticatedSession` (no credentials), onboarding
  pre-completed for the fixture user, `supabaseClient: nil` — so the real
  `MorselRootView` → `AuthenticatedDashboardView` chain (including the two
  real `fullScreenCover` sites and the fixed `.preferredColorScheme`
  seam) runs unchanged against the local-first empty store.
- The harness opened Settings through the shell's own
  `showingSettings` state ~0.5 s after launch, then wrote the SAME
  `UserDefaults` key the Night-ink button writes
  (`morsel.appearance.theme` = `nightInk`) at t+7 s while the cover stayed
  presented. Frame 1 was captured before the flip, frame 2 after it — both
  with Settings still up. No touch-injection tool exists on this host
  (stated honestly, same limitation as the #105 evidence): the button tap
  and the programmatic write are the identical
  `@AppStorage`/`UserDefaults` mutation the fix reacts to, and the seam
  under test (cover root re-asserting `scheme(for:)` from the shared key)
  is exercised end to end in the real shell.
- Device appearance was set light before launch (Paper forces light);
  Night ink forces dark through the same seam.
- After capture `MorselApp.swift` was restored byte-for-byte from the
  committed implementation head: sha256
  `2a96f23d05a54109fe3445e77e85e48c930b06e393caa5eb3a2c6d1d3fc0e990`
  matches, `git diff HEAD -- app/Sources/Morsel/MorselApp.swift`
  is 0 lines, and no `CAPTURE-HARNESS-ACTIVE` / `MorselCaptureApp` string
  remains in any shipped Swift source (grep over `app/Sources/Morsel`).

## Pixel audit (programmatic, PIL)

- `settings-paper.png` samples the Paper ground token `#FFF7E8` (dominant
  grid sample, 42,538 of ~47,000 counts); Night-ink frame samples the
  Night-ink ground `#2A261F` with the identical dominant count — the two
  frames are the same still-presented layout, re-inked.
- The Appearance row itself re-rendered: the selection marker moves Paper →
  Night ink between the frames (visual check of both PNGs).
- No `#000000` system-black regions on the Night surface outside the
  status-bar band (rows 36–140 = Dynamic Island/status chrome; identical
  band on the Paper frame); the Settings page body has zero black pixels.
  Near-black grid share 1.2–1.3% on both frames, all inside that top band.

## Gate results at the implementation head

See `logs/` — each log is the raw command output; raw exit codes:

| gate | command | raw exit |
| --- | --- | --- |
| XcodeGen byte stability | `cd app && xcodegen generate && git diff --exit-code -- Morsel.xcodeproj/project.pbxproj` | 0 (`logs/gate-xcodegen.log`) |
| Native build/test (iPhone 16 sim, unsigned) | `/usr/bin/xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,id=59DDC0C5-891E-4EC0-91AF-4F50DF68D793' -derivedDataPath <lane cache> CODE_SIGNING_ALLOWED=NO` | 0 (`** TEST SUCCEEDED **`, 143 tests / 0 failures — `logs/gate-xcodebuild-test.log`) |
| SwiftLint strict | `cd app && swiftlint lint --strict --quiet` | 0 (`logs/gate-swiftlint.log`) |
| Hosted app probes | `npx vitest run app/` | 0 (8 files / 65 tests — `logs/gate-vitest-app-probes.log`) |
| Probe mutation-RED | modifiers removed → `npx vitest run app/issue-110-settings-theme-contract.test.ts` | 1 (2 failed / 3 — `logs/probe-red-mutation.log`) |
| Probe GREEN at head | `npx vitest run app/issue-110-settings-theme-contract.test.ts` | 0 (3 passed — `logs/probe-green.log`) |
| Full hosted suite | `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 npm test` | 1 — **416/416 tests pass** across 35 files; raw exit 1 is the pre-existing vitest worker-teardown RPC timeout (`Timeout calling "onTaskUpdate"`), the identical failure class recorded at pristine base in the issue-106 evidence (`logs/npm-test-full.log`). App probes + this lane's probe exit 0 per-file |
| Capture build (harness) | `/usr/bin/xcodebuild build … CODE_SIGNING_ALLOWED=NO` | 0 (`** BUILD SUCCEEDED **` — `logs/gate-capture-build.log`) |
| Whitespace | `git diff --check` at the final committed head | 0 |

Note: a PATH shim in fleet panes routes bare `xcodebuild` simulator test
actions through `hermes-sim-task`, which fails this host's simulator
orchestration ("simulator did not reach booted state", #105 precedent);
the native gate therefore runs the canonical `/usr/bin/xcodebuild` with the
lane's external DerivedData path
(`/Volumes/NVMe2TB/BuildCaches/herdr-build-cache/morsel-bd5866df7b69c0b0/DerivedData`)
— same command otherwise, matching `herdr-xcodebuild`'s rewrite target.

## Files changed by the lane

`app/Sources/Morsel/MorselApp.swift` (cover-root scheme seam),
`app/Sources/Morsel/SessionStore.swift` (new — SessionStore moved out of
MorselApp.swift to keep the shell file under the SwiftLint file_length
ceiling), `app/Morsel.xcodeproj/project.pbxproj` (XcodeGen, new file),
`app/Tests/MorselTests/OnboardingTests.swift` (root-wiring test follows the
SessionStore file move), `app/issue-110-settings-theme-contract.test.ts`
(new hosted probe), this evidence directory.

NOT MERGED; no TestFlight dispatch; no live acceptance.

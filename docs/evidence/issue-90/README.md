# Issue #90 evidence — approved V1 naturalist field-journal design contract (promoted)

This directory is the **repo-local source of truth** for the Guy-approved V1
design (issue #90 approval comment issuecomment-5535107693, 2026-09-04),
promoted into the repository by the issue #94 implementation lane before any
code was written. It is the contract the native SwiftUI app implements: Paper
and Night-ink journal pages, Today · History · Goals primary tabs, inked
calorie ring with wash fill, macro wash strips, hand-lettered headings, warm
paper surfaces, and honest state treatment.

The prototype wins for look/interaction; the issue #94 acceptance criteria win
for behavior/tests. **HTML geometry and web controls are not part of this
contract** — no `v1-inked-ring.html`, CSS, gradients, or browser mechanics are
promoted here.

## Provenance (byte-exact)

| item | value |
| --- | --- |
| Source | `/Users/jirathip/Projects/design-output/morsel/90-journal-redesign/` (round 2 material pass) |
| Selected variant | **V1** only (`90-V1-*.png`); V2/V3 were rejected as implementation targets and are retained only as comparison evidence upstream |
| Frames | 36 PNGs = 18 C6 states × Paper/Night-ink; all exactly **390×844** |
| Integrity | every PNG verified sha256-identical to `manifest.sha256` in the source directory at promotion time |
| Approval | issue #90 comment `issuecomment-5535107693` (Guy, 2026-09-04) |
| Promotion lane | issue #94 (`.brief.md` Step 0) |
| Font assets | OFL-licensed Caveat / EB Garamond (+Italic) / IBM Plex Mono shipped to the app bundle by the #94 lane — see `app/Fonts/` and the lane's `.impl-evidence.md` |

## Artifact map

States per screen: Today `default|empty`; History `list|day|30d`; Goals
`default|invalid|saved`; Onboarding `signin|signedin|connect|coach|confirm|done`;
plus `addmeal`, `review`, `settings`, `signin`.

| file pattern | surface |
| --- | --- |
| `90-V1-today-{default,empty}-{paper,night}.png` | Today: hero ring + macro wash strips + meal log |
| `90-V1-history-{list,day,30d}-{paper,night}.png` | History: 7/30 bars vs goal, summary, drill-down, weight trend |
| `90-V1-goals-{default,invalid,saved}-{paper,night}.png` | Goals editor (primary tab) states |
| `90-V1-addmeal-*`, `90-V1-review-*` | add-meal sheet and low-confidence review surfaces |
| `90-V1-settings-*` | Settings (Appearance / MCP / Replay / Health / Sign out / version) |
| `90-V1-signin-*`, `90-V1-onboarding-{signin,signedin,connect,coach,confirm,done}-*` | auth + onboarding |

See `tokens.md` in this directory for the token/role map. Locked decisions A1–D3,
motion mapping, and the measured WCAG tables are recorded in the design-output
README (same directory as the manifest); the strict-pair floors are re-asserted
natively by the #94 regression tests and `app/warm-palette.test.ts`.

## Native captures (issue #94 implementation evidence)

Six simulator screenshots (per primary tab × Paper/Night ink) prove the
approved V1 look rendered natively by the SwiftUI app.

| file | state |
| --- | --- |
| `94-native-today-paper.png` / `94-native-today-night.png` | Today: inked ring + wash macro strips + journaled log; eaten 1,214 vs computed goal 2,100 (`886 kcal left`), P 75/150 · C 155/220 · F 29/70, `moved 386 kcal today` margin note |
| `94-native-history-paper.png` / `94-native-history-night.png` | History (7 days): `Calories vs goal` bars, ±50 goal band, hatched over day (2,260), today ghosted `· partial`, summary 2,024 avg / 1 over / 5 logged / 6-day streak, Days-vs-goal deltas |
| `94-native-goals-paper.png` / `94-native-goals-night.png` | Goals primary tab: daily-goals journal editor (computed 2100.0/150.0/220.0/70.0 fields, `Use these goals`, WHAT CHANGES, See it) |

### Capture provenance

- Device: iPhone 14 simulator, UDID `CBF7A3D7-37D0-424E-8FE7-40EAF3FB3652`
  (390×844 pt; screenshots at 3× = 1170×2532 px), iOS 26.5, unsigned Debug
  build (`xcodebuild build … CODE_SIGNING_ALLOWED=NO`), no TestFlight.
- Method: temporary DEBUG harness replaced the production `@main`
  (`CAPTURE-HARNESS-ACTIVE`) and drove the REAL `AuthenticatedDashboardView`
  shell with `MockDashboardRepository` — no Supabase client, no credentials,
  no network. Theme and tab were selected per launch via
  `SIMCTL_CHILD_MORSEL_CAPTURE_THEME` / `_TAB`; the simulator appearance was
  set to light for Paper and dark for Night ink before each launch
  (`xcrun simctl ui <UDID> appearance …`), then
  `xcrun simctl io <UDID> screenshot`. Harness removed after capture: no
  `CAPTURE-HARNESS-ACTIVE`/`MorselCaptureApp` string remains in any shipped
  Swift source and `MorselApp.swift` carries only the implementation diff.
- Fixtures: deterministic V1 arithmetic (1,214 eaten vs 2,100 computed goal,
  macros 75/155/29, active energy 386, 30-day ledger with one over day in the
  7-day window, weight trend ≈ −1.5 kg over 30 days). Dates are real capture
  dates. On Goals, no direction chip is pre-selected (the editor shows the
  stored computed targets honestly; picking a direction recomputes).
- Typography: the bundled OFL fonts (Caveat / EB Garamond (+Italic) /
  IBM Plex Mono) registered by `MorselFontCatalog` render natively — no
  network font fetch.
- Pixel audit (programmatic): Paper pages sample `#FFF7E8`; Night-ink pages
  sample `#2A261F`; macro washes sample the Paper pigment bases
  (`#BF5546`/`#AC7F1D`/`#6B8863`) and Night soft roles
  (`#FBE1C9`/`#D6A62C`/`#E1E9D7`); text is the mono/serif/hand voices with no
  tofu. Status-bar time/battery are real simulator chrome.

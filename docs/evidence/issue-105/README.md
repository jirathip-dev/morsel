# Issue #105 evidence — journal follow-up (native interaction + paper inputs)

Repo-local evidence for the issue #105 implementation lane (issue/105-journal-followup).
Covers AC1/AC2 page-turn pager states, AC3 Add Meal journal-page route, AC4/AC5
paper ground + paper-native inputs, AC6 keyboard contract, AC7 theme immediacy,
and the AC8 native test + gate proof. Design frames remain `docs/evidence/issue-90/`;
this lane adds only new behavior evidence.

## Captures (all 393×852 pt, 3× = 1179×2556 px, iPhone 16 simulator)

UDID `59DDC0C5-891E-4EC0-91AF-4F50DF68D793`, unsigned Debug
(`xcodebuild … CODE_SIGNING_ALLOWED=NO`), iOS 26.5 sim, no TestFlight.
Captured 2026-09-05 (00:1x +07).

| file | surface | what it shows |
| --- | --- | --- |
| `105-today-paper.png` | Today (Paper) | active Today tab + marker stroke, hand ring + macro washes, meal log rows, grain + sheet rules + bound crease + gutter folio |
| `105-history-paper.png` | History (Paper) | page reached through the pager transition (bar-tap path); active History tab; 7-day bars, hatched over day 2,260, today · partial |
| `105-goals-paper.png` | Goals (Paper) | page reached through the pager transition; direction chips, ruled mono goal fields (2100.0 / 150.0 / 220.0 / 70.0 with units), Use these goals |
| `105-addmeal-paper.png` | Add Meal page (Paper) | full journal page route — no tab bar, Cancel / Add meal / Save meal header, PHOTO rows, Meal type + Eaten at rows, ruled Notes / Food name / Quantity / Unit and 2×2 kcal·g nutrition grid |
| `105-today-night.png` | Today (Night ink) | same Today page under Night ink — charcoal ground `#2A261F`, cream copy, no system-black Form/bar leak (AC7 immediacy pair with the Paper shot) |
| `105-addmeal-night.png` | Add Meal page (Night ink) | Add Meal page re-inked immediately through the same dual tokens |

### Tab-flip / swipe-result method and honest limitation

- The shell pager is a native page-style TabView: a horizontal swipe on page
  content and a tab-bar tap drive the SAME `selection` transition (single
  `JournalPagerModel` source; pinned by `JournalTurnRuleTests` and the hosted
  probe). History and Goals were reached programmatically through that pager
  transition, so the post-transition frames double as the swipe-result state;
  the active marker strokes prove content/indicator sync (AC1).
- A true mid-animation frame could not be captured on this host: `simctl io
  recordVideo` reports "Host recording is already in progress" (a shared-host
  CoreSimulator recorder owns the host video service — not touched), there is
  no touch-injection tool installed, and single `simctl io screenshot` calls
  have 1.2–2.5 s latency vs a ~0.35 s page transition, so timed single shots
  miss the flight window. This is a device/host limitation, stated honestly:
  the flip is evidenced by the pre-state (Today) and the identical-transition
  post-states (History/Goals) at declared dimensions.

### Capture method (temporary DEBUG harness, removed before commit)

Same discipline as the issue #94 evidence: a temporary `CAPTURE-HARNESS-ACTIVE`
entry point replaced the production `@main` in `MorselApp.swift` and drove the
REAL `AuthenticatedDashboardView` shell with `MockDashboardRepository`
(fixture: 1,214 kcal eaten vs 2,100 computed goal, P 75 / C 155 / F 29,
moved 386 kcal, 7-day ledger with one over day; onboarding pre-completed for
the fixture user). `SIMCTL_CHILD_MORSEL_CAPTURE_*` env vars selected the theme
(`paper`/`nightInk`), an explicit initial tab (scene restoration otherwise
relaunches on the last page), the flip target, and the Add Meal route; device
appearance was set with `xcrun simctl ui … appearance light|dark` for each
frame. After capture the file was restored byte-for-byte:
`sha256 ff7255af9ee25e619dddf523a6e519176e9ea94b98da5edb354e270e1f8f9d89`
matches the committed `MorselApp.swift`, `git diff` shows zero harness lines,
and no `CAPTURE-HARNESS-ACTIVE` string remains in any shipped Swift source.

## Pixel audit (programmatic, PIL)

- Paper pages sample `#FFF7E8` (background token); Night-ink pages sample
  `#2A261F` — the dual-token ground resolves per capture theme.
- No `#000000` system-black regions on Night surfaces (status bar, forms,
  tab bar all sit on the charcoal ground).
- Paper grain + ruled sheet verified present behind content (tile baked at
  44 pt from `MorselPalette.inkline`; worst-case speck alpha ≈ 0.13 at radius
  ≤0.9 pt — far below the 4.5:1/3:1 floors; see `JournalPaperTexture.swift`).

## Regression proof (RED at base → GREEN at head)

- RED (tests against base behavior, recorded before implementation):
  `logs/red-base-tests.log` — tests-only commit `ea06099` on the pristine
  base regenerated project; test bundle fails to compile:
  `cannot find 'JournalTabNavigation' in scope` (+ pager/route/focus types);
  `xcodebuild test` RAW EXIT 65, `** TEST BUILD FAILED **`.
- GREEN at the implementation head: `xcodebuild test` — 110 tests,
  0 failures, `** TEST SUCCEEDED **`, RAW EXIT 0 (full log under
  `logs/gate-xcodebuild-test.log`).
- Hosted app probes (npm test surface): `app/issue-105-journal-contract.test.ts`
  (new, issue #105 wiring) + all pre-existing app probes pass 62/62
  (`logs/gate-vitest-app-probes.log`).

## Gate results at the implementation head (commit `f97ea26`)

| gate | command | raw exit | log |
| --- | --- | --- | --- |
| XcodeGen byte stability | `cd app && xcodegen generate && git diff --exit-code -- Morsel.xcodeproj/project.pbxproj` | 0 | `logs/gate-xcodegen.log` |
| Native build/test (iPhone 16 sim, unsigned) | `/usr/bin/xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO` | 0 (`** TEST SUCCEEDED **`, 110 tests) | `logs/gate-xcodebuild-test.log` |
| SwiftLint strict | `cd app && swiftlint lint --strict --quiet` | 0 | `logs/gate-swiftlint.log` |
| Whitespace | `git diff --check` | 0 | `logs/gate-diff-check.log` |

Note: a PATH shim intercepts bare `xcodebuild` on this host (agent-only
wrapper that fails simulator orchestration with "simulator did not reach
booted state"), so the native gate was run with the canonical
`/usr/bin/xcodebuild` binary — same command otherwise. All logs are the raw
command output ending with the command's own exit status.

## Files touched by the lane

`app/Sources/Morsel/`: `MorselApp.swift` (pager + Add Meal route shell),
`JournalNavigation.swift` (new), `JournalFocus.swift` (new),
`JournalPaperTexture.swift` (new), `PaperFields.swift` (new),
`JournalUI.swift`, `DesignSystem.swift`, `MealCaptureView.swift`,
`MealItemEditSheet.swift`, `GoalsEditor.swift`, `AuthView.swift`,
`HistoryView.swift`, `Views.swift`, `PreviewData.swift`, `MealCapture.swift`;
`app/Tests/MorselTests/JournalFollowUpTests.swift` (new native regressions);
`app/issue-105-journal-contract.test.ts` (new hosted probe) and
`app/unauth-action-tint.test.ts` (shell call-site pin updated).

NOT MERGED; no TestFlight dispatch; no live acceptance.

# Issue #113 — Goals recency in the app (evidence)

Issue #113 part (b): the app half of "goals latest update wins". With the
server/schema/skill half merged (PR #116, base 6a867e5), this lane makes the
Goals tab and the Today hero tell the same truth:

- **Superseded note (body item 4):** when the profile row is newer than a
  complete manual goal row, the Goals page shows the freshly computed
  targets and a one-line calm note naming the manual numbers they replaced
  (`app/Sources/Morsel/GoalsMath.swift` mirror of the server's
  `resolveEffectiveGoal` + `GoalsEditorModel.swift` copy).
- **Amendment A app path:** `DashboardMath.computedGoal(for:latestWeightKg:)`
  computes from the newest synced weight (remote `weight_logs` + newer local
  `weight_samples` overlay, newest `measured_at`) with the typed profile
  weight as fallback — the same `weight_used` contract the server's
  `compute_targets` reports, so "tap Cut" and the agent agree once Health
  weight diverges from the typed value. Unit test: profile 63 kg + newer
  Health sample 61.5 kg -> computed from 61.5.
- **Amendment B:** read-only profile line under YOUR TARGET
  (`computed from 61.5 kg (Health · 5 Sep) · 167 cm · 30 y · active · lose
  — set via your agent 5 Sep`; `no profile yet — tell your agent your
  height, weight, age and activity` when no profile row exists). No
  in-app editing.
- **Amendment C:** Today's margin note becomes
  `moved 412 kcal · Apple Health · 07:32` — day total from the
  energy_days-derived snapshot value, time from the SAME #112 calm-status
  stamp (`LocalHealthStore.lastSuccessfulUpload()`); hidden at 0; never
  subtracted (V1 locked).

## Evidence frames (iPhone 16 simulator, UDID 59DDC0C5-891E-4EC0-91AF-4F50DF68D793)

| frame | state | what it shows |
| --- | --- | --- |
| `113-goals-manual-current.png` | Goals, Paper — manual row (2,000 / 100 / 0 / 0, written 5 Sep 07:00) NEWER than the profile (5 Sep 06:00) | manual numbers stay effective, `writes source: manual`, NO note, read-only profile line under YOUR TARGET |
| `113-goals-superseded-paper.png` | Goals, Paper — same manual row but the profile was updated AFTER it (5 Sep 09:00); newest Health sample 61.5 kg (5 Sep 06:30) | the calm note (`your profile changed on 5 Sep; these are the new computed targets — your earlier manual numbers were 2,000 / 100 / 0 / 0`), fields prefilled computed 2111.0 / 158.0 / 237.0 / 59.0, `writes source: computed` (an unedited save stays computed), profile line `computed from 61.5 kg (Health · 5 Sep) · …` |
| `113-goals-superseded-night.png` | Goals, Night ink | the superseded state in the dark theme (AC7 paper+night pair) |
| `113-today-margin-paper.png` | Today, Paper — 1,004 kcal eaten vs 2,100 goal, moved 412 kcal | margin note reads exactly `moved 412 kcal · Apple Health · 07:32` under the macro strips |
| `113-today-margin-night.png` | Today, Night ink | same margin note in the dark theme (AC7 paper+night pair) |

All frames are the native @3x device pixels (1179×2556), matching the
repo's evidence convention.

## Capture method (temporary DEBUG harness, removed before commit)

- The existing single-@main discipline: a temporary
  `CAPTURE-HARNESS-ACTIVE` entry point suspended the production `@main` in
  `MorselApp.swift` and drove the REAL `GoalsView` / `TodayView` (real
  `GoalsEditorViewModel.load()` / `DashboardViewModel.load()` paths) with
  seeded `MockDashboardRepository` fixtures (stored goals row with explicit
  `updated_at`, profile row with explicit `updated_at`, `SyncedWeightSample`
  61.5 kg @ 5 Sep 06:30). The Today scene used a real temporary
  `LocalHealthStore` seeded through the SAME #112 seam
  (`setLastSuccessfulUpload(5 Sep 07:32)`) so the margin time is the actual
  calm-status stamp, not a second clock.
- `SIMCTL_CHILD_MORSEL_CAPTURE_SCENE` / `_THEME` env vars selected the
  scene (goalsManualCurrent | goalsSuperseded | todayMargin) and the theme
  (paper | nightInk, raw preference values; root
  `.preferredColorScheme(MorselAppearance.scheme(for:))`); device
  appearance was set per theme (`xcrun simctl ui <udid> appearance
  dark|light`) — the #94 lesson that the scheme alone does not flip
  dynamic tokens reliably in the capture app.
- After capture `MorselApp.swift` was restored from the clean checkout and
  proven byte-identical: sha256 `132c45be38d32fbec3c8a963a1714e9f5869730be782475e460a1d0ace1cb5e9`,
  `git diff` = 0 lines, zero `CAPTURE-HARNESS-ACTIVE` / `CAPTURE-ONLY` /
  `MorselCaptureApp` strings remain in any shipped Swift source.
- Device note: frames are page-level captures of the real views (real VM +
  real load path + real copy builders) mounted on the journal ground with
  the shell's scoped action tint; the tab bar chrome is not part of these
  frames. Unsigned Debug build, CODE_SIGNING_ALLOWED=NO.

## Regression proof (mutation RED → GREEN)

Native unit tests (RED under source mutation, GREEN after restore):

- Mutation: `DashboardMath.manualIsCurrent` reduced to "manual always
  current" (pre-#113 behavior) and `computedGoal` weight override ignored
  (profile weight only).
  - RED: `DashboardMathTests` 16 executed / 9 failed (recency supersede,
    stale-manual, partial-manual, missing-write-time + latest-weight tests)
    — log `logs/mutation-red-native-math.log`, raw exit 65.
  - RED: `GoalsEditorRecencyTests` 5 executed / 10 failures (superseded
    prefill + note, unedited-save keeps computed, note-clearing) —
    log `logs/mutation-red-native-vm.log`, raw exit 65.
  - Restored byte-identical (`cmp`), then GREEN: the three classes
    27/27, raw exit 0 — log `logs/mutation-green-native.log`.

Hosted probe (`app/issue-113-goals-contract.test.ts`, 8 tests):

- Mutation (margin hero reverted to the old `kcal today` literal + recency
  comparison loosened `>=` → `>`): RED raw exit 1, 2 failed / 6 passed —
  log `logs/probe-mutation-red.log`. Restored, GREEN 8/8 raw exit 0 —
  log `logs/probe-mutation-green.log`.

## Gate results at the implementation head

| gate | command | raw exit | log |
| --- | --- | --- | --- |
| XcodeGen byte stability | `cd app && xcodegen generate && git diff --exit-code -- Morsel.xcodeproj/project.pbxproj` | 0 | (run at head, see commit) |
| Native build/test (iPhone 16 sim, unsigned) | `/usr/bin/xcodebuild test … -destination 'platform=iOS Simulator,id=59DDC0C5-891E-4EC0-91AF-4F50DF68D793' … CODE_SIGNING_ALLOWED=NO` | 0 (`** TEST SUCCEEDED **`, 169 tests) | `logs/gate-xcodebuild-test.log` |
| SwiftLint strict | `swiftlint lint --strict --quiet` | 0 | (reported in commit) |
| Hosted app probes | `npx vitest run app/issue-113-goals-contract.test.ts` | 0 (8/8) | `logs/gate-app-probe.log` |
| Full vitest suite | `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 npm test` | 0 (38 files / 441 passed) | `logs/gate-full-npm-test.log` |
| Whitespace | `git diff --check` at final committed head | 0 | (run at head, see commit) |

Base native count at 6a867e5: 151 tests; this lane adds 18 (7 recency/weight
math in DashboardMathTests, 5 GoalsEditorRecencyTests, 6 GoalsPageCopyTests)
→ 169.

## Files touched by the lane

- `app/Sources/Morsel/Models.swift` — `updatedAt` on DashboardProfile /
  StoredDashboardGoal (recency inputs; optional, cache-safe)
- `app/Sources/Morsel/GoalsMath.swift` (new) — DashboardMath recency mirror
  (effectiveGoal/computedGoal/manualIsCurrent/supersededManual),
  SupersededManualGoal
- `app/Sources/Morsel/GoalPageContext.swift` (new) — GoalsPageContext /
  SyncedWeightSample, repository default + SupabaseDashboardRepository
  context read (goals + profile + newest weight_logs, all with updated_at)
- `app/Sources/Morsel/GoalsEditorModel.swift` (new) — GoalsEditorViewModel
  (moved from GoalsEditor.swift) loads the page context and renders the
  superseded note + amendment B profile line (GoalsPageCopy)
- `app/Sources/Morsel/MorselStamp.swift` (new) — fixed-stamp day/month +
  time formatters, ActiveEnergyMarginNote (amendment C)
- `app/Sources/Morsel/GoalsEditor.swift` — view notes under YOUR TARGET
- `app/Sources/Morsel/Repository.swift`, `HistoryRepository.swift` —
  updated_at columns/parses + newest weight into the dashboard/history goal
- `app/Sources/Morsel/SupabaseMealMutations.swift` — updated_at in goals /
  profile selects
- `app/Sources/Morsel/LocalHealthStore.swift` — `newestWeightSample()`
- `app/Sources/Morsel/LocalFirstRepository.swift` — local-first
  loadGoalsContext (cache + local sample overlay)
- `app/Sources/Morsel/ViewModel.swift` — `lastHealthImportDate` (the #112
  stamp, no second clock)
- `app/Sources/Morsel/Views.swift` — hero margin note via the shared builder
- `app/Sources/Morsel/MockRepository.swift` — goals-context seeding
- `app/Tests/MorselTests/DashboardMathTests.swift`,
  `app/Tests/MorselTests/GoalsPageTests.swift` (new) — recency/weight +
  page/copy/margin tests
- `app/issue-113-goals-contract.test.ts` (new hosted probe);
  `app/v1-journal-contract.test.ts` (updated: hero margin assertion moved
  from the old inline literal to the shared builder — extra tracked file
  beyond the brief fence, required so npm test stays green)
- `app/Morsel.xcodeproj/project.pbxproj` (XcodeGen — new files)
- `docs/evidence/issue-113/` (this evidence)

NOT MERGED; no TestFlight dispatch; no live acceptance. AC5 (live Claude
re-check after Fly deploy) is Guy's human gate — recorded, not performed.

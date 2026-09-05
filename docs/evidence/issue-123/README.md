# Issue #123 — Goals page polish (evidence)

Issue #123 (app lane after #125): two polish defects on the Goals page, both
visible on every open:

1. **Empty-then-filled flash.** `GoalsEditorViewModel` started with
   `calories/protein/carbs/fat = ""` and `fieldError` treated "" as invalid;
   `load()` was remote-first, so a moment after opening Goals all four
   fields were empty, `source: —`, and each showed the red
   "Enter a number of 0 or more." error before the real values painted.
2. **No direction shown as selected.** `selectedDirection` was tap-only
   (`nil` until a chip tap), so Cut/Maintain/Bulk rendered identically on
   open even though the profile said `lose`.

## Fix (app-only)

- **Local-first first paint** (`GoalsEditorModel.swift load()`): the cached
  stored goals row (new `DashboardRepository.cachedGoals`, implemented by
  `LocalFirstDashboardRepository` over the SQLite goals cache) paints
  immediately — `load()` applies the cached row BEFORE the remote refresh,
  then reconciles from `loadToday` + `loadGoalsContext`. Plain remote
  repositories keep a nil default. While the very first load is in flight
  with no cache, `isAwaitingFirstGoal` (`isLoading && goal == nil`) swaps
  the target block for a calm `ProgressView` + "Opening your goals…" row
  (`GoalsEditor.swift`) instead of empty inputs.
- **Validation only after edit**: `fieldError` returns nil for an EMPTY
  field the user has never edited (`editedFields` set in `edit()`); an
  edited-empty or invalid value still errors, and `isValid` is unchanged
  (Save stays disabled for empty fields).
- **Direction derived, not tap-only**: `GoalDirection(profileDietGoal:)`
  maps lose→cut / maintain→maintain / gain→bulk. `apply(context)` sets a new
  `profileDirection` from the profile row and fills `selectedDirection`
  only when the EFFECTIVE goal is computed. A current manual goal fills no
  chip (its numbers are typed, not chosen) and the profile's phase renders
  as the lighter "profile" hint chip (`profileDirection`, drawn at
  `morselForest.opacity(0.45)` with no fill); no profile row → no chips.
  The #113 superseded-manual note and the read-only Profile line are
  untouched.

## Simulator evidence frames (iPhone 16, UDID 59DDC0C5-891E-4EC0-91AF-4F50DF68D793, unsigned Debug, CODE_SIGNING_ALLOWED=NO, native @3x 1179×2556)

| frame | scene | what it shows |
| --- | --- | --- |
| `123-goals-open-paper.png` | Goals, Paper — lose profile, load completed | the Cut chip is FILLED (derived from the `lose` profile diet goal), fields show the computed targets 2111.0 / 158.0 / 237.0 / 59.0 (computed from the 61.5 kg Health sample), `writes source: computed`, read-only profile line `computed from 61.5 kg (Health · 5 Sep) · 167 cm · 30 y · active · lose — set via your agent 5 Sep`, NO red errors |
| `123-goals-open-night.png` | Goals, Night ink — same lose profile | same state in the dark theme; the Cut chip's filled selection is visibly lighter than the two plain chips |
| `123-goals-first-paint-paper.png` | Goals, Paper — CACHED row present, remote frozen in flight (never resolves) | the FIRST frame shows the cached goal 2126.0 / 159.0 / 239.0 / 59.0 (`source: computed`) while the remote round-trip is still pending — never empty fields, never red errors. Chips are unfilled in this frame because the goals cache carries no profile row (the profile + filled chip arrive with the remote context — next frame) |
| `123-goals-first-paint-night.png` | same first-paint scene, Night ink | dark-theme twin of the frozen first paint |
| `123-goals-loading-paper.png` | Goals, Paper — NO cache, remote frozen in flight | the calm loading state (`Opening your goals…` + accent spinner) replaces the empty inputs; no red errors, no empty field rows |
| `123-goals-loading-night.png` | same loading scene, Night ink | dark-theme twin of the calm loading state |

Pixel check for the filled chip (PIL, band y 1200–1360 @3x, per-column mean
RGB, Cut vs Maintain column): paper 36–45 sum-difference, night 43–48 —
the Cut chip's `morselForest` 14% fill is present and distinct in BOTH
themes; Maintain/Bulk have no fill.

SHA-256 (evidence images):

```
1c60f9bd02791f37a9e2f9d6c1c477227c5f9a372ee9422cdcd0da7cbeaebde8  123-goals-first-paint-night.png
2ea742ba717dd2f8608c2f19ff2ab3abca923bf13c44ae7ee93649a4eb96a6da  123-goals-first-paint-paper.png
acfdb85f594d9852b36f076944d9290f6bf97b7cde91425f99dd073e964616fd  123-goals-loading-night.png
458bca6403e23011148a0e0389c80f8348d1f8114b3a9534b1c5fa4600fd8996  123-goals-loading-paper.png
ee9c2a3700e61b541374d77b440b8b747ff1bc2ee2ea6965ee4e149d1e5e7470  123-goals-open-night.png
7863c72074762b21e3d0e7f69ad75720e47b87bc4d93f9f1940c19748776b592  123-goals-open-paper.png
```

## Capture method (temporary DEBUG harness, removed before commit)

- The single-@main discipline: a temporary `CAPTURE-HARNESS-ACTIVE` entry
  point suspended the production `@main` in `MorselApp.swift` and drove the
  REAL `GoalsView` (real `GoalsEditorViewModel.load()` path) on the journal
  ground with the shell's scoped action tint; the tab-bar chrome is not part
  of these frames. `MORSEL_CAPTURE_SCENE` (`goalsOpen | goalsFirstPaint |
  goalsLoading`) and `MORSEL_CAPTURE_THEME` (`paper | nightInk`) selected
  the scene; device appearance was set per theme (`xcrun simctl ui <udid>
  appearance light|dark`) — the #94 lesson that the scheme alone does not
  flip dynamic tokens reliably in the capture app.
- `goalsOpen` seeds the REAL view-model path with a lose profile + stored
  computed row + newest Health sample (61.5 kg, 5 Sep 06:30) via the
  mock repository used by the Goals tests. `goalsFirstPaint` / `goalsLoading`
  run the REAL local-first stack (`LocalFirstDashboardRepository` over the
  SQLite snapshot cache) with a remote that never answers — the frame is
  frozen at the pre-reconcile first paint: cached values (seeded through the
  production `saveGoalsCache` seam) or the calm loading state when the
  cache is empty.
- After capture `MorselApp.swift` was restored from the clean checkout and
  proven byte-identical: sha256
  `132c45be38d32fbec3c8a963a1714e9f5869730be782475e460a1d0ace1cb5e9`,
  `git diff` = 0 lines, zero `CAPTURE-HARNESS-ACTIVE` / `GoalsCapture` /
  `MORSEL_CAPTURE` strings remain in any shipped Swift source, and
  `xcodegen generate` leaves the tracked pbxproj byte-unchanged.

## RED / GREEN / mutation proof (raw exits, named logs in /tmp)

- **RED at pristine base `c512b0f`**: scratch worktree
  (`git worktree add --detach /tmp/morsel-123-red-base c512b0f`) + ONLY the
  new `GoalsPolishTests.swift` copied over (it compiles against the base —
  it uses no post-#123 API on purpose). `xcodebuild test -only-testing:
  MorselTests/GoalsPolishTests` → **TEST FAILED, raw exit 65, 5 tests with
  29 failures** — log `/tmp/123-red-base.log`. Failing assertions show the
  base defect exactly: fields stay `""` while the remote is in flight and
  `fieldError("")` returns "Enter a number of 0 or more.", `selectedDirection`
  stays nil after load.
- **GREEN at head**: the two new classes + all existing Goals classes
  (GoalsEditorTests, GoalsEditorPrecisionTests, GoalsEditorRecencyTests,
  GoalsPageCopyTests) → 41/41 raw exit 0 — log `/tmp/123-targeted-head2.log`.
  Full native suite at head: **180 tests, 0 failures, raw exit 0** — log
  `/tmp/123-gate-full-xcodebuild.log`.
- **Mutation RED (head)** — `GoalsPolishTests`/`GoalsDirectionProfileTests`
  bite the new code:
  - Mutation A (cached-goal paint removed from `load()`): 1 test / 5
    assertion failures, raw exit 65 — log `/tmp/123-mutationA-red.log`.
  - Mutation B (profileDirection + derived-chip block removed from
    `apply(context)`): 8 failures across the direction tests (11 executed),
    raw exit 65 — log `/tmp/123-mutationB-red.log`.
  - Restored byte-identical (`cmp` against the pre-mutation copy), then
    GREEN: 11/11 raw exit 0 — log `/tmp/123-mutation-green.log`.
- The manual-goal "documented behavior" tests
  (`GoalsDirectionProfileTests`, pinning the new `profileDirection` surface)
  are head-only by construction; their discrimination is proven by mutation
  B above.

## Gate results at the implementation head

| gate | command | raw exit | log |
| --- | --- | --- | --- |
| XcodeGen byte stability | `cd app && xcodegen generate` (pbxproj `git diff` = the committed 8-line test-file addition only) | 0 | — |
| SwiftLint strict | `cd app && swiftlint lint --strict --quiet` | 0 | — |
| Native build/test (iPhone 16 sim, unsigned) | `herdr-xcodebuild test … CODE_SIGNING_ALLOWED=NO` (DIRECT) | 0 — 180 tests, 0 failures, `** TEST SUCCEEDED **` | `/tmp/123-gate-full-xcodebuild.log` |
| Whitespace | `git diff --check` at final committed head | 0 | — |
| Hosted app probes | `npx vitest run app/*.test.ts` (12 files, incl. new `issue-123-goals-polish-contract.test.ts` 8/8) | 0 — 90/90 | — |
| Repo lint | `npm run lint` | 0 | — |
| Hosted CI | PR (orchestrator opens it) | pending | — |

Base native count at 585730b: 169 tests; this lane adds 11 (5
`GoalsPolishTests` + 6 `GoalsDirectionProfileTests`) → 180.

## Files touched by the lane

- `app/Sources/Morsel/GoalsEditorModel.swift` — cache-first `load()`,
  `editedFields` guard in `fieldError`, `profileDirection`, derived
  `selectedDirection` in `apply(context)`, `isAwaitingFirstGoal`
- `app/Sources/Morsel/GoalsEditor.swift` — `GoalDirection(profileDietGoal:)`,
  calm loading row, filled-vs-lighter-profile chip styling
- `app/Sources/Morsel/LocalFirstRepository.swift` — `cachedGoals`
  (same-file extension; class body stays under the 250-line lint budget)
- `app/Sources/Morsel/GoalPageContext.swift` — protocol default `cachedGoals`
  (nil) for plain remotes
- `app/Sources/Morsel/Repository.swift` — `cachedGoals` protocol requirement
- `app/Tests/MorselTests/GoalsPolishTests.swift` (new) — base-RED set:
  local-first paint via the REAL LocalFirst + SQLite cache with a delayed
  remote, validation-after-edit, computed direction mapping
- `app/Tests/MorselTests/GoalsDirectionProfileTests.swift` (new) — manual
  goal documented behavior (profileDirection hint, no filled chip, no
  profile → nothing), superseded-manual derived fill
- `app/issue-123-goals-polish-contract.test.ts` (new hosted probe) — source
  contract so hosted npm test bites the Swift edits
- `app/Morsel.xcodeproj/project.pbxproj` (XcodeGen — the two new test files)
- `docs/evidence/issue-123/` (this evidence)

Scope fence respected: no `server/**`, `db/**`, `skills/**`,
`packages/schema/**`, docs outside evidence, or release tooling. Refs #123.

NOT MERGED; no TestFlight dispatch; no live acceptance. AC4 (Guy's next
TestFlight device check) is the human gate — recorded, not performed.

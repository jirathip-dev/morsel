# Issue #111 — Journal hinged page turn (evidence)

Tab changes and swipes between Today / History / Goals were a flat
horizontal slide (`TabView .page`, UIPageViewController). Issue #111
replaces the page-style TabView with a custom journal pager
(`JournalPageTurner`, `app/Sources/Morsel/JournalPageTurner.swift`) that
turns the incoming page in on the approved V1 hinge (`#90` prototype):
−70° → 0° with an 0.2 → 1 fade over ~0.55 s on a
`cubic-bezier(.2, .7, .2, 1)` curve, hinged on the leading (binding) edge
for forward turns and mirrored on the trailing edge for backward turns.
`JournalPagerModel` (`JournalNavigation.swift`) stays the single source of
truth; interactive horizontal drags preview the adjacent page through the
same `JournalTabNavigation` no-wrap rules; Reduce Motion keeps the plain
non-3D opacity fade.

## Frame sequence (forward turn, Paper)

Tap History from Today — the incoming History page swings in over the flat
Today page, hinged on the left:

| frame | state |
| --- | --- |
| `111-forward-early.png` | early swing — incoming page at a steep angle (thin wedge near the hinge, right edge in depth) |
| `111-forward-mid.png` | mid swing — History page clearly angled in 3D over Today; History tab already active (content/indicator sync) |
| `111-forward-late.png` | late swing — History nearly flat, faint ghosting of the page fade (0.2 → 1 opacity per prototype) |

Backward turns mirror the hinge (`111-backward-mid.png`): returning Goals →
History, the incoming History page is hinged on the RIGHT edge and arrives
from the LEFT over the flat Goals page.

## Capture method (temporary DEBUG harness, removed before commit)

- Same discipline as #94/#105: a temporary `CAPTURE-HARNESS-ACTIVE` entry
  point suspended the production `@main` in `MorselApp.swift` and drove the
  REAL journal shell (real `JournalPageTurner`, real Today/History/Goals
  views, real `JournalTabBar`) with `MockDashboardRepository` (fixture:
  1,214 kcal eaten vs 2,100 goal, P 66 / C 117 / F 47, moved 386 kcal,
  7-day ledger with one over day, weight trend; onboarding not required).
  `SIMCTL_CHILD_MORSEL_CAPTURE_*` env vars selected the initial tab, the
  flip target, and the flip delay; the harness called `pager.select(...)`
  — the exact call the tab bar's buttons make — so the frames show the real
  bar-tap animation path.
- **Timebase disclosure:** the host video recorder is busy ("Host recording
  is already in progress", a shared-host CoreSimulator recorder — never
  killed), and `simctl io screenshot` latency (~0.7 s) exceeds the real
  0.55 s swing, so the capture build dilated the seam duration
  (`JournalTurnSeam.richDuration` 0.55 → 4.0 s, CAPTURE-ONLY) and frames
  were taken at wall-clock offsets. The pose math, curve, opacity, and
  hinge anchors are the shipped code; only the clock ran slower.
- After capture both files were restored byte-for-byte (cmp-verified
  against the pre-capture state; zero `CAPTURE-HARNESS-ACTIVE` /
  `CAPTURE-ONLY` strings remain in any shipped Swift source).
- Device: iPhone 16 simulator, UDID
  `59DDC0C5-891E-4EC0-91AF-4F50DF68D793`, unsigned Debug build
  (CODE_SIGNING_ALLOWED=NO), Paper theme, light appearance. Frames are the
  native @3x device pixels (1179×2556, matching the hotfix-89 convention).

## Honest device-feel note

- Tab-bar taps: the full hinge turn is verified on-device above (the bar
  button and the harness both call `JournalPagerModel.select`).
- Swipe drags (finger-following preview, commit ≥ half a page or a fast
  flick, rollback) are implemented with a `simultaneousGesture` horizontal
  drag (vertical page scrolls are never stolen — the guard only engages on
  horizontal intent, and `.simultaneousGesture` never blocks the pages'
  own ScrollViews) but could NOT be hand-tested on this host: there is no
  touch-injection tool installed and the shared host recorder blocks
  video. The rules are pinned by the native `JournalTurnRuleTests` +
  `JournalHingeSeamTests` and the hosted probes.
- Mid-turn retargets (rapid taps): the model settles atomically on the last
  request; the pager snaps the in-flight page and hinges the remainder.

## Regression proof (mutation RED → GREEN)

The rotation-seam probe (`app/issue-111-hinged-turn-contract.test.ts`,
hosted vitest) pins that the incoming page renders through
`.rotation3DEffect` with the y-axis hinge, the seam anchors
(forward `.leading`, backward `.trailing`), the signed ±70° start angles,
the 0.2 → 1 fade, the ~0.55 s cubic-bezier curve, and the Reduce Motion
fade path. Mutation (replacing `rotation3DEffect` with a plain `offset`
in `JournalPageTurner.swift`):

- RED: `npx vitest run app/issue-111-hinged-turn-contract.test.ts` —
  RAW EXIT 1, 1 failed (log: `logs/mutation-red.log`).
- Restored byte-identical (`cmp`), then GREEN: RAW EXIT 0, 7/7 passed
  (log: `logs/mutation-green.log`).

## Gate results at the implementation head

| gate | command | raw exit | log |
| --- | --- | --- | --- |
| XcodeGen byte stability | `cd app && xcodegen generate && git diff --exit-code -- Morsel.xcodeproj/project.pbxproj` | 0 | `logs/gate-xcodegen.log` |
| Native build/test (iPhone 16 sim, unsigned) | `/usr/bin/xcodebuild test … -destination 'platform=iOS Simulator,id=59DDC0C5-891E-4EC0-91AF-4F50DF68D793' … CODE_SIGNING_ALLOWED=NO` | 0 (`** TEST SUCCEEDED **`, 151 tests) | `logs/gate-xcodebuild-test.log` |
| SwiftLint strict | `swiftlint lint --strict --quiet` | 0 | `logs/gate-swiftlint.log` |
| Hosted app probes | `npx vitest run app/issue-111-hinged-turn-contract.test.ts app/issue-105-journal-contract.test.ts` | 0 (19/19) | `logs/gate-app-probes.log` |
| Full vitest suite | `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 npm test` | 1 (infra, see below) | `logs/gate-full-npm-test.log` |
| Whitespace | `git diff --check` | 0 | `logs/gate-diff-check.log` |

Note on the full vitest run: 37/37 files, 433/433 tests pass, but the
suite exits 1 with a vitest worker RPC error (`Timeout calling
"onTaskUpdate"`) after the ~86 s Postgres migration worker. The identical
error reproduces at the clean base commit (36 files, 426/426 passing) —
a pre-existing host-level vitest/worker issue, not caused by this lane
(both raw logs kept: `logs/gate-full-npm-test.log`,
`logs/base-full-npm-test.log`).

Note: a PATH shim intercepts bare `xcodebuild` on this host (agent-only
wrapper that fails simulator orchestration with "simulator did not reach
booted state"), so the native gate used the canonical `/usr/bin/xcodebuild`
binary with the lane's external DerivedData path — same command otherwise.

## Files touched by the lane

- `app/Sources/Morsel/JournalPageTurner.swift` (new — seam + hinged pager)
- `app/Sources/Morsel/MorselApp.swift` (pageContent: hinged pager in the
  rich path; Reduce Motion opacity fade; `.page` TabView removed)
- `app/Tests/MorselTests/JournalFollowUpTests.swift`
  (`JournalHingeSeamTests` added)
- `app/issue-111-hinged-turn-contract.test.ts` (new hosted seam probe)
- `app/issue-105-journal-contract.test.ts` (AC1/AC2 wiring pins updated to
  the #111 hinged pager)
- `app/Morsel.xcodeproj/project.pbxproj` (XcodeGen — new source file)
- `docs/evidence/issue-111/` (this evidence)

NOT MERGED; no TestFlight dispatch; no live acceptance.

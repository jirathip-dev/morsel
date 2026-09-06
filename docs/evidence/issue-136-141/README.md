# Issue #136 + #141 — delete paper dialog, History freeze fix, skeleton loading, endpoint copy (evidence)

Issue #136 (app): (A) the delete confirmation rendered as the Apple system
alert — it is now a themed paper dialog/sheet; (B) History could freeze on
'Reading the ledger…' after rapid tab switching — the ledger read path now
supersedes cancelled/stuck reads; (C) spinner-based loading on Today/History
was replaced with paper skeletons. Issue #141 (app): the onboarding connect
screen's MCP endpoint field gained a paper 'Copy' pill that copies ONLY the
endpoint URL.

## What changed (files)

- `app/Sources/Morsel/Views.swift` — Today's `.confirmationDialog` →
  `.sheet(item: $mealToDelete)` presenting `DeleteMealPaperDialog`
  (cream `morselSurface` card, ink copy, ghost Cancel, red-flagged
  `MorselDestructiveButtonStyle` on the `over` token, presentation detent +
  hidden drag indicator). `LoadingNotice` spinner → `TodaySkeleton`
  (journal-rhythm placeholder blocks) + shared `PaperSkeletonBlock` /
  `PaperSkeletonFill` primitives.
- `app/Sources/Morsel/TodayLogViews.swift` — `TodayLogSkeletonRows` (log-row
  placeholders feeding Today's first-load skeleton).
- `app/Sources/Morsel/HistoryView.swift` — `HistoryViewModel.load()` /
  `select()` now supersede in-flight reads by generation (the freeze root
  cause: the old `guard !isLoading` let a cancelled read that never surfaced
  `CancellationError` gate every newer load forever). `HistoryLedgerSkeleton`
  + `DayDrillDownSkeleton` replace the spinners.
- `app/Sources/Morsel/HistoryLedgerViews.swift` — DayDrillDown 'Opening the
  day…' spinner → `DayDrillDownSkeleton()`.
- `app/Sources/Morsel/Onboarding.swift` — endpoint field trailing 'Copy'
  pill (forest/inkline/surface tokens), 1.5 s 'Copied ✓' flip via
  `.task(id:)`; `OnboardingContent.copyToPasteboard` publishes the trimmed
  endpoint only. 'Copy setup prompt' untouched. File re-compacted to stay
  inside the 400-line lint budget (no copy changed).
- `app/Morsel.xcodeproj/project.pbxproj` — XcodeGen: the three new test
  files.
- `app/Tests/MorselTests/HistoryFreezeRegressionTests.swift` (new) — gated
  repository whose first read blocks on a raw continuation (ignores task
  cancellation, like a non-cooperative local/SQLite read); 4 tests drive the
  reported race RED at base / GREEN at head.
- `app/Tests/MorselTests/PaperDeleteAndSkeletonTests.swift` (new) — source
  contracts: no `.confirmationDialog`/`ProgressView`/freeze text remains on
  the Today/History surfaces; paper tokens on dialog + skeletons.
- `app/Tests/MorselTests/EndpointCopyTests.swift` (new) — pasteboard copy of
  exactly `https://mcp.morselfood.app/mcp` (trimmed, no newline) + paper
  token/source wiring pins.

## Simulator evidence frames

iPhone 16 (UDID 9FA5292B-D558-4951-93D3-460080205D4B, dedicated lane
simulator), unsigned Debug, CODE_SIGNING_ALLOWED=NO, native @3x 1179×2556.
Temporary CAPTURE-HARNESS-ACTIVE entry point (removed before commit;
MorselApp.swift restored byte-identical — sha256
`8f17d3ae31b0d221c0b88e9d8831a319007c43b25bc3a61f70023549d471ee4f` matches
the clean HEAD, `git diff` = 0 lines, no `CAPTURE-HARNESS-ACTIVE` /
`CaptureHarness136141` / `MORSEL_CAPTURE_SCENE` strings remain, `xcodegen
generate` leaves the tracked pbxproj byte-unchanged beyond the committed
12-line test-file addition).

| frame | scene | what it shows |
| --- | --- | --- |
| `136-delete-paper.png` | Today (Paper) + real `DeleteMealPaperDialog` over the real TodayView mock-seeded log | cream paper dialog card: "Delete this meal? / This removes 2 items and recalculates today's totals.", ghost `Cancel` + red-flagged `Delete Lunch` (over token #9C3A2F fill, ~1.03% frame pixels), over the dimmed real journal (hero, macros, Breakfast/Lunch rows) — no system alert chrome |
| `136-delete-night.png` | same scene, Night ink | dark charcoal sheet + warm dark card; destructive surface resolves to the night cream pair (#FFF7E8, ~1.18% frame pixels) with ink label; Cancel charcoal ghost |
| `136-today-skeleton-paper.png` | Today first load, real TodayView over a never-answering repository | paper skeleton: ring block + title bars + three macro fills + rule + log-row thumbnails/blocks; no `ProgressView`, no spinner text |
| `136-today-skeleton-night.png` | same scene, Night ink | dark-theme twin |
| `136-history-skeleton-paper.png` | History first load, real HistoryView over a frozen remote | ledger skeleton: two range-pill blocks + five bar rows; no spinner, no 'Reading the ledger…' |
| `136-history-skeleton-night.png` | same scene, Night ink | dark-theme twin |

Pixel audit (PIL, resized @3x): 0.0% cool-hue pixels in every frame (no
system-blue anywhere); delete dialog shows the over-red destructive fill in
Paper and its resolved cream pair in Night; dominant colors = warm paper
cream vs dark charcoal per theme. Simulator shots are @3x device pixels
(1179×2556), repo convention.

SHA-256:

```
113d942b9a639e135549909b370495d8374230069da80f673b47915ae88a831a  136-delete-night.png
16bc484773c92f285416e3600a04d1fa4ad5eb9a13f052b0ab1adf77b16698db  136-delete-paper.png
ecdc0f8b5ba891a22d1e42320268f5c75e2c5deecd3478c1dc58ed824af63e7d  136-history-skeleton-night.png
3f97b879d7e9356458d6dbce26dfd357e0e37f1d961c5eed533d093433e19cd6  136-history-skeleton-paper.png
33a9e69c5b42a97101815a42cd6427aab87c176c0feae06eb1b000bb98985af3  136-today-skeleton-night.png
8a38a318f1d51cd0aa4a70bc08358147d61f6a42925a7ef3d2ce9f5897ec0e6a  136-today-skeleton-paper.png
```

Capture disclosure: TodayView's delete-request state (`mealToDelete`) is
private `@State` and not injectable from a harness, so the harness drove the
sheet presentation (`presentDelete`) and passed the real seeded `MealRecord`
to the REAL `DeleteMealPaperDialog` over the REAL TodayView content — all
dialog chrome, tokens, text, and meal rows are production views. The
delete-dialog AC's "SwiftUI interaction test" half is the native source +
state wiring tests in `PaperDeleteAndSkeletonTests` and the interaction
behavior covered by `HistoryFreezeRegressionTests`/`MealCorrectionsTests`
(deleteMeal path) — this lane has no XCUITest/UI-test target (repo
convention), and #141's connect-screen copy pill is covered by unit +
interaction-source tests with the human remainder on Guy's TestFlight device
(issue AC4).

## RED / GREEN proof (freeze regression; raw exits, named logs in /tmp)

- RED at pristine base `c262549`: scratch detached worktree
  (`/tmp/morsel-136-141-red-base`, removed after) with ONLY
  `HistoryFreezeRegressionTests.swift` copied over, `xcodegen generate`,
  `xcodebuild test -only-testing:MorselTests/HistoryFreezeRegressionTests` →
  **raw exit 65 — 4 tests, 9 failures** — log `/tmp/xcodebuild-136141-red.log`.
  Failures show the reported defect exactly: loading stuck past 2 s, overview
  never published, the superseding read never ran (`historyCallCount` 1), a
  stale day read overwrote the newer selection, collapse left loading on.
- GREEN at head: the same four tests (with the full new-test set) →
  **raw exit 0 — 15/15** — log `/tmp/xcodebuild-136141-focused3.log`.

## Gate results at the implementation head

| gate | command | raw exit | log |
| --- | --- | --- | --- |
| XcodeGen byte stability | `cd app && xcodegen generate` twice; pbxproj diff = committed 12-line test-file addition only | 0 | — |
| SwiftLint strict | `cd app && swiftlint lint --strict --quiet` | 0 | `/tmp/136141-final-lint.log` |
| Native test (full suite, dedicated sim) | `herdr-xcodebuild test … CODE_SIGNING_ALLOWED=NO` | 0 — 210 tests, 0 failures | `/tmp/xcodebuild-136141-full.log` |
| Hosted test suite | `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 npm test` | 0 — 43 files / 497 tests | `/tmp/136141-npmtest.log` |
| Typecheck | `npm run typecheck` | 0 | `/tmp/136141-typecheck.log` |
| Repo lint | `npm run lint` | 0 | `/tmp/136141-lint.log` |
| Build | `npm run build` | 0 | `/tmp/136141-build.log` |
| Whitespace | `git diff --check base..HEAD` | 0 | — |

Base native count at c262549: 195 tests; this lane adds 15 → 210.

NOT MERGED; no TestFlight dispatch; no live acceptance.

# Issue 263 half (b): native numeric voice

Implementation base: `05e6314f2ebd107149c5be22f2b09f003e697948` (post-#214).
Approval: OWNER DECISION — 2026-09-17 on #263, design `cfd5940`.

## Production change

`Font.morselNumber(size:weight:)` uses the existing registered EB Garamond
variable face, nominal weights 400/500, explicit tabular-number and lining-number
selectors, and the existing UIFontMetrics scaling convention. `morselValue` and
`morselValueMedium` are the 11-point diary readout/caption roles. All old mono
factories/tokens are intact: this is a call-site migration, not a global swap.
No strings, nominal sizes, layout constants, colors, food artwork or data policy
were changed. Inherited nontechnical captions follow the approved COVERAGE map.

`Views.swift` has exactly one font edit: the Eaten number changes from
`.font(.morselHero)` to `.font(.morselNumber(size: 32, weight: 500))`. Its existing
`.monospacedDigit()` stays. The current base labels this hero **Eaten**, not
**Eaten · Goal**: half (a) moved the target to its training row. That row and its
local `TrainingDayType` are byte-unchanged; no old denominator was reintroduced.

GoalsEditor and MenuEditorSheet need no direct edits: their existing numeric
field flags resolve through the changed JournalPaperField value-font branch.
Only numeric inputs change; ordinary body-font text fields stay unchanged.
The old training-row source test now pins the separately approved numeric hero
while still preserving the old mono token and the no-inferred-amount guard.

## E1: real native surfaces

`before/` and `after/` hold original XCTest PNG attachments, not HTML/prototype
renders. Each is 1179×2556 pixels: a scene-backed 393×852-point iPhone 16 window
at 3×, unsigned Debug, iOS Simulator 26.5. Each leg's run.json records the exact
command, simulator UUID, raw exit and duration. Each manifest records SHA-256,
pixel dimensions and the original xcresult attachment identifier. PNG bytes are
not color-converted or resized; exported UIKit captures carry Display P3 profiles.

Before production sources came from `git archive 05e6314...`, expanded under
`/tmp/morsel-263-base/issue-263-numeric`. All 91 production source files were
compared byte-for-byte with that commit. The ONLY overlay was the identical
`NumericVoiceCaptureTests.swift` driver; XcodeGen regenerated the project in the
same checkout basename. There is no after-font overlay in the before app.

The driver mounts production SwiftUI views in the real app-hosted test process,
using in-memory fictional repositories and the existing TrainingDayFixture.
It yields for view tasks, draws the scene-backed UIWindow, and attaches the PNG
synchronously to its named state. It also prints actual Vision OCR text; this
is not timed stdout-driven simctl capture. These are mounted native-view captures,
not physical taps, full authentication/navigation journeys, or a live account.

| Owner surface | Capture state(s), in both themes and both builds |
| --- | --- |
| Today hero, food-row kcal/portion/macros, Today log | today |
| Day drill-down including historical macro columns | day-drill-down |
| History numeric ledger and summary gauge | history-ledger-gauge |
| Weight-delta labels and receipt | weight-chart |
| Calendar day numbers and date range | calendar |
| Goals numeric fields and validation text | goals-filled, goals-invalid |
| Meal capture numeric inputs | meal-capture, meal-capture-bottom |
| Edit numeric inputs, confidence, photo illustration/provenance | meal-edit, meal-edit-bottom |
| Photo upload JPEG/KB metadata | photo-metadata |
| Shared menu numeric input | menu-editor |

Eleven top-level surfaces plus two scroll positions produce 13
frames per theme, 26 per build. The photo is a generated gray square (not a food
photograph); metadata comes from its actual encoded JPEG. Invalid goals are
intentionally negative fictional values so the production validation text paints.
No save/upload or camera/picker interaction is invoked. Menu/capture optional
fields deliberately stay blank rather than inventing nutrition.

Native visual inspection covered Today/ledger/calendar/weight, the Night forms,
and scrolled edit/capture plus drill-down. Small 9–11-point serif text is visibly
finer than Plex at unchanged sizes, as the approved design warns. No size or
weight compensation was slipped in. Native date-picker chrome remains system
UI; this simulator's date picker/calendar uses its Buddhist calendar preference.
Some page furniture uses the test-run date, not the fictional record date. Neither
is a new typography behavior. Scrolled frames intentionally move the page header
off the viewport to expose the lower fields and edit controls.

## E2: SwiftUI pixel alignment, not inferred font advances

`NumericVoiceTests.testSwiftUIRenderedDigitColumnsAtProductionSizes` uses the
production numeric font with SwiftUI Text. A naturally laid-out HStack puts a
2-point red rectangle immediately after each repeated-digit string. The test
renders through ImageRenderer at 3×, finds the first red pixel column, and checks
all ten digits at string lengths 1–5, sizes 14/22/32, weights 400/500. No fixed
numeric cells or CoreText advance measurements provide the alignment oracle.
The proportional-number control uses the same registered serif and lining
selector, with only spacing changed. Font family and variation are checked too.

The first focused run passed: 60 measured rows, maximum tabular spread **0 pixels**,
minimum proportional-control spread **5 pixels**. `alignment/raw-output.txt`
retains every measured array and raw exit. Twelve themed SwiftUI ladder images
show the difference. Marker measurements use a high-contrast white background
for both iterations; the attached ladders themselves render in Paper and Night.
The rendered 32-point ladder was visually inspected: the tabular markers form a
straight column, the proportional control does not, and the figures are lining
serif numerals. This proves the exercised SwiftUI rendering path, not just GSUB.

Unverified: missing-font fallback branch, physical-device readability, VoiceOver,
keyboard interaction, localization, and exhaustive Dynamic Type. Existing native
regressions remain separately reported; the screenshots alone do not prove them.

## E3: remaining mono inventory

From the repository root:

    python3 docs/evidence/issue-263-numeric-voice/inventory.py > docs/evidence/issue-263-numeric-voice/remaining-mono.tsv
    python3 docs/evidence/issue-263-numeric-voice/inventory.py --check

The generated TSV contains **9 retained call sites** (including the two explicitly
retained wordmarks and two settings-row SF Symbols) and **7 declaration/helper
exceptions** (six preserved factories/tokens and the unused morselTag helper).
Wordmarks are identified as brand exceptions, not misrepresented as technical.
TrainingFuelViews is explicitly recorded as an unchanged, out-of-scope half-(a)
exception; its current local serif implementation has zero mono-face sites, so
it is not counted as a fictitious remaining mono call site. Monospaced-digit
features on serif text are not monospaced-font-family usage.

The source contract invokes the generator's drift check. Reintroducing Plex at
the actual 14-point food-energy call site caused two of its four assertions to
fail (raw exit 1); restoration matched the original SHA-256 and the unchanged
suite passed (raw exit 0). Detailed gate receipts are in GATES.md.

## Reproduce native legs

Use a fresh unique result label each time (xcodebuild refuses existing bundles).
No host setup, live data or credentials are required beyond the repository's
existing native toolchain. The wrapper requires hermes-sim-task and acquires
`/tmp/n.lock` atomically with a 60-second admission deadline. Do not bypass it.

    npm ci
    cd app && xcodegen generate
    cd ..
    pgrep -fl 'xcodebuild|xctest'
    df -h /
    touch /tmp/morsel-263-capture.enabled
    python3 docs/evidence/issue-263-numeric-voice/admit.py hermes-sim-task --name morsel-263-recapture --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-16 -- python3 docs/evidence/issue-263-numeric-voice/native.py recapture "$PWD" -only-testing:MorselTests/NumericVoiceCaptureTests
    python3 docs/evidence/issue-263-numeric-voice/package.py recapture recapture

Use the same runner without the capture marker for NumericVoiceTests or the full
native suite. The runner has a 900-second command deadline. Alignment was run
before adding the two convenience aliases; the helper/test bytes are unchanged.
For the before leg, archive the pinned base, copy only the capture test, regenerate
its project, and pass that checkout path instead of `$PWD`. The archive's
production files must match the base before claiming before/after provenance.

NOT MERGED; not opened as PR; nothing pushed to staging or main; no deploy; no production writes.

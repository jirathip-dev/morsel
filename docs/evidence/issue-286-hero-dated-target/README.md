# #286 — repro first, before the fix

Production source pin: `6ae782e8a606111de26b1171d48c3a96115d4b85` (origin/staging at
the brief's base). This commit contains only reproduction code and evidence: no
production fix, and the app target in this commit does not include the repro
test (it is committed here as a runnable artifact for the disposable archive).

## What was reproduced

`HeroPastDayReproTests.swift` mounts the real `TodayView` (the production page,
not a stand-in) on Wednesday 16 September 2026, in Paper and Night, through a
scene-backed `UIHostingController` in the app-hosted XCTest bundle. One
explicitly synthetic meal reproduces the owner-reported totals: 1,953 kcal,
P124/C162/F80. Today's separate 3,000 kcal goal is deliberately not a
historical observation.

At this pin the hero resolves both its goal and its calorie target to nil for
every non-today date. The attached frames show the unfilled ring and three
unfilled strips with correct consumed totals and no target denominators. The
value rows (`124`, `162`, `80`) are present; the target side of every strip is
absent, and nothing on the page explains why.

Raw behavioral result — `repro-red-xcodebuild.log`, 1 test executed, 2
failures, `RAW_EXIT=65`:

    error: -[MorselTests.HeroPastDayReproTests testPastDayWithoutSavedTargetMustNotBeSilentlyEmpty] :
    XCTAssertTrue failed - Past-day target silently disappears despite correct totals: Wednesday, 16 September

Both themes failed the same assertion
(`HeroPastDayReproTests.swift:48`); the totals and the no-backward-borrowing
assertions passed. The full OCR text of each theme is in
`failure-issue-description-1.txt` / `-2.txt` and in the `ISSUE286-REPRO` lines
of the raw log. This is an assertion failure after a successful compile, not a
build failure and not a source-text check.

## Mismatch with the reported build-14 symptom

The issue reports the readout falling back to “Goal unavailable”. This pinned
source does NOT render that text anywhere on the past-day page, and it does not
render replacement copy either — the target region is silently absent. The raw
OCR in this directory preserves that, and no capture or output was edited to
invent the reported wording. The shareable conclusion: the fill target is
missing and the surface is silently empty; the specific “Goal unavailable”
string comes from a different build than this pin. This is an unsigned Debug
simulator reproduction, not the installed TestFlight binary.

## Reproduce

Build a lane-owned archive of the pin (paths required by the app target's
project and Info.plist reference):

    git archive 6ae782e8a606111de26b1171d48c3a96115d4b85 \
      app fastlane docs/evidence/issue-241-artwork-native docs/design \
      | tar -x -C /tmp/morsel-286-repro-first/issue-286-hero
    cp HeroPastDayReproTests.swift \
      /tmp/morsel-286-repro-first/issue-286-hero/app/Tests/MorselTests/
    cd /tmp/morsel-286-repro-first/issue-286-hero/app
    xcodegen generate

An archive missing `fastlane/` fails the build with
`Build input file cannot be found: .../fastlane/Morsel-Info.plist` — a
launcher failure that is NOT the behavioral RED and must not be presented as
one. Run under the shared `/tmp/n.lock` + `hermes-sim-task` admission wrapper,
using the simulator it assigns:

    xcodebuild test -project Morsel.xcodeproj -scheme Morsel \
      -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
      -derivedDataPath /tmp/morsel-286-dd \
      -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
      -only-testing:MorselTests/HeroPastDayReproTests \
      -resultBundlePath <lane log dir>/repro-red.xcresult

The raw stdout+stderr is `repro-red-xcodebuild.log` (trailing whitespace
stripped so the repository's `git diff --check` gate stays clean; content
otherwise untouched); `repro-red-admission.log` is the wrapper's own log.
`repro-manifest.json` pins the source sha, the test sha, every attachment sha
and the raw exit. The production branch was not mutated by this runner; only
the disposable archive carried the test overlay.

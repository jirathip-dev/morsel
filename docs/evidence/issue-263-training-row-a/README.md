# Approved Training day Variant A — native evidence

Scope is issue #263 half (a), owner decision “variant A approved”. Half (b), the app-wide numeric voice, is not implemented.

## Authority

The supplied staging base is `6f3199e2e044f9eaba09cd577b38a5434a01fd8e`. The design files named by the brief are absent there and on product `origin/main`. The approved half-(a) artifacts were read, without merging the design branch, from `design/263-training-row-numeric-voice` at `a0c24d2ee87cd28d9e5e8ed1ea20372924c966a3`:

- `docs/design/263-training-row/SPEC.md`
- `docs/design/263-training-row/STATE-MATRIX.md`
- `docs/design/263-training-row/sources/copy-inventory.md`
- `evidence/a-paper-usual.png` and `evidence/a-paper-unconfirmed.png` under that directory are the visual controls inspected for this port.

The later owner comment on https://github.com/jirathip-dev/morsel/issues/263 approves A and excludes half (b); the archived spec's earlier “awaiting owner review” text is not a competing approval decision.

## Implementation boundary

Today has one ruled, unfilled state/target button. The hero retains its mono Eaten figure and comparison ring but no longer repeats the calorie target, remaining/over statement, or provenance. The row sits below the readout and above unchanged macro strips. Initial loading and read failure retain an available sheet entry; historical dates do not acquire today's row. Missing meal calories do not become a daily calorie total or ring progress. A cached diary refresh failure is labelled.

The shell owns one Training day sheet independently of edit mode. Its order is Today's answer, Readings, About this context. The writing field is blank on first opening, unfilled and underlined; confirmed mode offers edit and sheet-only undo. Cancel/Close/drag dismissal invalidate a pending confirmation. The existing day/account ownership and nil-goal observation rule remain; an open sheet resets honestly on date rollover.

The Health context gains independent read-failure flags and an in-flight state. Missing and permission-opaque readings still use the same unavailable representation, while real zero and original sample/checked dates remain distinct. The reader stays read-only. There is no server/schema change and no persistence cutover: the addition remains session-local, not synced.

Only this row/sheet uses A's locally specified EB Garamond numeric figures (17/19/20/26 pt, explicit tabular lining features). `TrainingDayType` is private to this feature's file/module use. No shared font tokens, bundled fonts, existing `.monospacedDigit()` calls, other numeric surfaces, artwork, or photo behavior were changed. The native test checks the bundled family and equal digit advances at all four sizes.

## Reproduction

From the repository root:

    npm ci
    npm run typecheck
    npm run lint
    npm test
    git diff --check
    cd app
    xcodegen generate
    swiftlint --strict

After admission (`pgrep -fl "xcodebuild|xctest"`; wait at most 60 seconds, do not overlap another native invocation), create and boot a dedicated iPhone 16 simulator with the installed iOS runtime. Run one complete, unfiltered suite, substituting only your own simulator ID and scratch paths:

    HERDR_XCODEBUILD_DIRECT=1 xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,id=<own-UDID>' -derivedDataPath /tmp/morsel-263-a-dd -resultBundlePath /tmp/morsel-263-a-full.xcresult -parallel-testing-enabled NO -testLanguage en -testRegion US CODE_SIGNING_ALLOWED=NO

`TrainingDayTests` exercises all 30 named matrix states and the edit/confirmation/undo/cancel/rollover lifecycle. `TrainingDayEvidenceTests` mounts the production Today view or Training day sheet in an app-hosted UIWindow, with fictional repository/Health inputs. It captures 390×844-point content in both themes; sheet specimens include top, readings and bottom/context positions. Its separate row-paint test has a determinism control, unchanged-draft control, changed-confirmation witness and identical-post-undo witness.

Export attachments with:

    xcrun xcresulttool export attachments --path /tmp/morsel-263-a-full.xcresult --output-path /tmp/morsel-263-a-attachments

Select the attachment names beginning `263-a-` from the exported `manifest.json`; retain the attachment bytes, not stdout-timed simulator captures. `manifest.json` here records state, theme, position, dimensions and SHA-256. `STATE-COVERAGE.md` maps the approved 30-state inventory to those native captures. Source hashes identify the exercised implementation.

## Recorded results

The complete unfiltered native invocation exited **65**: **445 passed, 1 failed, 0 skipped (446 total)**. Both new Training day suites passed (7 behavior tests + 2 render tests), producing all **140** named captures across **30** states and **2** themes. The failure was the untouched `WeightImportTests.testActiveEnergyObserverTriggersImportAndSuccessReload`, line 120, `XCTAssertEqual failed: ("0") is not equal to ("1")`. One isolated diagnostic of that unchanged test then passed (1 test, exit 0). This is not a full-suite green or proof of the failure's root cause; the failed full invocation remains the gate result.

`npm test` exited **1**: **581 passed, 7 failed (588 total)**. All seven failures were the brief's 5000 ms timeout class in untouched server tests (`chatgpt-tool-oauth`, `http`, `render-png`, `tool-classification`). No retry, timeout increase or skip was used. Hosted quality remains unverified.

`npm ci`, typecheck, lint, XcodeGen, strict SwiftLint and diff checks exited **0**. Focused source contracts passed **21/21**; the final new contract against base sources failed **2/3**, exit **1**, as expected. Native focused behavior passed **7/7**, exit **0**. These focused results do not override either red full gate.

## Limits

These are real native renders with fictional inputs, not live-account or device Health evidence. A sheet is mounted directly for repeatable scroll captures; this is not a claim of automated physical taps, native drag dismissal, VoiceOver traversal, software-keyboard viewport or exhaustive Dynamic Type acceptance. Source wiring and model cancellation are tested; physical-device interaction/Health permission acceptance remains separate. Missing/denied scenarios intentionally look identical because HealthKit does not disclose read permission reliably.

The save-error specimen injects a failed local acceptance operation, not a fictional server save. Pending operations are held at the existing asynchronous seam. No production account, database, meals, goals or Health writes were used.

Raw command logs and exact gate exits remain in the lane's untracked `.lane-logs/` and `.report.md`; no filtered log is a PASS/FAIL oracle. The hosted quality check, not a local timeout retry, adjudicates the brief's known untouched-server 5000 ms timeout class.

# Issue #164 — restore previous manual goals

## Implementation and discovery

The restore button beside the unchanged superseded note reuses
`MorselGhostButtonStyle`. It fills all four fields through `edit`, marks all
sources manual, clears the selected computed direction, and calls the existing
`save`. A successful save clears the note/shortcut; a failed save retains it.
Editing or choosing a direction continues the existing flow. Missing, current,
incomplete, or undated manual rows cannot trigger restoration.

The native app does **not** call MCP `get_goals` / `set_goals`.
`loadGoalsContext` reads goals/profile/weight rows; `DashboardMath.supersededManual`
constructs the same numeric values and timestamp. Native `saveGoals` directly
upserts the goals table. At the pinned base, its payload had no `updated_at`:
server issue #154 did not fix this client writer. The existing native payload
now stamps `updated_at`, including fractional seconds. No new write path,
server, schema, dependency, or recency-rule change was made.

Precision limitation discovered before implementation: MCP superseded macros
can contain more precision than the native editor's existing one-decimal save
contract accepts. Restore fills these values exactly, then normal validation
rejects an off-grid value (the test uses `104.25`); it never silently rounds or
writes it. Unconditional one-tap success for arbitrary MCP precision is not
claimed. The existing note's wording and rounded formatting are unchanged.

`GoalsPageCopy` moved byte-for-byte (plus its Foundation import) to its own file
because GoalsEditorModel was already 399 lines. The existing hosted copy guards
now read that file. XcodeGen added the new sources/tests and regenerated the
checkout-name-dependent fixture groups in this checkout's own name.

## Executed verification

- `npm ci`: exit 0.
- `npm run typecheck`: exit 0.
- `npm run lint`: exit 0.
- `npm test`: exit 1; 656 passed, 2 failed, 658 total. Both failures were
  `Test timed out in 5000ms` in unchanged `server/http.test.ts` and
  `server/tool-classification.test.ts`, matching the brief's documented
  host-effect class. No assertion failures; no retry, timeout increase or skip.
  This is **not** a passing full gate.
- `npx vitest run app/issue-164-goals-restore-contract.test.ts app/issue-113-goals-contract.test.ts server/goals-supersede.test.ts`:
  exit 0; 13 passed, including the two unchanged server supersede tests.
- `cd app && swiftlint --strict`: final exit 0. Earlier lint checks caught
  an extra trailing newline and two long test lines; corrected, not suppressed.
- `cd app && xcodegen generate`: exit 0. A second generation in
  `issue-164-goals-restore` followed by
  `git diff --exit-code -- Morsel.xcodeproj/project.pbxproj`: exit 0 against
  the staged generated file. No generated file was manually merged/restored.
- `git diff --check` and `git diff --cached --check`: exit 0.

One focused native invocation, exit 0, **43 tests / 0 failures**, 178.41 seconds
including build, `** TEST SUCCEEDED **`:

```sh
cd app
hermes-sim-task --name Morsel164Restore \
  --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-16 --xcodebuild -- \
  test -project Morsel.xcodeproj -scheme Morsel \
  -derivedDataPath /tmp/morsel-164-dd \
  -resultBundlePath "$PWD/../.lane-logs/native.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:MorselTests/GoalsRestoreTests \
  -only-testing:MorselTests/GoalsRestoreRenderingTests \
  -only-testing:MorselTests/GoalsEditorTests \
  -only-testing:MorselTests/GoalsEditorPrecisionTests \
  -only-testing:MorselTests/GoalsEditorRecencyTests \
  -only-testing:MorselTests/GoalsPageCopyTests \
  -only-testing:MorselTests/GoalsPolishTests CODE_SIGNING_ALLOWED=NO
```

The wrapper supplied dedicated simulator
`FA53598A-E3C4-4564-8F29-77EC545CD2D7` (iPhone 16, iOS 26.5), then deleted it.
Before admission: `df -h /` showed 4.5 GiB available;
`pgrep -fl 'xcodebuild|xctest'` exited 1 (none). A sibling native job began
later; it was not touched. All transport traffic is intercepted by the test
URLProtocol. The fixture preserves the old timestamp on UPDATE unless the
actual encoded payload supplies one. Assertions inspect all four exact values,
manual source, account, new timestamp, effective-goal reload, absent shortcut,
ordinary edit/computed save, failure and precision refusal. No live DB or MCP
response is asserted from these offline tests.

## Rendered evidence

`164-paper-before.png`, `164-night-before.png`: real production `GoalsView`
with a superseded manual row, unchanged computed fields, note and restore button.

`164-paper-after.png`, `164-night-after.png`: a newly mounted production
`GoalsView` reading the saved fixture row, all four manual fields
`2000.5 / 104.2 / 255.7 / 60.1`, no superseded note or shortcut.

These are app-hosted UIHostingController component captures at 390×1100 points,
1170×3300 pixels, not full-shell device screenshots or physical tap recordings.
The action is exercised at the model/repository seam; the hosted guard pins the
button action. Native Vision OCR assertions check button/note presence before,
absence after. Visual inspection confirmed both themes and no clipped controls.
The original Display-P3 attachment bytes are preserved. After colour-managed
sRGB conversion, ground pixels are Paper `(255,248,232)` and Night `(42,38,30)`
(within one quantization level of their existing tokens). `manifest.json` pins
image and source SHA256s.

## Regression discrimination

`python3 app/evidence/issue-164-restore/prove.py` ran while HEAD was the base
`afd6d45e642aa144af1f18000c91126889e2ab2f`. It used `git archive HEAD` in a
disposable tree, overlaid only the new hosted test, and symlinked node_modules.
Replay after delivery with that base SHA as its argument.

- Base source guard: exit 1, all 3 assertions failed:
  - `superseded note must offer restore` (missing button).
  - `restore action must exist: expected -1 to be greater than or equal to 0`.
  - `native goal upsert must encode updated_at` (missing coding key).
- Fixed sources in the same scratch tree: exit 0, 3 passed.
- Scratch original bytes restored, SHA256s identical; lane bytes never changed.
  Full before/after hashes are in `restore-bookends.json`.

This RED is executable hosted **source-wiring** proof, not a native behavioral
RED run. Native behavioral and rendering tests ran GREEN once; no additional
native mutation invocation was made under the brief's one-native-leg budget.
Raw logs and exits are retained in the implementation worktree's `.lane-logs/`.

NOT MERGED; not opened as PR; no deploy; no production writes.

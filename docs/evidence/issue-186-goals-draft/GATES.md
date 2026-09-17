# Gate receipts — issue 186 (draft revisions own hydration + save acknowledgement)

Lane checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-186-goals-draft`.
Base: `69a81602d6be03a2c316f85270a32ede84455d2a` (`origin/staging`).
Code commit: `ff4b32d`; test bytes + generated project: `d7cafdc`.
There is no justfile; the brief's exact commands are the entry points.
Complete raw logs are in the checkout's `.lane-logs/` (gitignored); the excerpts
committed here are the same bytes with trailing whitespace stripped.

## Required gates

| Exact command | Raw exit | Actual result | Log |
| --- | --- | --- | --- |
| `git stash push -- app/Sources/Morsel/GoalsEditorModel.swift`, then the focused invocation below at that base | **65** | 7 tests, **2 passed / 5 failed**, 15 assertion failures — `native/base-red-focused.txt` | `.lane-logs/red-goals-draft-revision-7tests.log` |
| same focused invocation at the head | **0** | 7 tests, **0 failures**, `** TEST SUCCEEDED **` — `native/head-focused.txt` | `.lane-logs/head-focused.log` |
| one invocation: all twelve Goals suites (focused class included) | **0** | **75 tests, 0 failures**, 12 suites passed — `native/head-goals-suite.txt` | `.lane-logs/head-goals-suite.log` |
| `cd app && swiftlint lint --strict` | **0** | 188 files, 0 violations | `.lane-logs/swiftlint.log` |
| `cd app && xcodegen generate` then `git diff --exit-code` | **0** / **0** | regenerated project is byte-stable | `.lane-logs/xcodegen-stability.log` |
| `git diff --check` (worktree) and `git diff --check 69a8160..HEAD` | **0** / **0** | no whitespace errors | `.lane-logs/diff-check.log`, `.lane-logs/diff-check-range.log` |
| `mise exec node@22 -- npx vitest run app` (node `v22.23.2`) | **0** | 21 files / **153 tests**, app contracts green (`issue-113`, `issue-123`, `issue-164`, `issue-185` included) — `hosted/app-contracts.txt` | `.lane-logs/hosted-app-contracts.log` |
| `mise exec node@22 -- npm ci` | **0** | 256 packages from the committed lockfile; dependencies untouched | `.lane-logs/npm-ci.log` |

Native artifacts: focused base `B296FFD4-B7AA-4426-8AD7-71E1A8DBA7EB`, focused
head `AC30356C-7535-4F47-9F34-F20028253F21`, suite `CFF9CBE8-1DEC-40A4-B92E-EF4BB0849A6C`
(each a `hermes-sim-task` private simulator, deleted after the run). Receipts
with argv, exits and counts: `native/run.json`, `hosted/run.json`.

## Generated project note

`app/Morsel.xcodeproj/project.pbxproj` is xcodegen output. Besides the two new
test files, the regenerated diff renames the group that represents the `..`
resource path (`../docs/evidence/issue-241-artwork-native/fixtures`): xcodegen
names that group after the **checkout directory**, so the committed base carried
`issue-183-cache-ordering` (the lane that last regenerated it) and this lane's
regeneration carries `issue-186-goals-draft`. Nothing under that group changed —
its only referenced files are the unchanged `issue-241-artwork-native/fixtures`
PNGs — and the stability gate above re-ran `xcodegen generate` in this checkout
with `git diff --exit-code` = 0, which is the reproducible condition the repo
uses (any checkout regenerates its own directory name).

## Disclosures

- **Infrastructure retry.** The first native attempt (19:41) died before any
  test ran: `hermes-sim-task: simulator did not reach booted state`
  (raw exit 1, no tests executed). The same command was retried once; that
  retry is the base-RED run recorded above. No assertion, timeout or test file
  was changed to obtain it.
- **Superseded intermediate runs** (kept as history, not part of the gate):
  the six-test RED at the same base (`.lane-logs/red-goals-draft-revision.log`,
  exit 65, 6/14 failures), the six-test focused GREEN
  (`.lane-logs/green-goals-draft-revision.log`, exit 0) and the six-test
  combined suite (`.lane-logs/goals-suite.log`, exit 0, 74 tests). The seventh
  test (`testRefreshDuringASaveCannotRewriteTheSubmittedValues`) was added
  after that capture; the base RED was therefore re-captured with the final
  seven-test class, and only that run is cited above.
- **Serialized native admission.** Every native invocation ran under
  `flock /tmp/n.lock` with the lane's `hermes-sim-task` private simulator; no
  concurrent heavy native gate, no host-level change, and no sibling lane or
  simulator was signalled or deleted.
- **Not run:** the full `npm test` suite (server/db) and hosted CI. Only the
  app-contract subset in the table above was executed.
- The base-RED run substituted exactly one file
  (`app/Sources/Morsel/GoalsEditorModel.swift`) via `git stash push`, then
  restored it and verified `shasum -a 256 -c` → `OK` before the head runs.

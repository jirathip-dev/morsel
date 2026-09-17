# Goals latest-choice evidence — issue #185

Implementation and native acceptance are verified. The full hosted quality
suite is **not green**: the CI-version run exits 1 with two 5000 ms timeouts,
and those same cases also time out in the final focused diagnostic.

## Provenance and artifacts

- Audited base: `2ddba7e0443c3d05f1345a4ce178738426144781`.
- Tested implementation: `a6c679dfd2094bfb69e8d07e1a13821fa9c4f4eb`.
  Later delivery changes only this evidence directory. Production, native test,
  spy and generated-project bytes match the six SHA-256 pairs in
  `restore-bookends.json`.
- `commands.json`: actual native/probe/final hosted argv, working directories,
  raw exits, deadlines reached and measured durations where recorded.
- `verification.txt`: selected actual log lines, with trailing whitespace
  removed. Complete logs remain in the named checkout's `.lane-logs/`.
- `prove.py`: reproducible archive-only behavioral proof. Invoke under the
  shared lock and owned simulator, never against mutable production files:

  ```sh
  flock /tmp/n.lock hermes-sim-task --name Morsel185 -- python3 docs/evidence/issue-185-goals-latest-choice/prove.py
  ```

The admission wrapper bounded lock acquisition to 600 seconds, and each native
command to 900 seconds; tests had a 30-second execution allowance. Both native
batteries acquired `/tmp/n.lock`; no sibling process was signalled.

## Acceptance

| AC | Executed regression | Result |
| --- | --- | --- |
| F1 | `testReversedSuccessesKeepBulkValuesSourcesAndSelection` | Cut starts first, Bulk finishes first; Bulk's goal, fields, all sources and selection remain after Cut finishes. Exactly two requests. |
| F2 | `testObsoleteErrorCannotOverwriteNewerSuccess`, `testLatestFailurePreservesAcceptedValuesAndRetrySurvivesOldSuccess` | Obsolete failure does not publish; current failure preserves accepted Maintain and names Bulk retry. Old success cannot erase that error; retry succeeds. |
| F3 | `testManualEditInvalidatesBothLateSuccessAndError`, `testTeardownDiscardsLateSuccessAndErrorAndAllowsNewGeneration` | Manual fields/sources survive late success/error; teardown discards both and allows a subsequent generation. Hosted view guard pins `.onDisappear` wiring. |
| F4 | `testCallerCancellationDiscardsNoncooperativeSuccessAndError`, `testRepeatedEquivalentChoicesCoalesceWhilePendingAndAfterAcceptance`, `testCutBulkCutUsesGenerationNotDirectionEquality` | Cancellation is observed despite noncooperative continuations. Initial choice + 20 pending repeats + 20 accepted repeats produce one compute; edit then choose produces exactly two total. Cut/Bulk/Cut produces three, and the first Cut cannot replace the last. |
| F5 | Base-file substitution inside a disposable `git archive HEAD` tree | Base compiles and runs six unchanged race tests: exit 65, 21 assertion failures. Restored archive: exit 0, 12 tests, zero failures. All six restore hashes equal their originals. |

The native trace's word `taps` denotes calls to the production `choose` method,
not physical touch injection. Request counts are asserted in the native tests,
not inferred from wall-clock timing. Additional tests protect pending-versus-
accepted state, save refusal while pending, return to the accepted direction,
obsolete pending cleanup, and an older context load.

## Native and hosted outcomes

- Initial focused native run: exit 0, 57 tests. Its `GoalsPageTests` filter
  matched no class. It also used macOS's default `/var/folders/.../T` temporary
  root rather than the brief's literal `/tmp` fence. These are disclosed
  execution mistakes, not counted as the final complete goals gate.
- The archive RED/GREEN proof ran in that original isolated temporary root.
  It replaced both complete production files from the pinned base; only the
  separate new-API ownership test file was omitted to allow base compilation.
  Race-test and spy bytes stayed unchanged. No mutation touched the worktree.
- Hosted view guard against the base view: exit 1, two assertion failures;
  byte-restored view: exit 0, two passes.
- Corrected final native invocation: exit 0, **68 tests / zero failures**, all
  eleven goals suites in one run (not a union of partial gates), including
  `GoalsEditorRecencyTests`, `GoalsPageCopyTests`, and #164 restoration tests.
  Simulator `1D513073-D02E-4921-91A1-E232069E2927`; result bundle
  `/tmp/morsel-185-isorat8t/native-final.xcresult`. The lane's completed build
  cache was moved into this `/tmp` root; Xcode emitted stale-old-path warnings
  but compiled and ran the tests successfully. The corrected driver is
  committed; the earlier archive proof was not repeated merely to change its
  temporary parent directory.
- `swiftlint --strict`: initial exit 2 (new line/body limits), fixed without
  suppressions; final exit 0. `cd app && xcodegen generate`: exit 0; generated
  project drift check in this checkout: exit 0.
- CI-version Node `22.23.2`: `mise exec node@22 -- npm ci`, `npm run typecheck`
  and `npm run lint` each exit 0 (the same prefix was used for all three).
  npm reports five existing dependency vulnerabilities; dependencies untouched.
- `mise exec node@22 -- npm test`: exit 1, **669 passed / 2 failed**, 60 files.
  Failures are `server/http.test.ts`'s tool-registration case and
  `server/tool-classification.test.ts`'s read-only-state case, each at the
  unchanged 5000 ms budget. No final-run `onTaskUpdate` error.
- `mise exec node@22 -- npx vitest run server/http.test.ts server/tool-classification.test.ts`:
  exit 1, **8 passed / 2 failed**, same two timeouts. This is a diagnostic,
  never an aggregate PASS. Their cause was not established; neither the tests,
  their timeout, nor the forbidden server files were modified.
- Earlier ambient Node `26.7.0` full run: exit 1, 663 passed / 8 timeouts and
  an unhandled `[vitest-worker]: Timeout calling "onTaskUpdate"` finding.
  Earlier focused hosted diagnostic: exit 0, 49 tests including the
  #113/#123/#164/#185 contracts. Neither result substitutes for the final
  CI-version full-suite failure.

No physical-device, live-account, HealthKit, hosted CI, or deployment claim.
No formula, RPC, server, migration, dependency, workflow, or forbidden-file edit.

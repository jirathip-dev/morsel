# Issue 258 — fix round 1 evidence

Reviewed head: `72a004b14722f7eb4eb8437fa7fa28c451aa71a4`.
The reviewer found that the local-first facade returned cached data through the successful
`loadToday` path, bypassing the view model's catch-only stale flag.

## Fix contract

- F1: native `DashboardSnapshot.readProvenance` carries cached/current and the last successful
  read time. The facade saves successful provenance with the existing day cache; cache hydration
  marks the returned copy cached without updating its timestamp. Pending-row merging preserves
  provenance. Both view-model read publishers consume it; the notice properties derive from the
  published snapshot rather than independent state. Legacy caches retain an unknown timestamp.
- F2: `DayReadCompositionTests` composes the real Supabase remote, local-first facade, SQLite cache
  and view model. It checks successful read → failed refresh two hours later → recreated facade
  and view model → successful retry. It also checks empty-cache failure and legacy-cache fallback.
- F3: all four attachments were regenerated through the same production composition and inspected.
  Both stale images retain 11:00 AM after the failed 1:00 PM refresh; both degraded images match
  their previous PNG bytes exactly. See the parent manifest for dimensions, hashes and assertions.
- F4: an item whose parent is not among the returned logs flags every meal incomplete, preserving
  all attributable readable rows, matching the server's existing behavior.
- F5: all unrelated comment/format compressions in Models/ViewModel were restored. Relevant day
  models and cache hydration helpers moved to `DayReadState.swift` to respect the existing lint
  budgets without deleting unrelated documentation. `MealGroup` moved byte-unchanged.
- F6: the in-memory repository marks both photo and no-photo day reads `items_read: complete`.

No migrations, shared MCP schema, timezone/day-key rules, photo behavior, refresh scheduling or
read-batching were changed in this round. The new optional provenance is native cache metadata.

## Executed regression evidence

`native-red.txt`: tests added before the implementation changed; raw exit 65, 9 tests, 7 failed
assertions across 3 test cases. Six assertions expose facade/cache timestamp dishonesty, and one
exposes unattributable-row loss. The existing bare-remote tests remain useful but are not the
production-composition witness.

`native-green.txt`: repaired sources; raw exit 0, 10 tests, 0 failures. This includes the 9 behavior
tests and the evidence test that generates four attachments. This is one complete focused invocation,
not an unfiltered application-suite result.

`native-red-replay.txt`: final behavior-test bytes against reviewed production sources in a
throwaway archive; raw exit 65, 9 tests, the same 7 assertion failures. This replay was necessary
because the retained bare-remote fixture was corrected to return a day-start snapshot between the
initial RED and GREEN. Neither the F2 composition test nor F4 assertion changed. The evidence fixture
was left at its reviewed version in the replay because the corrected fixture uses the new facade
clock initializer; it was not selected for execution.

`restore-bookends.json`: the scratch tree was populated with the fixed bytes, changed to reviewed
sources for RED, then restored byte-for-byte to the fixed bytes in a `finally` block. All SHA-256
bookends agree. The lane's implementation files were never overwritten for the replay. The two
behavior-test file hashes match the GREEN run exactly. The native receipts also record before/after
hashes around each invocation and its actual raw exit and elapsed seconds.

`server-red.txt` / `server-green.txt`: exact command
`npx vitest run server/day-read-degrade.test.ts`, raw exits 1 → 0, 1 failed/7 passed → 8 passed.
The RED assertion receives `[undefined]` instead of `['complete']` from the in-memory read. The
same suite preserves the existing Supabase item-failure, unattributable-row and #149 photo guards.

The `.txt` files are selected raw runner output, with ANSI escapes and trailing whitespace removed,
not reconstructed output. Each names the full local log and its SHA-256. Build chatter is omitted.

## Native command

From `app/`, for the passing gate:

```sh
HERDR_XCODEBUILD_DIRECT=1 xcodebuild test \
  -project Morsel.xcodeproj -scheme Morsel \
  -destination 'platform=iOS Simulator,id=152E7AA9-8BC5-41D0-AD74-F73C7C69A3EB' \
  -derivedDataPath /tmp/morsel-258-fix1/dd \
  -resultBundlePath /tmp/morsel-258-fix1/native-green.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:MorselTests/DayReadDegradeTests \
  -only-testing:MorselTests/DayReadCompositionTests \
  -only-testing:MorselTests/DayReadDegradeEvidenceTests
```

RED commands omit the evidence class and use `native-red.xcresult` or
`native-red-replay.xcresult`. The replay runs from
`/tmp/morsel-258-fix1/pre-fix-replay/app`; its project is regenerated, not hand-merged.
Each native leg first checks `df -h /` and `pgrep -fl 'xcodebuild|xctest'`, with at most three
60-second contention waits. Each native command is bounded to 900 seconds. No timeout occurred.

## Gates and limits

`gate-exits.json` records exact commands, raw exits, local log paths and log hashes.
`npm ci`, typecheck, lint, focused server tests, xcodegen, regeneration hash comparison,
final SwiftLint and diff-check passed. Initial SwiftLint exited 2 on a 407-line ViewModel and one
143-character evidence comment; both were corrected structurally before the final gate.

`npm test` was run once: raw exit 1, 589 passed / 4 failed (593 tests). All four failures are
`Test timed out in 5000ms` in `server/http.test.ts`, `server/render-png.test.ts` (two cases),
and `server/tool-classification.test.ts`. There are no assertion failures. This is the fix brief's
known host-side timeout class; no budgets, skips or retries were introduced. Hosted `quality`
remains unverified, not claimed green.

Not rerun this round: the original unfiltered native suite, Postgres gate and Bun gate (the fix
brief specifies a narrower gate set). No physical-device or live-service failure was exercised.
The notices and values were inspected in simulator window attachments; meal rows are below the
captured viewport and their identities/completeness are verified by native assertions. Retry uses
the real `load()` path in the tests, but an actual touchscreen tap is not claimed.

NOT MERGED; not opened as PR; no deploy; no production writes.

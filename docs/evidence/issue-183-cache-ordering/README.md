# Issue #183 — reject obsolete cache writes and preserve cancellation semantics

Base `163830a2e343a59a72935fc45936391372ebe534` (`origin/staging` at lane start, carrying
#182's refresh owner). Head = this lane's commits on `issue/183-cache-ordering` (exact sha in
the lane `.report.md` and in `exits.json`).

Everything here is an **unsigned Debug simulator run** (`CODE_SIGNING_ALLOWED=NO`, lane-private
iPhone 16 simulator `Morsel183-iPhone16` on iOS 26.5) — **not** a physical device, no HealthKit,
no live account and no real health/meal content. Every fixture value is synthetic. Raw logs stay
in the untracked `.lane-logs/`; each excerpt below carries its raw log's byte size, SHA-256 and
raw exit status.

## The audited mechanism

`LocalFirstDashboardRepository.loadToday` / `loadHistory` wrote the snapshot cache inside their
`do` block, so:

- a read that was superseded while its remote call was still in flight still published on
  completion — an older read that merely finished later overwrote the newer entry;
- a read superseded by a local mutation (no task cancellation involved) republished a payload
  that predates the write;
- an account teardown could be repopulated by a read that was already in flight;
- a cache write fault landed in the same `catch` as a remote failure, so a *successful* remote
  read returned the older cached payload (or failed outright on a cold cache).

## What changed

| file | change |
| --- | --- |
| `app/Sources/Morsel/LocalSnapshotCache.swift` | monotone publication **generations** per account+resource+day/range scope, a per-account invalidation epoch and a teardown fence (`clearAccountData`); the generation-scoped write-through checks and writes under one lock; ordering never compares `saved_at` |
| `app/Sources/Morsel/LocalFirstRepository.swift` | today/history reads begin a publication, refuse to report a superseded result as fresh (`CancellationError`) and publish best effort; `logMeal`, `deleteMealLog`, `updateMealItem`, `confirmMealItem`, `attachMealPhoto`, `saveGoals` invalidate in-flight reads; the injected clock stamps `saved_at` |
| `app/Sources/Morsel/TodayRefreshOwner.swift` | an invalidating write also fences the in-flight pass's publication (`ReadPublicationFencing`) |

No timestamp ordering is used anywhere: a newer read wins by generation, and two publications
that carry the **same** `saved_at` still order correctly.

## AC map (native XCTest, real SQLite files)

| AC | test (both classes in `app/Tests/MorselTests/LocalCachePublicationOrderingTests.swift`) |
| --- | --- |
| 1 — reversed completion keeps the newer read in the visible state *and* in a newly recreated reader | `CachePublicationOrderingTests.testReversedCompletionPublishesOnlyTheNewerReadAndSurvivesWarmRestart` |
| 2 — superseded by mutation invalidation (repository and refresh-owner paths) and by account teardown | `…testMutationInvalidationCannotPublishAnInFlightRead`, `…testRefreshOwnerInvalidationCannotPublishTheInvalidatedPass`, `CachePublicationFenceTests.testAccountTeardownFencesInFlightWritesAndServesLaterReads` |
| 3 — cancellation is cancellation; genuine offline keeps the cached day; a cold offline read is never a success | `CachePublicationFenceTests.testCancellationIsCancellationAndOfflineKeepsTheCachedDay` |
| 4 — per account/resource/day/range scoping; equal timestamps cannot bypass ordering | `CachePublicationFenceTests.testIndependentDaysAndAccountsAreNotBlockedByAHeldRead`, `CachePublicationOrderingTests.testEqualTimestampsCannotBypassOrdering` |
| 5 — reversed completion, teardown, cancellation, write failure and warm restart; freshness metadata | all of the above (each reads the entry back through a **newly opened** `LocalSnapshotCache`/repository over the same file) |

## RED → GREEN

- `red-base-focused.txt` — base `163830a` **with the lane's tests only**: 8 tests, 15 failures,
  raw exit **65**, 0.412 s. The two tests that pass at base are the scoping witness and the
  cancellation/offline witness; the other six fail on the audited mechanism (a superseded read
  reporting its obsolete payload as fresh, the warm restart serving the older entry, the
  teardown repopulating a cleared account, and a cache write fault turning a fresh read into an
  error).
- `green-focused.txt` — the same two classes at head: 8 tests, 0 failures, raw exit **0**, 0.118 s.

## Mutation battery (`mutation-battery.txt`)

Six mutations of the committed head, each rerunning the focused suite; every one must RED its
named test, and the source is restored with `git diff --exit-code -- app/Sources/Morsel` empty
(`TREE-RESTORED-CLEAN`):

| mutation | raw exit | named test failed |
| --- | --- | --- |
| remove the read-side supersession guard | 65 | `testReversedCompletion…WarmRestart` |
| remove the teardown fence from `clearAccountData` | 65 | `testAccountTeardownFences…` |
| remove the `logMeal` invalidation | 65 | `testMutationInvalidationCannotPublishAnInFlightRead` |
| remove the refresh-owner hook | 65 | `testRefreshOwnerInvalidation…` |
| stamp `saved_at` with the wall clock instead of the injected clock | 65 | `testEqualTimestampsCannotBypassOrdering` |
| make the cache write `try` instead of best effort | 65 | `testCacheWriteFailureStillReturnsTheFreshRemoteRead` |

## Gates

| gate | result |
| --- | --- |
| `swiftlint lint --strict` (app, 185 files) | 0 violations, raw exit 0 (`swiftlint-strict.log`) |
| `xcodegen generate` then `git diff` | empty (byte-stable), `xcodegen-diffcheck.log` |
| `git diff --check` | exit 0, `xcodegen-diffcheck.log` |
| one complete unfiltered native run | 542 tests / 3 skipped / 5 failures, raw exit **65** (`gate-full-native.txt`) |
| hosted app contracts (`npx vitest run app/`) | 20 files / 142 tests passed, raw exit 0 (`hosted-contracts.txt`) |
| `npm test` | 61 files (3 failed) / 675 tests (4 failed), raw exit **1**, `AssertionError` count 0, all four failures are `Test timed out in 5000ms` in Swift-unrelated server suites; the three files pass 12/12 alone with a 60 s diagnostic budget (`hosted-contracts.txt` — diagnostic only, never gate evidence) |

## Known pre-existing red (disclosed, not folded in)

The unfiltered native run's 5 failures come from 4 test methods. Reverting the fix to `163830a`
and rerunning exactly those methods (`pre-existing-native-base.txt` / `-head.txt`, raw exit 65 on
**both** legs) shows three of them are red at base with the fix reverted:

- `PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll`
- `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts`
- `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping`

(the same set the #181 lane recorded as known red on this base). The fourth,
`MealReliabilityTests.testOfflineAddMealCommitsLocallyAndPaintsPendingRow`, passes in the focused
reruns at base **and** at head and failed only inside the full run: the documented load/timing
flake, not an assertion about this change.

## What this evidence does NOT cover

- No physical device, no HealthKit and no live account (tracker #172 owns that).
- The generation gate covers the Today and History resources; the goals/menus cache writes are
  untouched (goals direction generation is #185's, already merged) and only the account-wide
  invalidation fence reaches them.
- The production sign-out path (`AccountReliabilityServices.shutdownAndClear`, out of this lane's
  fence) deletes the whole account directory instead of calling `clearAccountData`; the teardown
  fence is proven through the cache's own teardown seam.
- `LocalSnapshotCache.allows` re-checks the generation inside the write lock (closing the window
  between the repository's check and the upsert). That window is not separately observable in
  these witnesses, so the write-side check is belt-and-braces rather than independently
  mutation-proven.
- Simulator screenshots are not part of this evidence: the ACs are ordering/state contracts, and
  the witnesses drive the shipped repository and the real SQLite file directly.

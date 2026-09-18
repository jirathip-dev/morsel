# #194 — dense meal, weight and menu reads are complete under a bounded paging read

Lane checkout: `/Users/jirathip/.herdr/worktrees/morsel/issue-194-bounded-paging`.
Base: `1cf9ecc26b56037b53b34cc611425043bf21a36d` (`origin/staging`).
Test commit (the RED bytes): `026d7f23695f4ab2c7bcc30e8e17be27aeadec33`.
Fix commit: `807b1fc9ad112a804bce677539027c8129e47626`.
The head that includes this evidence commit (and the final gate re-run) is in
`.report.md` — it is gitignored by this repo, so it can carry the true head.

## The audited mechanism (base pin)

Every collection read asked for "everything" in ONE request:

- `Repository.loadMealLogs` / `loadMealItems` / `loadWeightTrend`,
  `HistoryRepository.loadLedgerMealLogs` / `loadLedgerMealCalories` and
  `SupabaseMenus.listMenus` sent no `limit`/`offset` at all, and the meal/menu
  item reads put every parent id into one `in.(...)` list.
- A deployment row cap (Supabase's `db-max-rows`, default 1000) therefore
  truncated the response **silently**: the app received a prefix of the day,
  the trend window or the menu library and rendered it as if it were complete.
- A dense day's id list also went out as one very long request URL.

## What changed

- **`BoundedReadPaging.swift` (new)** — the paging layer:
  - `BoundedRead` documents the bounds: `pageSize = 200` rows per page,
    `idChunkSize = 50` ids per `in.(...)` request, `maxConcurrentChunks = 1`
    (chunks are sequential, so a long list cannot fan out).
  - `pagedRows` reads one ordered collection to completion: it advances by the
    rows actually received, keeps the first copy of each identity, checks
    cancellation before every page, and ends on an empty page.
  - **Cap handling:** when the deployment clamps a response below the requested
    page size, the covered span in `Content-Range` is adopted as the effective
    page size and paging continues — a clamped deployment still returns the
    COMPLETE collection. A short page therefore costs one extra (confirmation)
    request: only the next request can prove the collection ended rather than
    the deployment clamping.
  - `chunkedRows` sends ids in bounded chunks and pages every chunk.
  - The paged bodies of `loadMealLogs` / `loadMealItems` / `loadWeightTrend`
    live here (Repository.swift is at the 400-line lint cap and delegates); the
    ledger and menu seams stay in their own files, next to their private row
    types.
- **Total order + tie-breaking identities** (AC2): `eaten_at,id` (meal logs),
  `created_at,id` (items), `measured_at,kg` (weight samples), `name,id`
  (menus), `menu_id,id` (menu items). A page boundary always falls between rows
  whose order is total, equal timestamps included.
- **Deduplication** (AC1): rows are deduped by primary key — the weight pair
  `(measured_at, kg)` is the whole identity of a projected sample, and the
  ledger's narrow item projection (deliberately key-less, #193) needs none
  because its ordering keys are immutable.
- **Failure, cancellation, scope** (AC3/AC4): a failed page throws out of the
  read, so no partial snapshot can be cached or published; the loop checks
  cancellation before each page; every page and chunk re-applies the account
  and window filters (a chunk's ids are the account's own meal/menu ids).
- **No index, no migration, no new UI.** The existing `(user_id, eaten_at)` and
  `(meal_log_id, created_at)` access paths already serve these ordered ranges.

## Consistency while paging (AC5, documented in the helper)

- A concurrent INSERT is either visible inside a later page or not visible at
  all — never half a row.
- An UPDATE that moves a row LATER in the order can deliver that row twice:
  identity dedupe keeps the first copy, so totals never double count.
- An UPDATE that moves a row EARLIER in the order can miss it for this read;
  the next read is complete again.
- A DELETE simply stops appearing. The ledger's narrow read orders on
  immutable keys (`created_at` + `id`), so those rows cannot migrate.

## AC mapping

| AC | Where it is proved |
| --- | --- |
| 1. A capped fake transport returns complete, deduplicated meals/items/weight samples/menus across multiple pages | `BoundedPagingTests.testCappedServerReturnsEveryMealAndItemAcrossPages`, `…EveryWeightSampleAcrossPages`, `…EveryMenuAndItemAcrossPages`, `BoundedPagingBoundaryTests.testLedgerKeepsDistinctRowsThatShareTheirValues` — the transport caps every response at 2–3 rows and the assembled result is compared with the same fixture read with the cap out of the way |
| 2. Large id lists are chunked to a documented bound; page requests have stable ordering and tie-breaking identities | `BoundedPagingTests.testLargeMealIDListsGoOutInBoundedChunks` (120 meals → chunks `[50, 50, 20]`, disjoint, complete), `testPageRequestsCarryStableOrderingAndTieBreakers` (the recorded `order=` values of all five collections) |
| 3. Totals/grouping match an uncapped reference; no silent partial snapshot on an intermediate page failure | `BoundedPagingTests.testHistoryTotalsMatchTheUncappedReferenceAcrossPages` (day-by-day parity), `BoundedPagingBoundaryTests.testAnIntermediatePageFailureFailsTheRead`, `testAFailedPageNeverReplacesTheCachedSnapshot` (the local-first facade keeps the complete cached payload byte-for-byte) |
| 4. Cancellation stops further pages; filters apply to every chunk; bounded concurrency | `BoundedPagingBoundaryTests.testCancellationStopsFurtherPages`, `BoundedPagingTests.testEveryPageAndChunkCarriesTheAccountAndWindowScope`, `testChunkAndPageFanoutStaysBounded` (pages/chunks are sequential, the read graph stays within `ReadGraph.maxInFlightRequests`) |
| 5. Consistency documented; boundary duplicates / equal timestamps / empty last page tested; no index added | the helper's header documents the behaviour and `BoundedPagingBoundaryTests.testDocumentedBoundsAndConsistencyBehaviourArePinned` pins the bounds and the contract phrases; `testEqualTimestampsSplitAcrossPagesStayCompleteAndUnique`, `testBoundaryDuplicateIsDeduplicatedAndNotDoubleCounted`, `testEmptyLastPageTerminatesAnExactlyFullCollection`; no migration or index was added |

## RED → GREEN

- **RED** (base production code, final committed test bytes): `RAW_EXIT=65`,
  16 tests, **51 failures** — every completeness assertion fails on the audited
  mechanism (a capped server answers 3 of 7 meals; the 120-id list goes out as
  one request; `reads == 1` where the read must page)
  (`excerpts/red-base-paging.txt`).
- **GREEN** (head, the same focused command): `RAW_EXIT=0`, 16 tests, 0
  failures (`excerpts/green-head-paging.txt`).
- **Head repository/menu classes** (one invocation, 18 classes):
  `RAW_EXIT=65`, 92 tests / 1 skipped / **1 failure** — the pre-existing
  `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts`
  (`excerpts/head-focused-repository-menus.txt`).
- **Base leg with the fix stashed** (same classes): `RAW_EXIT=65`, 76 tests /
  1 skipped / **the same single failure**, reproduced with the fix out of the
  tree — the red is pre-existing, not this lane's
  (`excerpts/base-known-reds.txt`).
- **Full unfiltered native suite** (one complete invocation): `RAW_EXIT=65`,
  630 tests / 3 skipped / **4 assertion failures in 3 tests**, all three
  documented pre-existing reds: `PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll`,
  `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts`,
  `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping`.
  Both new suites pass inside it (`excerpts/head-full-native.txt`).
- **Mutation battery** (head, one mutation per defended mechanism):
  `excerpts/mutation-battery.txt`.

## Recorded limits (disclosed, not silently claimed)

- **A short page costs one confirmation request.** A deployment that clamps
  below `BoundedRead.pageSize` and a collection that simply ended look
  identical in the response; only the next request can tell them apart, and
  skipping it would truncate a clamped deployment. Test transports that send no
  `Content-Range` (the pre-#194 stubs) keep the one-request behaviour, which is
  why the existing request-count pins still hold.
- **One out-of-fence edit, disclosed:** `app/v1-journal-contract.test.ts` gains
  `BoundedReadPaging.swift` in its `rawTokenAllowlist` (2 lines). The helper must
  name the client SDK's builder/response types to read a ranged response's
  `Content-Range` header; that is the same "backend plumbing, never user-facing
  copy" case the existing `MealRepository.swift` entry documents. The
  alternatives were rejected: the classic short-page rule truncates under a
  clamp, and a client-side probe request breaks the read graph's pinned request
  counts (`reads == 6`, `meal_logs == 1`).
- **The ledger item read is deliberately key-less** (#193's narrow projection):
  it is not deduped, because its ordering keys are immutable and distinct rows
  that share a calorie value must both count
  (`testLedgerKeepsDistinctRowsThatShareTheirValues`).
- **The first RED attempt is kept** as
  `.lane-logs/red-base-paging-pre-fixture-fix.txt`: it exposed a fixture
  id-format bug (ids with a 9-character first group for numbers ≥ 10, which the
  app rejects as invalid UUIDs). The fixture was fixed and the recorded RED/GREEN
  legs run with the final bytes.
- **Simulator/model evidence only.** Physical-device acceptance stays with #172.
- **No production data or secrets** in any log; fixtures are synthetic.

## Files

| File | Change |
| --- | --- |
| `app/Sources/Morsel/BoundedReadPaging.swift` | **new** — bounds, paging/chunking machinery, the paged Today/History-graph seam bodies |
| `app/Sources/Morsel/Repository.swift` | the three collection seams delegate to the paged bodies (file stays inside the 400-line cap) |
| `app/Sources/Morsel/HistoryRepository.swift` | the ledger's log and item reads page/chunk on the same total orders |
| `app/Sources/Morsel/SupabaseMenus.swift` | `listMenus` pages menus and chunks+paged menu items |
| `app/Tests/MorselTests/BoundedPagingTestSupport.swift`, `BoundedPagingFixtures.swift` | **new** — the capped PostgREST-shaped transport (row cap per response, `Content-Range`, recorded requests, fail/park/overlap plans) and its fixtures |
| `app/Tests/MorselTests/BoundedPagingTests.swift`, `BoundedPagingBoundaryTests.swift` | **new** — the AC1–AC5 regressions |
| `app/v1-journal-contract.test.ts` | the disclosed raw-token allowlist entry (above) |
| `app/Morsel.xcodeproj/project.pbxproj` | xcodegen output for the new files (regeneration is byte-stable) |
| `docs/evidence/issue-194-bounded-paging/` | this evidence |

Gate receipts: `GATES.md`. Machine-readable receipts: `native/run.json`.

# Issue #179 — native first paint mints no signed URLs (evidence)

The native read model minted a signed storage URL **per photo, awaited, before
publication** (`Repository.loadToday` → `mintMealImages` → one
`createSignedURL` request per row). Issue #179 removes URL minting from the
native read path: first paint attaches the **account-validated canonical
object path** only, and a URL is minted lazily, only if a consumer that
genuinely requires one calls for it.

- `app/Sources/Morsel/Repository.swift` — `loadToday` no longer awaits
  `mintMealImages`; it calls the new synchronous `mealImagePaths` (one line
  swap, #178's bounded concurrent graph untouched).
- `app/Sources/Morsel/SupabaseMealReadModel.swift` — new `mealImagePaths`
  (validates the stored path exactly like the download seam, attaches
  `MealImage(path:)` with no network work); `mintMealImages` is kept as the
  **lazy** URL-mint seam with its 15-minute TTL, documented as
  consumer-initiated and never called by the read graph.
- `app/Tests/MorselTests/NativeImageSigningTests.swift` — 6 focused tests
  (new file; `project.pbxproj` regenerated with `xcodegen generate`, +4 lines).
- `app/Sources/Morsel/MealThumbnail.swift` — **unchanged**: the loader already
  consumes the authenticated `loadMealImage(path:)` seam, which is exactly why
  first paint needs no URL. No photo-consumer file changed.

## How the claims are proven (real request seams, not fakes)

`app/Tests/MorselTests/StubSupabaseReadTransport.swift` (issue #178 support)
installs a `URLProtocol` transport at the real URLSession seam the production
`SupabaseClient` uses. `NativeImageSigningTests` registers a plan for the
stored photo object that **parks every request for it forever**: the signing
endpoint is deliberately blocked. Publication and every signing-call count are
asserted from the transport's recorded start/finish/cancel events — never from
sleeps or wall-clock guesses. The headline test waits at most 3 s for the
snapshot and asserts it arrived while the photo plan is still parked.

| Claim (issue AC) | Test | Mechanism |
| --- | --- | --- |
| Photo meal publishes text/totals while signing is blocked; zero signing calls | `testFirstPaintPublishesTextWhileEveryPhotoRequestIsBlocked` | photo plan parks forever; snapshot published, `signingStarts == 0`, `photoStarts == 0`, item ID/name/kcal + goal present, `image?.signedURL == nil` |
| Minting is lazy and consumer-initiated; the read path never calls it | `testLazyMintServesAUrlConsumerAndTheReadPathNeverMints` | legacy bucket-qualified row: read graph `signingStarts == 0`; direct `mintMealImages` call → exactly 1 signing request, URL + expiry returned |
| Today thumbnail / Edit photo keep authenticated, validated loads (canonical + legacy) | `testThumbnailAndEditLoadsDownloadThroughTheAuthenticatedPathSeam` | canonical and legacy bucket-qualified paths both `loadMealImage` → same bytes; 2 authenticated GETs, `signingStarts == 0` |
| Missing image degrades independently | `testMissingPhotoBytesDegradeWithoutHidingTextOrTotals` | download 404 → load throws; canonical path, meal text and kcal unaffected; `signingStarts == 0` |
| Forbidden/foreign path degrades independently; validation stays enforced | `testForeignPhotoPathKeepsTextAndRejectsTheDownload` | foreign-owner path → no image contract, no storage request, download seam throws; text/IDs/kcal stay |
| Replacement at the canonical path stays visible; no URL/byte cache mediates | `testPhotoReplacementAtTheCanonicalPathStaysVisibleWithoutAnyUrlCache` | same path, changed bytes: second load returns the new bytes, 2 GETs, `signingStarts == 0` |

### Signing-call counts (head vs audited base, same fixture)

| Scenario | base `ac1460d3` | head (this branch) |
| --- | --- | --- |
| `loadToday` with one photo meal, signing endpoint parked | 1 signing request started; snapshot **never published** (3 s bound) | 0 signing requests; snapshot published |
| Thumbnail/Edit loads for canonical + legacy paths | 3 photo requests (1 sign + 2 GETs); sign count 1 | 2 photo requests (0 sign + 2 GETs) |
| Direct consumer mint (lazy seam) after a read | read already mints 1, plus consumer mint | read mints 0, consumer mint 1 |

## RED → GREEN (behavioural, scratch copy)

Scratch tree `/tmp/morsel179-base` at base `ac1460d38e01dd726e8c96abee409e7ea41484a4`
with **the same test file** and a regenerated project; lane simulator
`C738A4B7-F157-4609-B2F4-F82D6B2E3717`, `HERDR_XCODEBUILD_DIRECT=1`,
`CODE_SIGNING_ALLOWED=NO`.

| Leg | Sources | Command | Raw exit | Result |
| --- | --- | --- | --- | --- |
| RED | base `ac1460d3` + new tests | `xcodebuild test … -only-testing:MorselTests/NativeImageSigningTests` | `redprobe=65` (`.lane-logs/red-probe-base.log`) | compiled; **6 tests, 12 failures (0 unexpected)** — publication blocked (`XCTAssertTrue failed - text/totals must publish while every photo request is parked`), `("1") is not equal to ("0")` for signing starts, unwrap of the never-published snapshot |
| GREEN (focused) | head | same focused command | `focused=0` (`.lane-logs/xcodebuild-focused.log`) | 6 tests, 0 failures |
| GREEN (full) | head | full suite, lane sim | `xcodebuild=0` (`.lane-logs/xcodebuild.log`) | **313 tests, 0 failures (0 unexpected)** |

The base failures are behaviour, not compile errors: the probe suite compiles
unchanged against base (`ac1460d3`) and fails because `loadToday` awaits one
signing request per photo before publishing.

## Native vs MCP boundary (explicit)

- **Native (`app/`)** — the read model carries `{path}` only; nothing on the
  Today/History first paint calls storage signing. Thumbnails and Edit/view
  photo read bytes through the authenticated, account-validated
  `loadMealImage(path:)` seam (`storage.from(bucket).download`). A signed URL
  is available lazily via `mintMealImages` for a consumer that requires one.
- **MCP/server (`server/**`, unchanged by this lane)** — `get_day` and the
  dashboard renders keep minting their own short-lived `signed_url` per read
  and keep returning `image: {path, signed_url, expires_at}` to agents
  (`server/supabase-repository.ts`; `server/meal-image.test.ts`,
  `server/meal-image-fail-soft.test.ts` — green in both npm runs). No public
  bucket, no server/DB/workflow change, `MealImage` stays schema-valid and the
  #133 contract shape is unchanged.

## Gate results (raw exits; logs under `.lane-logs/`, untracked)

| Gate | Command | Raw exit | Log |
| --- | --- | --- | --- |
| npm install | `npm ci --no-audit --no-fund` | `npmci=0` | `npm-ci.log` |
| TypeScript | `npm run typecheck` | `typecheck=0` | `typecheck.log` |
| ESLint | `npm run lint` | `lint=0` | `lint.log` |
| Hosted suite | `npm test` | `npmtest=1` | `npm-test.log` |
| Hosted suite, isolation | `npx vitest run --testTimeout=60000 <6 failing files>` | `isolated=1` | `npm-test-isolated.log` |
| Base control | base worktree + `npm ci` + `npm test` | `base_npmci=0`, `base_npmtest=1` | `base-control-npm-test.log` |
| SwiftLint strict | `cd app && swiftlint --strict` | `swiftlint=0` | `swiftlint.log` |
| Focused native | `xcodebuild test … -only-testing:MorselTests/NativeImageSigningTests` | `focused=0` | `xcodebuild-focused.log` |
| Full native | `xcodebuild test …` (full suite) | `xcodebuild=0` | `xcodebuild.log` |
| RED probe (base) | base scratch tree, focused | `redprobe=65` | `red-probe-base.log` |
| Flake isolation | `xcodebuild test … -only-testing:MorselTests/ParallelReadsTests` | `parallelonly=0` | `parallel-only.log` |

### `npm test` load-skew class (hosted suite, honest attribution)

`npmtest=1`: **12 failed / 544 passed (556)** — every failure is a per-test
timeout (`Test timed out in 5000/20000/30000ms`), **0 assertion failures**
(`rg -c AssertionError` exits 1). This is the repo-documented host-load class
(a moving set of heavy server suites times out while the host runs other
lanes' simulators). Re-running the six
failing files alone at 60 s: 56/58 pass; the two that still time out are
`db/postgres-integration.test.ts` (its own 30 s budget, local Postgres) and one
`scripts/migration-recovery.test.mjs` case (its own 20 s budget) — a
**different** migration-recovery case than the full run, i.e. the failing set
moves between runs. The pristine-base control (base `ac1460d3`, `npm ci`,
`npm test`) exited `base_npmtest=1`: 8 failed files, **15 failed / 520 passed /
21 skipped (556)**, 0 `AssertionError`, the same per-test timeout class — the
base is red under the same host load, with a different (larger) failing set.
No timeout, skip or assertion was weakened.

## Native run provenance

- Xcode 26.6, iOS 26.5 runtime, dedicated lane simulator `Morsel179-iPhone16`
  UDID `C738A4B7-F157-4609-B2F4-F82D6B2E3717`, unsigned Debug,
  `CODE_SIGNING_ALLOWED=NO`, `HERDR_XCODEBUILD_DIRECT=1` (herdr shim bypass),
  lane-local derived data `$HOME/Library/Developer/Xcode/DerivedData/Morsel179`
  (the machine default `/Volumes/NVMe2TB` is not mounted).
- Full suite: **313 tests, 0 failures**, raw `xcodebuild=0`. New suite alone:
  6 tests, 0 failures.
- Run history, disclosed: the first full-suite attempt wedged in
  `GoalsPolishTests` (documented fresh-sim class — log frozen, 0 % CPU for
  5+ min); it was killed and the wedged log kept at
  `.lane-logs/xcodebuild-wedged.log`. The second attempt aborted with
  `xcodebuild=65` because the host volume hit 100 % full (ENOSPC, "unable to
  write manifest"); no host simulators were deleted for this (the shutdown
  scratch sims of lanes #175/#176/#178 were already gone from the device set),
  only CoreSimulator log caches and this lane's own scratch trees were
  reclaimed. After reclaim the full suite passed.
- One full-suite attempt showed a single unexpected failure in the untouched
  `ParallelReadsTests.testHistoryAndGoalsContextOverlapAndKeepBaselineValues`
  (4 × 60 s URLSession timeouts on a parked stub request under host load);
  re-running that suite alone exited `parallelonly=0` (7/7) and the following
  full-suite run was green — classified as a load-sensitive flake in the #178
  suite, not caused by this diff (the diff does not touch History or the
  goals-context read graph).

## Not verified / boundaries

- Simulator/model evidence only: no physical-iPhone feel or HealthKit
  acceptance (tracker #172 retains it). No production performance claim — the
  evidence is request counts and bounded publication, not latency.
- The blocked-signing case is deterministic at the transport seam (a parked
  request stands in for an unreachable signing endpoint); it is not an
  over-the-air measurement against the live Supabase project.
- The replacement claim is proven at the model/seam layer (same path, new
  bytes, fresh authenticated GET per load, no signed URL involved). It does not
  claim SwiftUI re-render behaviour, which the current `.task(id: path)`
  identity keeps keyed on the canonical path.
- Physical first paint tap timing (the audit's original freeze report) is not
  reproduced here; this lane removes the audited blocking mechanism and proves
  the request-count consequence.
- `mintMealImages` is retained as the lazy mint seam (pinned by
  `app/photo-pipeline-contract.test.ts`, outside this lane's fence); nothing in
  the native read graph calls it.

NOT MERGED; not opened as PR; no deploy; no production writes.

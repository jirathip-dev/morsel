# Issue #288 — closed secondary-phrase tolerance for descriptive logged names

`satay skewers with peanut sauce` → `satay` and `olive oil / butter for cooking` →
`cooking oil`, without weakening a single required negative. The #260 contract
("a composite or shared plate is never attributed to a head food") is unchanged:
the new tolerance is a CLOSED policy, not an "ignore the tail" rule.

Base: `b5e64f3` (`origin/staging`, carries the merged #260 rule `1348994`).
Changed: `app/Sources/Morsel/FoodArtwork.swift` (the strip chain now consults the
new policy; `skewer(s)`/`drizzle(d)` join the closed serving-format words),
`app/Sources/Morsel/FoodArtworkSecondary.swift` (new: the policy),
`app/Tests/MorselTests/FoodArtworkMatcherClosureTests.swift` (new test class +
the shared coverage harness accepts this lane's corpus marker), and the
`xcodegen`-generated `app/Morsel.xcodeproj/project.pbxproj`.

## The policy (in-source: `FoodArtworkSecondary`)

Tolerated TRAILING classes — every one closed, positively enumerated:

1. **Serving format / container** (`skewers`, `slice`, `bowl`, `drizzle` …) — a
   word that names how an item is served, never a food.
2. **Accompaniment** — an attachment marker (`with`, `with a side of`,
   `on the side`, `topped with`, `served with`, `plus`, `and`, `&`, `+`) plus a
   phrase from the closed condiment/sauce/fat/garnish vocabulary (76 phrases:
   `peanut sauce`, `gravy`, `chili oil`, `butter`, `dressing`, `honey` …). Safe
   because the vocabulary is exhaustively listed and holds no dish noun.
3. **Purpose** — `for <use>` with a use from a closed non-food set
   (`for cooking`, `for dipping` …). Safe because it states the item's ROLE; a
   food cannot appear in it.
4. **Alternation** — `A / B`: the first component names the item, every remaining
   component must itself be an accompaniment or purpose.
5. Portion/size and quantity — the shipped #260 classes, unchanged.

Vetoed (fail closed to the neutral sign):

- any tail word outside the closed lists (`coffee with rice and chicken`: `rice`,
  `and`, `chicken` are none of them — the unbounded tail-drop #260 rejected);
- a tolerated phrase that names a catalog identity OUTSIDE the condiments class
  (a second dairy/protein/sweets/… identity means a shared plate, not a
  description: `cake with coffee`, `americano (black) with toast`);
- a head that never reaches a whole catalog name/alias (`chicken skewers`,
  `butter for cooking`, `skewers with peanut sauce`);
- two surviving identities (ordinary ambiguity) still resolve to neutral.

The accompaniment vocabulary was checked against the shipped catalog: no listed
phrase names a non-condiment identity (every phrase that IS an identity is a
condiments-class identity — `sauce`/`gravy` → Gravy, `chili oil` → Chili oil …).
The veto is therefore inert on today's catalog by construction and bites the
moment a listed phrase names a second identity — proved with a synthetic catalog
in `FoodArtworkSecondaryPhraseTests.testToleratedPhraseThatNamesASecondIdentityFailsClosed`
and by mutation M3.

## Executed evidence

See `gates.json` for raw exits and log paths, `mutation-battery.json` for the bite
proof, `named-results.json` for the case inventory and `coverage-aggregate.json`
for the corpus aggregates (aggregates only — no logged name is committed).

## Executed results

### RED → GREEN (native, one command, one class set)

Both legs use the same 11-class focused invocation (new class + the whole #260
matcher set + the shared coverage harness), one simulator at a time, lane scratch
`/tmp/rev288-dd`:

| leg | source state | result | raw exit | log (sha256) |
|---|---|---|---|---|
| `red-288-focused` | base resolver (`git stash push -- app/Sources/Morsel/FoodArtwork.swift`; sha256 `1e3517b4…` — byte-identical to the `resolver_sha256` pinned in the #260 coverage evidence) | `Executed 54 tests, with 14 failures` — **all** failures inside the new `FoodArtworkSecondaryPhraseTests` (`testClosedSecondaryPhrasesReachTheirHeadIdentity`, `testIssueRowsPaintTheirStudyInTheRealRowSeam`, `testToleratedPhraseThatNamesASecondIdentityFailsClosed`); every shipped #260 matcher test passed | 65 | `/tmp/rev288-logs/red-288-focused.log` `1208ef27…` |
| `green-288-focused` | head | `Executed 54 tests, with 0 failures` | 0 | `/tmp/rev288-logs/green-288-focused.log` |

### Required negatives, same executed run (AC3)

The GREEN leg also ran `FoodArtworkQualifierTests` (compound false friends:
`Coffee with rice and chicken` → neutral; `coffee cake` → cake, never coffee),
`FoodArtworkMatcherClosureTests` (milk tea ↔ boba tea separated both ways, `pad
thai` never the generic stir-fried noodles, unknown/composite/shared plate
neutral, malformed parentheticals neutral), `FoodArtworkFallbackTests`,
`FoodArtworkQualifierSurfaceTests`, `ArtworkIdentity*`, `RowArtworkRendererTests`
and `FoodLibraryIntegration*` — `0 failures` in the same invocation.

### Coverage at the shipped resolver (AC5)

Aggregates only; no logged name is committed or printed (provenance — path,
sha256, mtime, distinct count — in `coverage-aggregate.json`).

| corpus | base / delivered head | issue #288 head | delta |
|---|---|---|---|
| owner corpus N=250 (same snapshot as the #260 evidence, sha256 `76bf28f6…`) | specific 58 (23.2%) / labelled 1 (0.4%) / neutral 191 (76.4%) | specific **63 (25.2%)** / labelled 1 (0.4%) / neutral **186 (74.4%)** | +5 specific, −5 neutral |
| newer owner snapshot N=151 (`/tmp/m260/recent.json`, ephemeral, sha256 pinned in the JSON; contains both issue rows) | specific 43 / labelled 1 / neutral 107 | specific **46** / labelled 1 / neutral **104** | +3 specific, −3 neutral |

Per-name audit (base vs head dumps over both corpora, probe harness): every
changed name moved `neutral → a specific study`; **zero** names moved to a
different identity and zero resolutions were lost. The changed-name list is not
committed (raw logged names) — the counts above are the committed form.

### Mutation battery (bite proof, AC1/AC2)

Run on the committed head, each leg the same focused 5-class set, the source
restored byte-identically (`e62ddad4…`) after every leg — details in
`mutation-battery.json`:

| mutation | what it removes | observed (focused 5-class leg) | raw exit | log |
|---|---|---|---|---|
| **M1** — AC1/AC2's named mutation: `FoodArtworkSecondary.head` returns `nil` (whole-name/qualifier-only matching again) | the whole secondary tolerance | `Executed 33 tests, with 12 failures` — the three new cases RED (`testClosedSecondaryPhrasesReachTheirHeadIdentity`, `testIssueRowsPaintTheirStudyInTheRealRowSeam`, `testToleratedPhraseThatNamesASecondIdentityFailsClosed`); every shipped #260 matcher test GREEN | 65 | `/tmp/rev288-logs/mut-m1.log` |
| **M2** — accept ANY non-empty tail (drop the closed vocabulary) | the closed vocabulary (the veto #260 rejected) | `Executed 33 tests, with 28 failures` — `FoodArtworkQualifierTests.testCompoundFalseFriendsNeverBecomeTheirHeadFood` and `FoodArtworkMatcherClosureTests.testLeadingNegativeNamesNeverCrossIdentitiesInEitherDirection` / `testMalformedCrossFoodAndCompositeNamesStayNeutral` RED (the prior attempt's exact failure signature: `Coffee with rice and chicken` becomes `coffee`) | 65 | `/tmp/rev288-logs/mut-m2.log` |
| **M3** — `namesSecondIdentity` always `false` | the catalog-derived veto | `Executed 33 tests, with 1 failure` — exactly `testToleratedPhraseThatNamesASecondIdentityFailsClosed` RED; the shipped-catalog set stays GREEN (no listed accompaniment names a foreign identity), which is why the veto is proved with a synthetic catalog | 65 | `/tmp/rev288-logs/mut-m3.log` |

Infrastructure disclosure: the first M1 attempt wedged inside the documented
fresh-sim first-run class (`xcodebuild` at 0 % CPU, no log growth for 5 min); it
was killed (raw exit 143, log kept as `/tmp/rev288-logs/mut-m1-wedged.log`) and
retried once — the retry is the row above.

### Gates

| gate | command | raw exit | evidence |
|---|---|---|---|
| `swiftlint --strict` | `cd app && swiftlint lint --strict` | 0 | `Done linting! Found 0 violations, 0 serious in 182 files.` — `/tmp/rev288-logs/swiftlint-final.log` |
| `xcodegen` byte-stability | `cd app && xcodegen generate` re-run over the committed project, `cmp` before/after | 0 | regeneration is byte-identical to the project in the tree (no hand-edited project) — `/tmp/rev288-logs/pbxproj.idempotence.log` |
| whitespace | `git diff --cached --check` (staged lane diff) | 0 | `/tmp/rev288-logs/git-diff-check.log` |
| JS typecheck | `npm run typecheck` | 0 | `/tmp/rev288-logs/typecheck.log` |
| full JS suite | `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 npm test` | 1 | 3 failures, all `Test timed out in 5000ms` (`AssertionError` count 0) in `server/http.test.ts`, `server/render-png.test.ts`, `server/tool-classification.test.ts` under host load 21/135/171; the documented diagnostic rerun of exactly those three files passes 12/12 (raw exit 0, `/tmp/rev288-logs/npm-test-diagnostic.log`). No JS/TS/server file is touched by this diff — `/tmp/rev288-logs/npm-test.log` |
| native (base resolver) | 11-class focused leg | 65 | `/tmp/rev288-logs/red-288-focused.log` |
| native (head) | same 11-class focused leg | 0 | `/tmp/rev288-logs/green-288-focused.log` |

### Unfiltered native suite (one complete invocation)

`hermes-sim-task --name Morsel288-iPhone16 -- bash /tmp/rev288-native-gate.sh full-288`
→ `Executed 530 tests, with 2 tests skipped and 4 failures (0 unexpected)`,
**raw exit 65**, 912 s, log `/tmp/rev288-logs/full-288.log`. **Zero failures in any
artwork/matcher/library suite this diff touches.** The 4 failures are the SAME
three test cases that already fail at the base commit `b5e64f3`, reproduced in a
clean scratch worktree (`/tmp/rev288-base`, none of this lane's changes) with
`/tmp/rev288-native-gate-base.sh base-verify-288` → `Executed 17 tests, with 4
failures (0 unexpected)`, **raw exit 65**, 293 s, log
`/tmp/rev288-logs/base-verify-288.log` — identical assertion signature:

| test case | assertion (identical at base and at head) |
|---|---|
| `PageIdentityTests.testRevisitKeepsHistoryRangeExpandedDayAndScroll` | `XCTUnwrap failed: … the seed exposes a drill-down day` |
| `ParallelReadsTests.testFixtureDelayedEndpointsMeasureTheCriticalPathAndRequestCounts` | `("7") is not equal to ("6") … goals, profiles, weight, energy, logs, items` |
| `SharedButtonTargetTests.testAllProductionCallSitesPreserveTheVisualFootprintWithoutClipping` | `GoalsEditor.swift: compensate outside the Button…` + `("14") is not equal to ("13") action inventory` |

So the unfiltered suite is RED at `origin/staging` itself (pre-existing, outside
this lane's fence); this diff neither causes nor fixes it.

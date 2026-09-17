# Matcher closure evidence — issues #266 / #262 / #260

Branch: `issue/260-matcher-closure`. Base: `05e6314f2ebd107149c5be22f2b09f003e697948`.
Tested production/test code: `c63b37fc75180a27a2c02106f67d66b6634be3a5`.
Later commits package these receipts and public fixture images; no production source changes follow this test head.

## Part 1 — bounded class fix

- Leading and trailing qualifiers share the same closed descriptor/quantity grammar.
  This includes iced/hot/cooked/boiled/steamed/grilled/fried/raw, portion and size
  words, all existing trailing descriptors, and metric quantities. Hyphenated
  descriptors normalize inside the qualifier parser, not inside food names.
  Compound descriptors such as `small-portion` must contain only known descriptors.
- At most four successive edge removals; leading/trailing bare-edge checks inspect
  at most two space-delimited tokens. Unknown nouns, malformed parentheticals,
  cross-food synonyms and composites cannot be discarded to manufacture a match.
- A noun parenthetical is accepted only when both complete terms are names/aliases
  of the same asset: `pasta (linguine)` and the reverse, not `pasta (coffee)`.
  Synthetic catalog tests prove this is vocabulary-driven, not a special-case pasta table.
- A complete catalog name/alias wins before weaker reductions. This repairs the
  previously pinned `sausage slices` → neutral gap while preserving `fried egg` as
  its own identity. Competing whole matches still fail closed.
- The cooked-greens study resolves as the existing labelled Produce category, not
  an identified leaf variety. Catalog metadata/aliases and all asset bytes stay frozen.
- Existing explicit-ID precedence, unsupported-ID degradation, other-item artwork,
  and row-illustration/detail-photo rules remain covered. Legacy decoded item fields
  and photo paths are unchanged; no stored row rewrite is performed.

Changed files: `app/Sources/Morsel/FoodArtwork.swift`;
`app/Tests/MorselTests/{ArtworkIdentityTests,ArtworkIdentitySurfaceTests,FoodArtworkMatcherClosureTests,FoodLibraryIntegrationTests}.swift`;
`app/Morsel.xcodeproj/project.pbxproj`; this evidence directory.
The generated project includes the new test file and checkout-name-derived group IDs;
regenerating in this exact checkout now produces zero drift.
The old `pasta-gap` fixture now expects pasta; cooked-kale and alias/legacy compatibility
expectations now reflect the correct category and complete-alias behavior. Composite
fixtures use unique deterministic item IDs instead of duplicate ForEach identities.
No catalog, asset PNG, server, DB, schema, dependency or other production-view file changed.

## Regression discrimination

All legs used actual app-hosted XCTest on the same owned simulator, under `/tmp/n.lock`.
The base probe replaces only `FoodArtwork.swift` with the base Git blob; the leading
probe removes only `strippingLeadingQualifier(current) ??` from the fixed reducer.
Tests stay unchanged, compile, and fail by XCTest assertions, not launcher/build errors.

| Leg | Raw exit | Actual result |
|---|---:|---|
| Final focused artwork/coverage/capture invocation | 0 | 50 tests, 0 failures |
| Base grammar, new matcher tests | 65 | 8 tests, 207 assertion failures |
| Leading-rule disabled, new matcher tests | 65 | 8 tests, 176 assertion failures |
| Fixed source restored | 0 | 8 tests, 0 failures |
| Whole native wrapper | 0 | All expected legs completed; no timeout |

Both RED logs include `XCTAssertEqual failed` for `iced test dish, cooked`;
the base probe also rejects the new portion/synonym cases. The fixed/restored resolver
SHA-256 is `1e3517b4c588ad0c2196e168f98986040caced4efffe760c5eb82a7ec5481639`.
The restore is byte-verified and touched before the GREEN rebuild.
Exact commands, raw exits, durations and local log paths are in `gates.json`.

## Part 2 — rebuilt #266 AC4 run

The old ignored `.lane-tools/` driver was unavailable. `run-native.py` rebuilds the
attachment workflow described in `../issue-266-bundle-library/README.md`, reusing and
extending the committed production-row tests rather than inventing a renderer.
`FoodArtworkCatalog.bundled`, `FoodArtworkResolver.resolve(items:in:)`,
`JournalRowArtwork.resolve`, the production item rows, and the real edit sheet are
used in app-hosted, scene-backed windows. This is native component rendering, not
physical tap or authenticated live-device evidence.

There are **24 cases × 2 themes = 48 raw records / row captures**. A separate Today
initial-loading capture makes **49 #266 frames** (the old run had 45); two qualified-kale
detail captures bring this package to **51 native frames**. Two derived contact sheets
are previews, not extra captured frames. Every native PNG is 1179×2556 pixels, from
`Morsel260-Matcher-iPhone16`, UDID `61B0A2F6-1759-4A48-AC36-48F33791161D`.

Raw observations: `named-results.json` (only public issue/test fixtures), extracted
without changing desired identities or statuses from `ISSUE266_RESOLVER` output in
`.lane-logs/native-closure.log`. Paper and Night have the same resolutions:

| Public fixture input | Actual asset | Kind | Raw observation |
|---|---|---|---|
| `pork gravy` | `fallback-neutral` | neutral | FINDING |
| `pork with brown gravy` | `braised-pork` | food | PASS |
| `Chinese kale` | `stir-fried-greens` | category | PASS |
| `kana` | `stir-fried-greens` | category | PASS |
| `linguine` | `pasta` | food | PASS |
| `pasta (linguine), cooked` | `pasta` | food | PASS |
| `white rice` | `jasmine-rice` | food | PASS |
| `half-portion white rice` | `jasmine-rice` | food | PASS |
| `white rice, cooked (half portion)` | `jasmine-rice` | food | PASS |
| `Americano (black, no sugar, homemade)` | `coffee` | food | PASS |
| `Iced americano (black, no sugar)` | `coffee` | food | PASS |
| `coffee cake` | `cake` | food | PASS |
| `milk tea` | `milk-tea` | food | PASS |
| `boba tea` | `boba-tea` | food | PASS |
| `pad thai` | `pad-thai` | food | PASS |
| `stir-fried noodles` | `stir-fried-noodles` | food | PASS |
| `generic stir-fried noodles` | `fallback-neutral` | neutral | FINDING |
| `Uncatalogued lunar stew` | `fallback-neutral` | neutral | PASS |
| `composite/shared restaurant plate` | `fallback-neutral` | neutral | PASS |
| `white rice` + `braised pork` | `fallback-neutral` | neutral | PASS |
| `Dairy` | `fallback-dairy` | category | PASS |
| `Sweets` | `fallback-sweets` | category | PASS |
| `Prepared` | `fallback-prepared` | category | PASS |
| `Condiments` | `fallback-condiments` | category | PASS |

**44 PASS / 4 FINDING records** across both themes. The two retained findings per
theme are historical extra probes: `pork gravy` is not the approved `pork with brown
gravy` alias, and `generic stir-fried noodles` is not a complete approved alias.
Both remain neutral; neither is silently renamed or counted as an identification.
The latter still passes the required negative constraint (it does not become Pad thai).
All named required positives and wrong-identity negatives pass. The compound plate
keeps neutral summary artwork while its separately identified child foods retain art.

Visual inspection of both contact sheets confirms visible rice, pasta, pork, coffee,
cake, distinct milk/boba teas and Pad thai/noodles; neutral marks remain on the
unknown/shared cases. Long row names use the existing truncation; underlying names
and nutrition are not modified. The two detail captures show **Produce · fallback**
in Paper and Night. The longer category disclaimer is visibly ellipsized by the
existing UI; this lane does not claim the entire disclaimer is visible or alter that view.

`package-evidence.py` preserves the original attachment bytes, hashes every PNG,
colour-manages Display-P3 attachments into sRGB only for its analysis/contact sheets,
checks both theme grounds, and passes **54 pixel comparisons**. Positive aliases'
artwork regions equal their canonical controls; negative pairs differ; neutral
controls agree. Inventory, SHA-256 values and test/device attribution are in
`rendered-manifest.json`; comparison results are in `rendered-audit.json`.

### Today/performance limit (not hidden by the passing test)

`266-today-130.png` visibly shows the Today **loading skeleton**, not populated food
rows. It proves the mounted initial Today surface paints, not that loading completes.
The reused cost test measured warm catalog-load median **0.614 ms** and warm
Today mount/draw median **47.971 ms**, but the latter measures that initial/loading
surface. It is not a fresh cold-launch-to-populated-Today benchmark. No new A/B
performance delta was run. #266 AC5's complete performance acceptance remains
unverified by this lane; prior A/B figures are historical evidence only.

## Part 3 — real-name coverage

See `coverage.md` and `coverage-aggregate.json`. Actual shipped-resolver result:
**250 distinct names: 58 specific (23.2%), 1 category (0.4%), 191 neutral (76.4%),
0 none (0.0%)**. These are not the old estimator-layer percentages.
Coverage artifacts contain aggregates and corpus provenance only. No raw private
names, private per-name table, partial private name lists or corpus bytes are committed.
The public named fixtures above are separate from the private measurement.

## Exact commands and gates

No repository justfile exists. Commands ran from the named worktree root unless
noted; raw outputs and status receipts remain in ignored `.lane-logs/`.

| Command | Raw exit | Output / log |
|---|---:|---|
| `npm ci` | 0 | 256 packages added; `npm-ci.log` |
| `npm run typecheck` | 0 | `closure-typecheck.log` |
| `npm run lint` | 0 | `closure-lint.log` |
| `npm test` | 0 | **59 files / 669 tests passed**; `closure-npm.log` |
| `cd app && xcodegen generate` | 0 | `compound-xcodegen.log` |
| `git diff --exit-code -- app/Morsel.xcodeproj/project.pbxproj` | 0 | zero regeneration drift; `compound-drift.log` |
| `cd app && swiftlint --strict` | 0 | `compound-swiftlint.log` |
| `python3 docs/evidence/issue-266-bundle-library/verify-assets.py` | 0 | all 260 frozen PNGs, original 36 PNGs and 18 identities' metadata unchanged; `frozen-assets.log` |
| `python3 .lane-logs/verify-delivery.py` | 0 | aggregate-only coverage, public-fixture provenance, PNG hashes and file fence; `delivery-privacy-catalog-aware.log` |
| `git diff --check` | 0 | `closure-diff-check.log` |
| `git diff --cached --check` | 0 | staged new evidence included; `closure-staged-check.log` |
| `git diff --check 05e6314` | 0 | complete base-to-working-tree range; `closure-range-check.log` |
| `python3 docs/evidence/issue-260-matcher-closure/package-evidence.py` | 0 | 51 frames / 54 comparisons; `package-evidence.log` |

Native/coverage/mutation command (wrapper exit 0):

```sh
python3 docs/evidence/issue-260-matcher-closure/run-native.py --label native-closure --corpus /Users/jirathip/.herdr/worktrees/morsel/design-262-library-expansion/.lane-logs/logged-names.json --mutation
```

Expanded focused native command, from `app/` (raw exit 0):

```sh
xcodebuild test -project Morsel.xcodeproj -scheme Morsel -destination 'platform=iOS Simulator,id=61B0A2F6-1759-4A48-AC36-48F33791161D' -derivedDataPath /tmp/morsel-260-derived -resultBundlePath /tmp/morsel-260-native-closure.xcresult -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -jobs 2 CODE_SIGNING_ALLOWED=NO -only-testing:MorselTests/FoodArtworkMatcherClosureTests -only-testing:MorselTests/FoodArtworkFallbackTests -only-testing:MorselTests/FoodArtworkQualifierTests -only-testing:MorselTests/ArtworkIdentityTests -only-testing:MorselTests/ArtworkIdentitySurfaceTests -only-testing:MorselTests/FoodArtworkQualifierSurfaceTests -only-testing:MorselTests/RowArtworkRendererTests -only-testing:MorselTests/FoodLibraryIntegrationTests -only-testing:MorselTests/FoodLibraryCostTests -only-testing:MorselTests/FoodArtworkPrivateCoverageTests
```

The native driver records `pgrep -fl 'xcodebuild|xctest'` and `df -h /`, waits at
most 900 seconds for atomic `/tmp/n.lock` ownership, and uses `hermes-sim-task`
admission plus its own `/tmp/morsel-260-*` scratch. Final native preflight found no
matching native process (pgrep exit 1), and disk preflight exited 0. It bounds each
xcodebuild at 900 seconds, the native wrapper at 3000 seconds, cleans its path marker,
and releases only its own lock. No sibling was interrupted or admission bypassed.

### Earlier failures retained, not passed off as GREEN

- `npm-test.log`: raw 1 (HTTP/tool-classification 5-second timeouts). Unchanged-timeout
  isolation `npx vitest run server/http.test.ts server/tool-classification.test.ts`
  exited 0 (`npm-timeout-isolation.log`).
- `leading-npm-complete.log`: raw 1, 56 files passed / 3 failed, 664 tests passed /
  5 failed; all failures were 5000-ms timeouts in HTTP, PNG rasterization, and
  tool-classification. A separate foreground npm observation was interrupted by
  the tool deadline without a saved npm exit; it is not gate evidence.
- Final `closure-npm.log`: one complete unfiltered invocation at the fixed code
  head, raw 0, 669/669 passed. This supersedes the timeout runs; no timeout policy,
  test filter, dependency or server code was changed to obtain that result.
- Initial `native-focused.log` exited 65 on stale fixture expectations; those were
  corrected (neutral aliases are valid fallback matches; composite item IDs unique).
  `native-final.log` subsequently passed before the leading-grammar widening.
- `native-leading.log` exited 65 with 9 assertions on `small-portion` inputs.
  The compound-descriptor rule fixed that class; the current 50-test run passes.
- Initial SwiftLint strict runs exited 2 on long lines; the final run exits 0.
  `npm ci` reports 5 dependency vulnerabilities (4 moderate, 1 high), deprecated
  ESLint, and install-script approval advisories; no dependency edits were authorized.
  Packaging emitted a Pillow getdata deprecation warning; it still exited 0.
- The first privacy overlap diagnostic exited 1 because its public-provenance input
  omitted the already-published catalog. Including the base catalog (not a new name
  allowlist) removed those false positives; aggregate fields, fixture provenance,
  exact PNG hashes and file-scope checks then exited 0. Raw overlap diagnostics stay
  private in `.lane-logs/`, never in this evidence package.

Tooling: `ast-grep outline app/Sources/Morsel/FoodArtwork.swift` exited 0, identifying
FoodArtworkResolver and the match/qualifier/synonym/resolve methods. A later combined
outline of `ArtworkAliasMigrationTests.swift` and `ArtworkIdentityTests.swift` reported
that the first file does not exist and outlined the actual identity suite (combined
exit 0). No nonexistent migration suite is claimed; the executed
`testOldRowsCategoryAndMixedMealCompatibility` is in `ArtworkIdentityTests`.
File reads/edits used Hermes read_file/search_files/patch; ast-grep handled structural
questions, Python reduced receipts/counts, and terminal ran real gates and Git.

## AC-by-AC disposition (this lane, not blanket issue closure)

| Issue / AC | What this lane closes or leaves open |
|---|---|
| #266 AC1 | Revalidated 130 identities / 260 readable bundled PNGs via real build validator and artwork tests. Prior fail-closed mutation battery not rerun. |
| #266 AC2 | Re-proved approved catalog byte identity by hash comparison. |
| #266 AC3 | Re-proved original 36 PNGs and 18 identities' metadata unchanged. |
| #266 AC4 | Closed named required positives and negative identity separation with actual bundled resolver + both-theme production rows; two extra historical gaps retained above. |
| #266 AC5 | Resource hashes/bytes revalidated (this lane adds zero FoodArt resource bytes). Initial Today loading render/cost only; complete populated-Today launch/performance delta NOT verified here. |
| #266 AC6 | Closed named-case rendering: 48 both-theme row captures; details and loading frame separately identified. |
| #266 AC7 | Category resolution/labels tested; qualified greens detail shows Produce fallback in both themes. Row illustration/detail-photo policy preserved. |
| #266 AC8 | No server, DB or schema change in this lane. |
| #262 AC1 | Historical design batch/export/reproducibility acceptance not recreated. Required gap classes are now exercised against the shipped bundle. |
| #262 AC2 | Closed pork, greens and pasta matching/rendering gap; greens explicitly category-level. |
| #262 AC3 | Original-art byte identity re-proved. |
| #262 AC4 | No clean SVG/export rebuild performed; prior design reproducibility evidence not re-certified. |
| #262 AC5 | No design batches or owner approvals created/claimed by this lane. |
| #262 AC6 | Coverage report delivered against 250 real distinct logged names; pre-existing catalog has 120 food-kind entries / 130 total assets. Cooked greens is conservatively resolved as a category. |
| #262 AC7 | No artwork authored, third-party art or photos added. This authorized matcher follow-up necessarily changes Swift, unlike the original design-only lane. |
| #260 AC1 | Qualified rice resolves/renders in both themes; decoded food/nutrition/photo data unchanged. |
| #260 AC2 | Pasta and cooked-kale cases, plus approved pork/`moo ob` synonym grammar covered; only closed approved synonym forms, not arbitrary suffix text. |
| #260 AC3 | Required negative identities and mixed/unknown neutrality preserved; coffee cake may correctly use its own cake study, never coffee. |
| #260 AC4 | Descriptive Americano remains coffee; leading iced form also passes. |
| #260 AC5 | **UNVERIFIED**: no live production agent write/server readback/native-device chain was performed. Unit/render tests are not a substitute. |
| #260 AC6 | Closed by `coverage.md` with real shipped-resolver counts, percentages, N, command, mtime and hashes. |
| #260 AC7 | No runtime image generation or universal unique-food-art claim introduced. |

No unfiltered native suite, physical-device acceptance, live production-write proof,
new design approval or deployment is claimed. The requested focused native gate,
full npm gate, byte proof, bounded mutation proof and aggregate report are complete;
these do not authorize closing every criterion of the three parent issues.

NOT MERGED; not opened as PR; nothing pushed to staging or main; no deploy; no production writes.

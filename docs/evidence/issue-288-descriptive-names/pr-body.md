# fix(artwork): resolve a trailing condiment/purpose phrase so descriptive logged names find their studies (Refs #288)

Closes #288. `Satay skewers with peanut sauce` → `satay` and
`Olive oil / butter for cooking` → `cooking oil` at the shipped resolver, without
weakening a single required negative.

## The policy (closed, never "drop the tail")

Tolerated TRAILING classes — each one closed and positively enumerated
(in-source: `FoodArtworkSecondary`):

1. **Serving format / container** — `skewers`, `slice(s)`, `bowl`, `drizzle` …:
   a word that names how an item is served, never a food.
2. **Accompaniment** — an attachment marker (`with`, `with a side of`,
   `on the side`, `topped with`, `served with`, `plus`, `and`, `&`, `+`) plus a
   phrase from the closed condiment/sauce/fat/garnish vocabulary (76 phrases:
   `peanut sauce`, `gravy`, `chili oil`, `butter`, `dressing`, `honey`, …).
   Safe: a sauce, seasoning or cooking fat served alongside is not the dish, and
   the vocabulary is exhaustively listed and holds no dish noun.
3. **Purpose** — `for <use>` from a closed non-food set (`for cooking`,
   `for dipping`, …). Safe: it states the item's ROLE; no food can appear there.
4. **Alternation** — `A / B`: the first component names the item, every remaining
   component must itself be an accompaniment or purpose. Safe: the `/` asserts
   the writer means the same thing twice, and the remaining components stay
   inside classes 2–3.
5. Portion/size and quantity — the shipped #260 classes, unchanged.

Vetoed (the name keeps its whole, unresolved meaning → neutral sign):

- **any tail word outside these closed lists** — this is what refuses the
  generic-ingredient compound `coffee with rice and chicken` (`rice`, `and`,
  `chicken` are none of them); the unbounded tail-drop is exactly what #260
  rejected and what this policy does not reintroduce;
- **a tolerated phrase that names a catalog identity outside the condiments
  class** (`cake with coffee`, `americano (black) with toast`, `som tum with
  peanuts`): a second dairy/protein/sweets/… identity means a shared plate, not
  a description of the first item;
- **a head that never reaches a whole catalog name/alias** (`chicken skewers`,
  `butter for cooking`, `skewers with peanut sauce`);
- **two surviving identities** — ordinary ambiguity still resolves to neutral.

The accompaniment vocabulary was checked against the shipped catalog: no listed
phrase names a non-condiment identity (every listed phrase that IS a catalog
identity is a condiments-class identity — `sauce`/`gravy` → Gravy,
`chili oil` → Chili oil). The veto is therefore inert on today's catalog **by
construction**, and bites the moment a listed phrase names a second identity —
proved by a synthetic-catalog test and mutation M3.

Precedence is unchanged: whole names/aliases win first (`coffee cake` → cake,
`iced americano` → iced coffee), the parenthetical/comma branches still fail
closed before the new step, and no catalog/asset byte, alias or schema changed.

## Evidence

- **Native RED/GREEN pair, one command, same 11-class set**: base resolver
  (`1e3517b4…`, the #260 evidence pin) `Executed 54 tests, with 14 failures`
  (raw exit 65) — every failure inside the new
  `FoodArtworkSecondaryPhraseTests`; head `Executed 54 tests, with 0 failures`
  (raw exit 0). The whole #260 matcher set ran in the same invocation, negatives
  green.
- **Bite proof**: mutation battery on the committed head — whole-name/
  qualifier-only (M1), unbounded tail / no closed vocabulary (M2), no
  catalog-derived veto (M3).
- **Coverage at the shipped resolver** (owner corpus N=250, same corpus as the
  delivered head's published numbers): specific 58 (23.2%) → **63 (25.2%)**,
  labelled 1 → 1, neutral 191 → **186 (74.4%)**; every changed name moved
  `neutral → a specific study`, none to a different identity. A newer owner
  snapshot (N=151, includes both issue rows) moves specific 43 → 46.
- **One complete unfiltered native suite**: `Executed 530 tests, with 2 tests
  skipped and 4 failures` (raw exit 65) — zero failures in any artwork/
  matcher/library suite; the 4 failures are the same three test cases that
  already fail at the base commit `b5e64f3` in a clean scratch worktree
  (`PageIdentityTests`, `ParallelReadsTests`, `SharedButtonTargetTests`),
  i.e. pre-existing on `origin/staging` and outside this fence.
- Gates: `swiftlint lint --strict` 0 violations; `xcodegen generate`
  byte-identical; `git diff --check` clean; `npm run typecheck` exit 0;
  `npm test` exit 1 with three 5000 ms timeouts (`AssertionError` count 0)
  whose files pass 12/12 on the diagnostic rerun. Logs and raw exits in
  `docs/evidence/issue-288-descriptive-names/`.

## Files

- `app/Sources/Morsel/FoodArtworkSecondary.swift` (new policy + vocabularies)
- `app/Sources/Morsel/FoodArtwork.swift` (strip chain consults the policy; four
  serving-format words; header)
- `app/Tests/MorselTests/FoodArtworkMatcherClosureTests.swift`
  (`FoodArtworkSecondaryPhraseTests`; the shared coverage harness accepts this
  lane's corpus marker)
- `app/Morsel.xcodeproj/project.pbxproj` (xcodegen-generated)
- `docs/evidence/issue-288-descriptive-names/` (evidence)

NOT MERGED; no TestFlight dispatch; no live acceptance.

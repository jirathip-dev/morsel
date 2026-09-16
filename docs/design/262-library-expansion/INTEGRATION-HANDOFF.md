# Integration handoff — design scope only

No bundling, asset-catalog wiring, Swift, DB, schema or matcher changes are part of this branch. Candidate art is not production art until the owner approves it and an implementation lane integrates it.

## Library boundaries

- `library/catalog.json` is a cumulative **candidate** library. Source/master/export paths are relative to `library/`.
- The original 18 catalog entries are copied as exact JSON values, with their original names, aliases, categories and provenance. Their actual art bytes, shared wash and fonts are hash-locked.
- Original `docs/art/food-library-v2/catalog.json` and `app/Resources/FoodArt/` are untouched. No alias additions to `toast` or `vegetable-soup` from the round-1 proposal have been silently applied.
- The exact candidate acceptance set is derived from the approved list and five approved labeled fallback IDs, never from whatever files happen to exist.
- Newly introduced categories: dairy, sweets, prepared, condiments. A later implementation must provide labels and test unknown-category behavior; this lane does not change `FoodArtwork.swift`.

## Names and matching

The proposal alias lists are retained verbatim on the new identities. The round-1 validator checks duplicate IDs and full-name/alias collisions against the shipped catalog. That check is not a substitute for the runtime resolver.

The #260 reference branch explicitly uses exact ID membership, unambiguous normalized names/aliases and a bounded qualifier grammar—not arbitrary substring or ingredient matching. The coverage estimator is broader and is labeled as an estimate throughout this handoff. Do not use its 92.0% figure as evidence that the shipped matcher resolves those rows.

The public issue examples map, at the design-catalog/estimator layer, to:

- pork with brown gravy → `braised-pork`
- Chinese kale / kana → `stir-fried-greens` (generic cooked-greens class; no claim to distinguish leaf variety)
- linguine → `pasta` (generic long-strand class; not a sauce/recipe claim)
- white rice → unchanged `jasmine-rice`
- Americano → unchanged `coffee`

A bundling lane should run these cases through the actual resolver with the candidate catalog, and also test exact IDs, qualified names, unknown foods, composite/shared plates, `coffee cake` versus coffee, milk tea versus boba tea, and pad thai versus generic stir-fried noodles. Prefer an explicit stable artwork identity from the logging agent when available. Ambiguity must retain an honest labeled-category or neutral result, not guess a single ingredient.

## Batch 5 honesty

All 12 promoted identities are for general coverage and have **0 observed rows resolved to those identities in this account's frozen evidence window**. A historical ingredient mention under a different food (for example a squid nigiri row resolved to sushi) is not observed demand for a dedicated squid study. The owner explicitly superseded the old reserve prose.

Dedicated `pad-thai` and `boba-tea` art is justified by their durable visual cues and a generic labeled reading, not by a claim about actual logged ingredients. The batch-5 report records the final depiction decision. Aliases on shipped identities remain unchanged regardless of that decision.

## Privacy and acceptance

Raw account names and row-level mappings remain only in the original untracked `.lane-logs/`. The public evidence contains approved generic vocabulary, the issue's already-public examples and aggregate counts. No credentials or query scripts are copied.

Mechanical validity, visual judgment and owner approval are separate. Do not promote these assets merely because the SHA/DOM gates pass. After asset approval, the implementation lane owns native loading, theme resolution, actual 64px placement, catalog schema/version compatibility, resolver behavior and app tests.

DESIGN ARTIFACTS ONLY; no app/DB edits; not merged; not opened as PR; no deploy.

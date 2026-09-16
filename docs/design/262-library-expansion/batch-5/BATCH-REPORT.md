# Issue 262 · batch 5

DESIGN ARTIFACTS ONLY — subject list approved; final pixels await owner review. No per-batch stop (owner decision); no app integration or rollout.

## Delivered

12 new food identities. Cumulative candidate: **120 foods**, 10 fallback signs; 130 assets total. Shipped baseline is 13 foods plus five fallbacks (including neutral), not 14 foods.

- `pancake` — Pancakes (grains; food)
- `croissant` — Croissant (grains; food)
- `bacon` — Bacon (protein; food)
- `sausage` — Sausage (protein; food)
- `peanuts` — Peanuts (protein; food)
- `ramen` — Ramen (grains; food)
- `donut` — Donut (sweets; food)
- `chicken-wings` — Chicken wings (protein; food)
- `grilled-squid` — Grilled squid (protein; food)
- `khanom-jeen` — Khanom jeen (grains; food)
- `pad-thai` — Pad thai (prepared; food)
- `boba-tea` — Boba tea (drinks; food)

## Proofs

- [Paper contact sheet](contact-paper.png) / [Night contact sheet](contact-night.png)
- [Both themes at native 64px and diagnostic 40px](optical-both.png)
- [Paper phone strip](proofs/phone-all-paper.png) / [Night phone strip](proofs/phone-all-night.png)
- [Interactive Paper gallery](gallery-paper.html) / [Night gallery](gallery-night.html)
- [Catalog delta](catalog-delta.json), [subjects](subjects.json), [build cache](build-cache.json), [SHA-256 manifest](SHA256SUMS.json)

Phone proof pages: 3 cohorts per theme, 390×844 CSS/device pixels, every new ID at exactly 64×64 pixels. Layout is fictional and labeled; not a screenshot of deployed/native Morsel. 40px is diagnostic only.

## Coverage — observed data versus general coverage

All 12 are **evidence-free for this account: 0 observed rows**. General coverage for other users only; not observed-demand items. The historical proposal's ingredient-level mention for grilled squid did not resolve to this identity; it was sushi. Owner amendment supersedes reserve/demand prose in the frozen reference.

Frozen observation window: 250 distinct names / 284 rows. The estimate uses the approved round-1 qualifier-tolerant estimator, **not the shipped #260 resolver**. Private local aggregate was recomputed for this delivery; raw names never enter this bundle.

| Partition | Distinct names | Rows |
|---|---:|---:|
| Specific studies now available | 230 (92.0%) | 264 (93.0%) |
| Labeled category fallback | 20 | 20 |
| Neutral | 0 | 0 |
| Specific study pending a later batch | 0 | 0 |

This batch changes estimated specific coverage by 0 distinct names / 0 rows. Pending-later entries are shown explicitly so the partition closes; they are not silently presented as covered. The named pork-gravy / Chinese-kale / linguine classes have specific studies from batch 1. Rice and coffee reuse their unchanged shipped studies. Actual runtime matching remains an implementation-lane check.

## Alias versus dedicated study — honesty decision

- `pad-thai`: dedicated generic study, with orange flat strands, a lime wedge, sprouts and restrained peanut/shrimp cues. Those durable cues honestly distinguish the named dish from the shipped generic stir-fried-noodles bowl. Its label, not the image alone, names the class; it makes no assertion about a logged recipe, protein, portion or allergy. No shipped aliases changed.
- `boba-tea`: dedicated pearl-focused clear-cup study, broad straw and visible bottom pearl mass. The earlier `milk-tea` study depicts orange Thai-style tea and keeps its approved `bubble tea` alias. This overlap is intentional generic coverage, not a claim of perfect name disambiguation. A future matcher/bundling lane must retain exact-ID/name priority and test both names. No shipped identities or aliases were rewritten.

Both decisions use recognizable, honest generic depictions rather than reduced authoring effort.

## Executed verification

- Asset gate: PASS, raw exit 0. Closed-set IDs, source/master parity, locked palette, transparent RGBA dimensions, border/alpha checks, cache output hashes.
- Shipped preservation: 18 identities × nine art files = 162 before/after SHA-256 comparisons; full product baseline covers 534 files (shipped art/docs plus app/DB/schema). Each pair is recorded in [shipped-18-before-after.json](shipped-18-before-after.json). Original catalog entries, aliases, fonts and shared wash are unchanged.
- Clean rebuild: PASS, raw exit 0; **96** new master/export files recreated in fresh scratch without cache, byte-identical SHA-256. See [reproducibility.json](reproducibility.json).
- Browser gate: PASS; 10 actual Chromium screenshots with image/font load, console, no-overflow, 44px links, all-row visibility, exact 64px placement and all-ID/both-theme coverage. See [browser.json](browser.json).
- Public-package private-name scan and manifests: see `privacy.json` and `SHA256SUMS.json` after final packaging.
- Visual judgment: see `VISUAL-REVIEW.md`; mechanical passes are not owner approval.

## Reproduce / limitations

See [root README](../README.md). New source SVGs are original agent-authored on gpt-6-astra. Exact clean export bytes depend on the pinned recorded librsvg/cairo environment; no runtime generation. Historical raw observations are private, so public clones can verify aggregate hashes but cannot independently requery account history. Shipped pixels and app resources are never regenerated or wired by this pipeline.

DESIGN ARTIFACTS ONLY; no app/DB edits; not merged; not opened as PR; no deploy.

## Repository gate caveat

See [HOST-GATES.md](../HOST-GATES.md). npm ci, typecheck, lint and diff-check exited 0. The one npm test invocation exited 1: 583 passed / 2 failed, both 5000ms timeouts in unchanged server files, plus two worker timeouts. No retries, timeout changes, skipped tests or hosted-CI success claim. Asset/browser/rebuild gates above are separate from that raw aggregate result.

# Issue 262 · batch 3

DESIGN ARTIFACTS ONLY — subject list approved; final pixels await owner review. No per-batch stop (owner decision); no app integration or rollout.

## Delivered

24 new food identities. Cumulative candidate: **85 foods**, 10 fallback signs; 95 assets total. Shipped baseline is 13 foods plus five fallbacks (including neutral), not 14 foods.

- `fried-rice` — Fried rice (prepared; food)
- `basil-stir-fry` — Basil stir-fry (prepared; food)
- `omelette` — Omelette (protein; food)
- `fried-chicken` — Fried chicken (protein; food)
- `pizza-slice` — Pizza slice (prepared; food)
- `sandwich` — Sandwich (prepared; food)
- `focaccia` — Focaccia (grains; food)
- `instant-noodles` — Instant noodles (grains; food)
- `roti` — Roti (grains; food)
- `mashed-potato` — Mashed potato (produce; food)
- `cooking-oil` — Cooking oil (condiments; food)
- `raw-vegetable-plate` — Raw vegetable plate (produce; food)
- `mixed-nuts` — Mixed nuts (protein; food)
- `shabu-slices` — Thin-sliced meat (protein; food)
- `beef-rice-bowl` — Beef rice bowl (prepared; food)
- `protein-shake` — Protein shake (drinks; food)
- `apple` — Apple (produce; food)
- `pomelo` — Pomelo (produce; food)
- `cucumber` — Cucumber (produce; food)
- `kimchi` — Kimchi (produce; food)
- `mushrooms` — Mushrooms (produce; food)
- `shrimp` — Shrimp (protein; food)
- `stewed-duck` — Stewed duck (protein; food)
- `cake` — Cake (sweets; food)

## Proofs

- [Paper contact sheet](contact-paper.png) / [Night contact sheet](contact-night.png)
- [Both themes at native 64px and diagnostic 40px](optical-both.png)
- [Paper phone strip](proofs/phone-all-paper.png) / [Night phone strip](proofs/phone-all-night.png)
- [Interactive Paper gallery](gallery-paper.html) / [Night gallery](gallery-night.html)
- [Catalog delta](catalog-delta.json), [subjects](subjects.json), [build cache](build-cache.json), [SHA-256 manifest](SHA256SUMS.json)

Phone proof pages: 5 cohorts per theme, 390×844 CSS/device pixels, every new ID at exactly 64×64 pixels. Layout is fictional and labeled; not a screenshot of deployed/native Morsel. 40px is diagnostic only.

## Coverage — observed data versus general coverage

Observed and zero-observed additions are separately listed in `coverage.json`. This is not a claim that every new identity was logged.

Frozen observation window: 250 distinct names / 284 rows. The estimate uses the approved round-1 qualifier-tolerant estimator, **not the shipped #260 resolver**. Private local aggregate was recomputed for this delivery; raw names never enter this bundle.

| Partition | Distinct names | Rows |
|---|---:|---:|
| Specific studies now available | 225 (90.0%) | 259 (91.2%) |
| Labeled category fallback | 20 | 20 |
| Neutral | 0 | 0 |
| Specific study pending a later batch | 5 | 5 |

This batch changes estimated specific coverage by 24 distinct names / 25 rows. Pending-later entries are shown explicitly so the partition closes; they are not silently presented as covered. The named pork-gravy / Chinese-kale / linguine classes have specific studies from batch 1. Rice and coffee reuse their unchanged shipped studies. Actual runtime matching remains an implementation-lane check.

## Executed verification

- Asset gate: PASS, raw exit 0. Closed-set IDs, source/master parity, locked palette, transparent RGBA dimensions, border/alpha checks, cache output hashes.
- Shipped preservation: 18 identities × nine art files = 162 before/after SHA-256 comparisons; full product baseline covers 534 files (shipped art/docs plus app/DB/schema). Each pair is recorded in [shipped-18-before-after.json](shipped-18-before-after.json). Original catalog entries, aliases, fonts and shared wash are unchanged.
- Clean rebuild: PASS, raw exit 0; **192** new master/export files recreated in fresh scratch without cache, byte-identical SHA-256. See [reproducibility.json](reproducibility.json).
- Browser gate: PASS; 14 actual Chromium screenshots with image/font load, console, no-overflow, 44px links, all-row visibility, exact 64px placement and all-ID/both-theme coverage. See [browser.json](browser.json).
- Public-package private-name scan and manifests: see `privacy.json` and `SHA256SUMS.json` after final packaging.
- Visual judgment: see `VISUAL-REVIEW.md`; mechanical passes are not owner approval.

## Reproduce / limitations

See [root README](../README.md). New source SVGs are original agent-authored on gpt-6-astra. Exact clean export bytes depend on the pinned recorded librsvg/cairo environment; no runtime generation. Historical raw observations are private, so public clones can verify aggregate hashes but cannot independently requery account history. Shipped pixels and app resources are never regenerated or wired by this pipeline.

DESIGN ARTIFACTS ONLY; no app/DB edits; not merged; not opened as PR; no deploy.

## Repository gate caveat

See [HOST-GATES.md](../HOST-GATES.md). npm ci, typecheck, lint and diff-check exited 0. The one npm test invocation exited 1: 583 passed / 2 failed, both 5000ms timeouts in unchanged server files, plus two worker timeouts. No retries, timeout changes, skipped tests or hosted-CI success claim. Asset/browser/rebuild gates above are separate from that raw aggregate result.

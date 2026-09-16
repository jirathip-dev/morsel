# Issue 262 · batch 1

DESIGN ARTIFACTS ONLY — subject list approved; final pixels await owner review. No per-batch stop (owner decision); no app integration or rollout.

## Delivered

24 new food identities, plus five approved labeled category fallbacks. Cumulative candidate: **37 foods**, 10 fallback signs; 47 assets total. Shipped baseline is 13 foods plus five fallbacks (including neutral), not 14 foods.

- `sweet-potato` — Sweet potato (produce; food)
- `yogurt` — Yogurt (dairy; food)
- `berries` — Berries (produce; food)
- `boiled-egg` — Boiled egg (protein; food)
- `egg` — Egg (protein; food)
- `sticky-rice` — Sticky rice (grains; food)
- `braised-pork` — Braised pork (protein; food)
- `stir-fried-greens` — Stir-fried greens (produce; food)
- `pasta` — Pasta (grains; food)
- `sourdough-bread` — Sourdough bread (grains; food)
- `cereal-flakes` — Cereal flakes (grains; food)
- `smoothie` — Smoothie (drinks; food)
- `cheese` — Cheese (dairy; food)
- `ice-cream` — Ice cream (sweets; food)
- `grilled-pork` — Grilled pork (protein; food)
- `grilled-beef` — Grilled beef (protein; food)
- `steamed-fish` — Steamed fish (protein; food)
- `hot-pot` — Hot pot (soup; food)
- `tom-yum` — Tom yum (soup; food)
- `noodle-soup` — Noodle soup (grains; food)
- `nam-jim` — Dipping sauce (condiments; food)
- `wrap` — Wrap (prepared; food)
- `chicken-rice` — Chicken rice (prepared; food)
- `milk` — Milk (dairy; food)
- `fallback-soup` — Soup · fallback (soup; fallback)
- `fallback-dairy` — Dairy · fallback (dairy; fallback)
- `fallback-sweets` — Sweets · fallback (sweets; fallback)
- `fallback-prepared` — Prepared · fallback (prepared; fallback)
- `fallback-condiments` — Condiments · fallback (condiments; fallback)

## Proofs

- [Paper contact sheet](contact-paper.png) / [Night contact sheet](contact-night.png)
- [Both themes at native 64px and diagnostic 40px](optical-both.png)
- [Paper phone strip](proofs/phone-all-paper.png) / [Night phone strip](proofs/phone-all-night.png)
- [Interactive Paper gallery](gallery-paper.html) / [Night gallery](gallery-night.html)
- [Catalog delta](catalog-delta.json), [subjects](subjects.json), [build cache](build-cache.json), [SHA-256 manifest](SHA256SUMS.json)

Phone proof pages: 6 cohorts per theme, 390×844 CSS/device pixels, every new ID at exactly 64×64 pixels. Layout is fictional and labeled; not a screenshot of deployed/native Morsel. 40px is diagnostic only.

## Coverage — observed data versus general coverage

Observed and zero-observed additions are separately listed in `coverage.json`. This is not a claim that every new identity was logged.

Frozen observation window: 250 distinct names / 284 rows. The estimate uses the approved round-1 qualifier-tolerant estimator, **not the shipped #260 resolver**. It is recomputed from the private local aggregate at delivery; raw names never enter this bundle.

| Partition | Distinct names | Rows |
|---|---:|---:|
| Specific studies now available | 138 (55.2%) | 171 (60.2%) |
| Labeled category fallback | 20 | 20 |
| Neutral | 0 | 0 |
| Specific study pending a later batch | 92 | 93 |

This batch changes estimated specific coverage by 112 distinct names / 132 rows. Pending-later entries are shown explicitly so the partition closes; they are not silently presented as covered. The named pork-gravy / Chinese-kale / linguine classes have specific studies from batch 1. Rice and coffee reuse their unchanged shipped studies. Actual runtime matching remains an implementation-lane check.

## Executed verification

- Asset gate: PASS, raw exit 0. Closed-set IDs, source/master parity, locked palette, transparent RGBA dimensions, border/alpha checks, cache output hashes.
- Shipped preservation: 18 identities × nine art files = 162 before/after SHA-256 comparisons; full product baseline covers 534 files (shipped art/docs plus app/DB/schema). Each pair is recorded in [shipped-18-before-after.json](shipped-18-before-after.json). Original catalog entries, aliases, fonts and shared wash are unchanged.
- Clean rebuild: PASS, raw exit 0; **232** new master/export files recreated in fresh scratch without cache, byte-identical SHA-256. See [reproducibility.json](reproducibility.json).
- Browser gate: PASS; 16 actual Chromium screenshots with image/font load, console, no-overflow, 44px links, all-row visibility, exact 64px placement and all-ID/both-theme coverage. See [browser.json](browser.json).
- Public-package private-name scan and manifests: see `privacy.json` and `SHA256SUMS.json` after final packaging.
- Visual judgment: see `VISUAL-REVIEW.md`; mechanical passes are not owner approval.

## Reproduce / limitations

See [root README](../README.md). New source SVGs are original agent-authored on gpt-6-astra. Exact clean export bytes depend on the pinned recorded librsvg/cairo environment; no runtime generation. Historical raw observations are private, so public clones can verify aggregate hashes but cannot independently requery account history. Shipped pixels and app resources are never regenerated or wired by this pipeline.

DESIGN ARTIFACTS ONLY; no app/DB edits; not merged; not opened as PR; no deploy.

## Repository gate caveat

See [HOST-GATES.md](../HOST-GATES.md). npm ci, typecheck, lint and diff-check exited 0. The one npm test invocation exited 1: 583 passed / 2 failed, both 5000ms timeouts in unchanged server files, plus two worker timeouts. No retries, timeout changes, skipped tests or hosted-CI success claim. Asset/browser/rebuild gates above are separate from that raw aggregate result.

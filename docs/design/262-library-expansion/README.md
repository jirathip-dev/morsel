# Morsel · issue 262 · ink/wash library expansion

Surface: **Compare**. Additive candidate artwork, not an application redesign.

Owner-approved subject list: `88b8d4df7978254d2f0fb0297b8b60bc67153e57`.
- [Production / no per-batch stop](https://github.com/jirathip-dev/morsel/issues/262#issuecomment-5690697676)
- [Batch 5 promotion](https://github.com/jirathip-dev/morsel/issues/262#issuecomment-5690755910)

The immutable `references/subjects-proposed.json` contains historical reserve/status text. The decisions above supersede it: produce batches **1 → 5**, sequentially, without an owner stop between batches. Final pixels are **not yet owner-approved**. Batch 5 is general coverage only: all 12 subjects are evidence-free for this account, **0 observed rows**. No observed-demand claim is made for that batch.

## Review

Open `index.html`; each batch has a separate `BATCH-REPORT.md`, Paper/Night contacts, 64px placement / 40px diagnostic proof, all-ID labeled phone contexts, catalog delta, coverage, clean-build comparisons and SHA-256 manifest.

- Canonical working bundle: `/Users/jirathip/design-output/morsel/262-library-expansion/`
- Product-branch evidence mirror: `docs/design/262-library-expansion/`
- Review gallery: https://jirathips-macbook-air.tail8c3301.ts.net:8444/morsel/262-library-expansion/index.html
- Private archive: https://github.com/jirathip-dev/design-output/tree/main/morsel/262-library-expansion

The product mirror is documentation/artwork only. `docs/art/food-library-v2/`, `app/**`, Swift, database and schema files remain untouched. The original 18 entries are 13 foods plus five fallback signs, including neutral. Their exact source/master/export bytes and identity metadata are copied unchanged into the candidate library. Candidate metadata uses schema 2 / `2.2.0-candidate-bN`; this is not a bundled production version.

Batches contain 24 / 24 / 24 / 23 / 12 new foods. Five approved labeled category fallbacks accompany batch 1. After all five, the target is 120 food identities, excluding fallback signs; machine evidence gives the actual delivered count.

## Locked design system

Authority: `references/shipped-ART-SPEC.md`. Palette, seeded wash filters, font bytes and theme logic are unchanged. Original organic ink/wash SVG drawing only; no third-party food artwork, raster source, stock, scans, photos, AI diffusion, runtime generation or nutrition claims. New art is authored on gpt-6-astra, not the fallback model used for round-1 list preparation.

Paper `#FFF7E8`, Night `#2A261F`; selective line `#8B7355` / `#9D917F`; approved cream, sage, leaf, forest, orange, peach, red, gold, ochre and brown ingredients. Historical proposal hue words such as blue/purple/silver do not authorize new tokens. These hues are interpreted through the locked warm pigments. EB Garamond labels, Caveat headings, IBM Plex Mono technical notes. Flat grids and hairlines, no card chrome, shadows, decorative gradients or animation.

Original `skills/food-art` compiler/validator files are retained byte-for-byte under `scripts/vendor/`, with provenance hashes. The issue-223 closed-set gate is not relaxed. This package has a separate issue-262 closed-set gate over the approved list and per-batch acceptance sets.

## Reproduction

Requirements already available on the authoring host: Python 3 + Pillow, `rsvg-convert`, a Chromium headless shell. Exact renderer versions are recorded per batch. No install, network service, account credentials or API keys are required to generate art/proofs. The browser uses fresh owned profiles. Font/OFL files are included.

Run from this bundle. The command derives `N` as the highest delivered batch (so the full-library closed-set verification matches all retained sources). To independently reproduce earlier art, use `pipeline.py reproduce --batch N` for each earlier N without shrinking the cumulative catalog. Execute the batches in order when rebuilding cumulative catalog metadata; earlier source/master/export bytes are retained. No script writes the production library or app resources.

```sh
export PYTHONDONTWRITEBYTECODE=1
N=$(python3 -c 'import json; from pathlib import Path; print(max(int(p.parent.name.split("-")[1]) for p in Path(".").glob("batch-*/catalog-delta.json")))')
python3 scripts/pipeline.py build --batch "$N"
python3 scripts/pipeline.py coverage --batch "$N"
python3 scripts/pipeline.py verify --batch "$N" --product /path/to/morsel-checkout
python3 scripts/pipeline.py reproduce --batch "$N"
python3 scripts/proofs.py --batch "$N"
python3 scripts/reports.py --batch "$N"
python3 scripts/capture.py --batch "$N"
python3 scripts/reports.py --batch "$N"
```

`verify --batch N` expects the cumulative source set through N; on the final bundle use the highest delivered batch for the full-library check. `build --batch N` only exports that batch's new entries and never renders the original shipped 18. `reproduce` ignores the cache, reconstructs every new theme master and rerenders every new 64/192/512 PNG in an owned temporary directory, compares SHA-256 to the delivered output, then removes that scratch. SVG masters remain editable; source SVG is canonical. Run `build` a second time to prove every unchanged new asset skips; missing/tampered outputs rebuild only their owner.

Privacy-bearing coverage and leak checks require the original untracked aggregate; it is intentionally not in the package. Authoring-host commands:

```sh
PRIVATE=/Users/jirathip/.herdr/worktrees/morsel/design-262-library-expansion/.lane-logs/logged-names.json
python3 scripts/pipeline.py coverage --batch "$N" --private-names "$PRIVATE"
python3 scripts/pipeline.py privacy --private-names "$PRIVATE"
python3 scripts/pipeline.py pack --batch "$N" --private-names "$PRIVATE"
python3 scripts/pipeline.py check-package
```

Without private input, coverage uses the frozen, hash-pinned round-1 aggregate and explicitly records that it was **not recomputed**. Public clones cannot independently reconstruct private observed names. There is no live-account or production-matcher claim. The estimator partitions every observed distinct name/row into specific / labeled category / neutral / pending-later study, without hiding the pending portion.

Heavy rendering admission uses `pgrep -fl 'chrome|blender|render|xcodebuild'` and bounded 60-second cycles, continuously resumed as authorized to catch short between-probe windows. Actual native/render executables determine admission, not Rust diagnostic-rendered flags or globally idle load; see `HOST-GATES.md`. Each deferred window records UTC times and blocking PIDs in `admission.jsonl`. The predicate is rechecked after at most four studies/captures. An idle persistent browser daemon is classified separately after CPU inspection; it is never stopped or mutated. All export and screenshot jobs in this lane run serially. Owned temporary profiles/exports are outside the bundle and removed by the scripts.

The one repository `npm test` invocation remains raw FAIL (583 passed / 2 unchanged-server 5000ms timeouts and two worker timeouts). No retries or budget changes. See `HOST-GATES.md`; art/browser/rebuild gates are reported separately.

## Verification and packaging

- Original product-art/app/DB/schema snapshot: `references/shipped-baseline.json`.
- Exact 18-identity before/after hashes per batch: `shipped-18-before-after.json`.
- Raw file set must equal manifest file set (except the manifest itself); all hashes are checked. The aggregate review entry is [index.html](index.html); [ROLLUP.md](ROLLUP.md) and [ROLLUP.json](ROLLUP.json) aggregate completed batches with per-identity hashes and observed-versus-general-coverage records. Regenerate these after the latest batch's visual review:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/summarize.py --through "$N"
PYTHONDONTWRITEBYTECODE=1 python3 scripts/gallery_index.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/capture_index.py
```

The index uses the same locked font/palette tokens, real 44px-or-larger links, natural mobile scrolling, and explicit pending-pixel-approval language. Its captures and DOM evidence are separate in `evidence/index/`.

No transient browser/runtime caches, bytecode, editor backups or scratch in the deliverable. Named JSON build caches are deliberate, hash-verified pipeline inputs.
- `batch-N/SHA256SUMS.json` freezes that batch's source/art and proof/report files; later batches do not rewrite its art.
- Root `SHA256SUMS.json` covers all final package files, including retained build/verifier scripts and previous batch manifests, excluding itself.
- Browser evidence is real Chromium output and DOM validation of fictional fixtures, not production/native screenshots.
- Visual-review notes and the 10-tell composition audit are separate from mechanical gates. Neither grants pixel approval.
- The orchestrator posts each report to issue #262; this lane makes no issue/PR writes.

DESIGN ARTIFACTS ONLY; no app/DB edits; not merged; not opened as PR; no deploy.

# Issue 197 · refined full food library

Direction approved; full-set extension prepared for fleet review/staging.
No app integration or main/release approval is implied.

Owner brief: https://github.com/jirathip-dev/morsel/issues/197#issuecomment-5646485904
Approved control: `3b2d880c65553ef190c7072033cac5904a8c1f87`.

## Review first

- [Local gallery](index.html), [Paper](gallery-paper.html), [Night](gallery-night.html)
- [Paper contact sheet](contact-paper.png), [Night contact sheet](contact-night.png)
- [All labeled 64/40px checks](optical-both.png)
- [Category fallbacks, both themes](fallbacks-both.png)
- [Chicken correction, both themes](evidence/chicken-gate/comparison.png)
- [All phone contexts, Paper](proofs/phone-all-paper.png)
- [All phone contexts, Night](proofs/phone-all-night.png)
- [Visual findings and limits](evidence/REVIEW.md)

Phone proofs are real 390×844 browser captures. Strips place four captures beside
one another without scaling; their pages visibly say fictional fixture / not
implemented UI. All17 entries appear once per theme across the four cohorts.

## What is supplied

Exactly 13 foods + 4 category fallbacks, retaining first-delivery IDs, names,
aliases, categories and kinds. `sources/` contains17 editable tokenized SVGs;
`masters/` contains34 resolved Paper/Night SVGs; `exports/` contains102 transparent
RGBA PNGs at64/192/512. The final gate records and verifies these counts.
`subjects.json` is editable metadata; `catalog.json` is schema2/library2.0.0.

Approved mango/noodles/coffee source SVGs, theme masters and64px PNGs stay
byte-identical to R1. First delivery and R1 remain intact beside this folder.
Chicken now has a bone-in silhouette, not repeated bread-like slices. Other
studies extend the accepted grammar. Grains/Protein received bounded category
readability corrections after the first full-set review.

See [ART-SPEC](ART-SPEC.md) for tokens, sizing, semantic limits and controls.

## Reproduce and verify

At repository root, using existing Python3/Pillow, librsvg and headless Chromium:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_gate.py

This executes build, proof composition, chicken proof, browser capture, asset
verification, workflow tests and local skill/link checks. Raw exits/logs go to
`evidence/gates.json`. It does not open a PR, push, merge, deploy or edit app files.

Focused commands:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_library.py build
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_library.py verify
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_proofs.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_capture.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_tests.py

After final review, regenerate the separated timing report:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_timing.py

The additional actual-click probe is retained at
`skills/food-art/references/browser-interaction-probe.py`: execute its contents
through `browser_exec` with `ROOT=Path(repository_root)` prebound. It waits for
expected URL/body/load/fonts after navigation; it is not a standalone Python CLI.

After all final evidence/doc edits:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_package.py write
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_package.py check

The package manifest verifies current delivered bytes. Timing reports and
browser logs are measurements, not byte-deterministic across runs; regenerate
the manifest after intentionally rerunning them. `ink_tests.py` separately
proves deterministic artwork outputs in a fresh temporary fixture, including
approved control bytes. Sources, renderer/shared helpers and output hashes key
the incremental cache. A no-op leaves masters/PNGs' hashes and mtimes intact.

## Exercised workflow, not finished-art speed claims

Read [timing breakdown](evidence/TIMING.md). Initial batch windows include
reference reads, authoring and tool waits; the parallel windows overlap. Parent
chicken and category corrections are separate. Exports, proof composition,
browser capture, verification and packaging are not counted as drawing time.

The repository-owned [food-art skill](../../../skills/food-art/SKILL.md) records
this exercised flow. A synthetic one-item addition is tested in a temporary
fixture; no eighteenth food is shipped. A future catalog addition requires new
scope/version/proof coverage, not silently bypassing this closed-set release.

## Handoff contract

The designer supplies a committed/pushed exact branch head plus this package to
`orch-morsel`. Orch owns PR, independent review, CI and staging landing; app
bundling belongs to a dependent implementation issue. Designer does not edit
app code/assets, merge, deploy, modify database records or generate art at runtime.
Main/release remains behind its human gate.

Use labeled64px illustrations.40px is diagnostic and loses some material detail.
Category artwork is not ingredient identification. Existing aliases—including
chicken cut terms—are generic grouping metadata, never a promise that the drawn
part/recipe/portion matches a logged food. Real meal photographs remain photos.
No nutrition, allergy or portion inference is supplied.

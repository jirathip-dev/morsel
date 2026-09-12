# Morsel — curated food studies (#197)

PROTOTYPE — awaiting Guy approval.

An original ink-and-wash food library following approved #90 V1. This package
is **artwork and reusable workflow**, not app wiring or a deployed screen.

## Review first

- [Paper gallery](gallery-paper.html) · [Night ink gallery](gallery-night.html)
- [Approved V1 comparison](comparison.html)
- [Paper contact sheet](proofs/contact-paper.png) · [Night contact sheet](proofs/contact-night.png)
- [Every food at 64px and 40px, both themes](proofs/optical-both.png)
- [Paper phone proof](proofs/phone-paper-390.png) · [Night phone proof](proofs/phone-night-390.png)
- [Art specification](ART-SPEC.md) · [Actual review and caveats](evidence/REVIEW.md)
- [Versioned catalog](catalog.json) · [Incremental timing](evidence/incremental.json)

13 distinct foods (12 starter + avocado workflow addition), 4 category fallbacks.
Each has an editable JSON layer source, two themed editable SVG masters and six
transparent PNGs: 64, 192 and 512 square in Paper and Night ink. Totals verified
by code: **17 catalog entries, 34 SVG masters, 102 transparent PNG exports**.
Illustrations are generic, never actual meal photos or portion/nutrition evidence.

## Canonical files

- `sources/`: editable original layer geometry and food metadata.
- `masters/`: generated SVG with named path layers, descriptions and wash fills.
- `exports/`: app-ready transparent pixels; no app integration is implied.
- `catalog.json`: schema/library version, stable IDs, aliases, category, kind,
  dimensions, paths and provenance. Separate from Morsel's database food_catalog.
- `fonts/`: copied existing OFL fonts plus license files.
- `references/`: untouched approved V1 controls and preserved rejected iterations.
- `proofs/`, `evidence/`: real renders, logs, checks and measured experiment.
- `../../../skills/food-art/`: repository-owned skill, template, example and helpers
  (from this file, the correct repository-relative location is
  `skills/food-art/`; use commands below at repository root).

## Reproduce from the Morsel repository root

Prerequisites already exercised: Python 3 + Pillow, `rsvg-convert`, an existing
Chrome headless shell for browser captures. No packages need to be added to the
application. Missing host tools must be escalated, never silently installed.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/library.py build
PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/verify.py
PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/test_workflow.py
PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/capture.py
PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/package.py --reproduce
PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/package.py --write-manifest --check-manifest
```

`build` renders only changed/missing/tampered foods, updates the catalog and
refreshes all gallery/contact/optical pages. It does not regenerate browser
screenshots; run `capture.py` after changes for those. Browser executable can be
specified via `CHROME_HEADLESS_SHELL`; there is no browser install fallback.
All gate commands must exit 0. Expected negative test subprocess exits are 1,
recorded in `evidence/workflow-tests.json` and asserted by the suite.

For a new food, read `skills/food-art/SKILL.md`, author a JSON spec with the
saved template and existing sources, then use one command:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/library.py add path/to/new-food.json
```

Duplicate IDs are refused. Edit an existing JSON and run `build` for revisions.
To reconstruct starter source recipes in an empty library, run `starter.py`;
it deliberately preserves existing sources. The avocado example is under
`skills/food-art/examples/` and can be added only when its ID is absent.

## Actual incremental evidence

Avocado's initial addition command took **2.438695 s**, **42.350095 s** including
saved-workflow readback and manual geometry authoring. Zero command retries;
128 existing SVG/PNG files kept both hashes and mtimes. One later art-review
pigment revision and subsequent review time are excluded; this is not an
end-to-end approval benchmark. The optical-sheet enhancement was added later,
so the timing is specifically for the saved pipeline version exercised then.
Raw logs and snapshots are retained, not synthesized.

## Review delivery

Canonical root:
`/Users/jirathip/.herdr/worktrees/morsel/design-197-food-library/`

Phone gallery (Tailscale; Mac awake):
https://jirathips-macbook-air.tail8c3301.ts.net:8444/morsel/197-food-library/docs/art/food-library/index.html

Review archive:
https://github.com/jirathip-dev/design-output/tree/main/morsel/197-food-library

Only the design-output review mirror has standing push authorization. No Morsel
push, PR, merge or production deployment is part of this delivery. Owner decision:
approve this artwork or name specific refinements before implementation.

---
name: food-art
description: Use when adding Morsel ink-and-wash food art.
version: 0.1.0
author: Guy (jirathip-k), Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [design, food, svg, incremental]
    related_skills: []
---

# Morsel food art

Add original generic food illustrations to the approved V1 library. This is
an offline authoring workflow, not runtime generation or meal recognition.
It never changes app assets, databases, profiles or nutrition records.

## When to Use

- Add a new food or refine one existing illustration in this library.
- Export both Paper and Night ink with stable IDs and honest provenance.
- Do not use for actual meal photos, portion estimation, new art directions,
  app integration, or publishing without authorization.

## Prerequisites

Run through `terminal` at the Morsel repository root. Existing Python 3 with
Pillow and `rsvg-convert` are required. No network, API keys, paid service or
model-specific tool is involved. Do not install dependencies on the host;
escalate missing prerequisites. Exact exercised versions are in the evidence.

Read `docs/art/food-library/ART-SPEC.md` and inspect both approved-reference
PNGs in its `references/` directory with `vision_analyze`. Reuse the source
JSON and layer vocabulary in `docs/art/food-library/sources/`, particularly
`mango.json` for fruit or `jasmine-rice.json` for a vessel.

## How to Run

Short designer invocation: “Use food-art to add <food>; keep approved V1.”

1. Author one JSON spec with `write_file`, using
   `skills/food-art/templates/food.json`. Choose an unused stable slug, useful
   aliases, a category, a food-specific silhouette and layered original paths.
   `layers` is SVG path geometry, not a prompt. Start from shared vessel geometry
   only when the food genuinely uses that vessel. No imported stock drawing.
2. Run through `terminal`:

       PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/library.py add path/to/new-food.json

   This single command registers the source, renders two editable SVG masters
   and transparent PNGs at 64/192/512, updates the versioned catalog, refreshes
   both galleries and contact sheets, copies approved controls, and validates.
   The command must exit 0. Inspect stdout's rebuilt/skipped IDs and PASS report.
3. Inspect the refreshed contact sheets with `vision_analyze`, sequentially,
   and view the art at 64 and 40 CSS pixels in both galleries. Keep the shape
   quiet like the approved controls. A mechanical PASS is not visual approval.
4. If a named defect exists, edit only that source JSON with `patch`, then run
   the `build` command below. Record each manual step and retry. Never rename
   an existing ID to hide a revision. New silhouette work is manual design time,
   not included in a renderer-only speed claim.
5. For delivery, run the capture command below for fresh 390×844 contexts.
   Retain elapsed wall time, changed/unchanged hashes and mtimes, raw exits,
   and visual caveats. Update the package manifest after final evidence edits.
   Owner reviews the art before any app integration.

## Quick Reference

Use `terminal` at repository root:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/library.py build
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/verify.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/capture.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/test_workflow.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/gate.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/package.py --write-manifest --check-manifest

For a clean-room starter reconstruction (not an overwrite):

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/starter.py

## Cache contract

Every food is keyed by source SHA-256, compiler SHA-256 and renderer version.
All expected output hashes must also match. Untouched masters and exports are
not rewritten; missing or tampered outputs rebuild that food only. Changing
compiler or renderer intentionally invalidates the set. Gallery/contact sheets
refresh separately. No-op runs may rewrite aggregate proofs, not food exports.
JSON sources are canonical editable geometry; generated SVG layers are editable
in vector tools, but port deliberate SVG edits back into JSON before rebuilding.

## Pitfalls

- Add refuses an existing ID. Use `build` after a deliberate source edit.
- The template contains a simple example shape, not acceptable finished art.
- Strong hue shifts, thick outlines, tiles and glossy lighting break V1.
- Grain is contained in food fills; transparency does not mean deleting cream
  ingredient areas or plate rims. Night uses soft pigment families, not a white tile.
- Fallbacks are intentionally generic and visibly labeled; an alias match is
  not ingredient, allergy, portion or nutrition evidence. Real photos stay photos.
- The catalog is a design resource, separate from the database food_catalog.
- Green food identity can disappear when sage maps to leafSoft in Night. Use
  the existing forest→sage family for avocado skin/broccoli crowns; use ochre,
  not the brown→pale-line mapping, for grill sears. Check both before claiming fit.
- Pale Paper fallbacks need adjacent names; inspect the generated optical-both
  sheet at exact 64/40px rather than judging only enlarged contact sheets.
- The library command is not a transactional database: if rendering fails,
  retain the source and retry build after fixing the cause. Never claim completion.
- This repository does not contain Hermes' website/doc generator. Do not run
  foreign repository commands or modify canonical shared skills.

## Verification

`verify.py` checks required counts/categories, IDs/aliases, paths, source/catalog
parity, palette/XML safety, alpha/padding/nonblank exports, themes and local links.
`test_workflow.py` proves no-op byte/mtime stability, single-food incremental
behavior and reject paths in an isolated temporary fixture. `capture.py` uses
only an existing headless engine and records actual browser DOM/image checks.
Visual review remains explicit and separate from mechanical PASS.

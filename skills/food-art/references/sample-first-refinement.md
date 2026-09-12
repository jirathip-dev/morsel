# Sample-first ink/wash refinement — exercised, not approved art

Use when the owner retains infrastructure but rejects the artwork. This is a
cheap direction gate, not a new production compiler or a whole-library rebuild.
The issue-197 sample uses exactly mango, grilled-chicken, stir-fried-noodles,
and coffee. Changing this set requires a new owner scope, not an automatic loop.

## Procedure exercised in the local sample round

1. Read the latest issue comment completely and inspect control pixels with
   `vision_analyze`. Fix the exact subject set and first-delivery commit.
2. In a new sibling sample directory, snapshot control hashes and mtimes, copy
   only the four subject exports needed for comparison, and retain the old
   SKILL.md. Do not rewrite the first library's catalog, sources, cache or proofs.
3. Redraw material structures, not merely the surface noise: mango cheek depth,
   broad cut-meat faces, a crossing noodle tangle, ceramic rim/handle and dark
   coffee. Use editable SVG path groups and the existing palette. Broken ink
   weight and pigment density must describe those structures.
4. Use overlapping translucent wash silhouettes, reserved highlights and
   sparse drybrush passages selectively. The sample's seeded SVG wash filter
   affects painted regions only; it is digital simulation, not physical paint.
   It cannot substitute for material drawing. A lighter underpainting than the
   food pigment can create a false pale fringe in Night: the mango test exposed
   this, and pigment-colored underpainting reduced it.
5. Render only 256px studies and 64px thumbnails for both themes; derive the
   40px optical view from the 64px export. Place BEFORE and AFTER together at
   equal framing and show labeled phone contexts. Do not create a full export
   matrix, archive mirror, app asset catalog or deployment before sample approval.
6. Inspect the actual comparisons sequentially with `vision_analyze`. A narrow
   slice band can still look like bread; larger ivory cut faces and a thin crust
   improved cooked-protein reading in the exercised chicken correction. Do not
   assert reliable unlabelled 40px recognition—the sample did not prove it.
7. Preserve the first sample render before one bounded corrective pass. Separate
   initial authoring, initial export, review, corrective authoring, re-export,
   proof composition and browser-capture time. Record wall windows, not invented
   active drawing time or renderer-only finished-art speed.
8. Run the cheap sample verifier after final generation. It checks the fixed
   set, alpha/dimensions/padding, palette/XML, local links and unchanged control
   hashes/mtimes. Report visual shortcomings separately and stop for approval.

## Reproduce the existing issue-197 sample, repository root

Use `terminal` (existing Python/Pillow/rsvg-convert; no installs):

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/sample_gate.py render
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/sample_capture.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/sample_gate.py verify

Local gallery: `docs/art/food-refinement-197-r1/index.html`.
Candidate sources: its `sources/` directory; common wash definitions live in
`wash-defs.svginc`. The helper's `control` command was run once before drawing
and refuses overwrite; do not rerun it for an existing gate. `event <phase>`
appends real timing timestamps. Render deliberately touches only these four
candidate subjects, never original library assets.

The original `library.py add/build`, catalog and asset cache remain intact.
Candidates are not yet expressed in the old JSON layer schema and are NOT
promoted or wired. Integrating an approved richer painting grammar into the
main compiler is a later decision. Keep the first-delivery manifest historical;
do not regenerate it to hide this deliberate, separately versioned skill update.

## Known limits / truthful outcome

The rendered samples show real geometry/material changes beyond grain. They
still have constructed facets, occasional doubled edges and small-size meat
ambiguity. No tool or mechanical PASS establishes genuine physical watercolor
or owner approval. If the owner wants a medium the available pipeline cannot
achieve, state that limit and ask about another authoring tool/service rather
than describing vector icons as painted art. No paid service was used here.

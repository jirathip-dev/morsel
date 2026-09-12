# Review and evidence — issue 197

PROTOTYPE — awaiting Guy approval. Mechanical validity is not owner art approval.

## Actual visual review

The approved V1 Paper and Night-ink screenshots were examined with the vision
tool before drawing. Final rendered contact sheets, both 390×844 browser phone
captures and the exact 64/40px optical sheet were examined sequentially.

- First Paper review: restrained palette, but chicken and broccoli were too
  generic. Preserved `references/round-1/contact-paper.png` and affected source
  JSONs. Revised chicken anatomy/sear strokes and branching broccoli crown.
- Night review: soft theme pigment mapping made broccoli resemble cauliflower,
  the back avocado resemble a pale pear, and chicken grill marks too faint.
  Preserved `references/round-2/contact-night.png` and affected source JSONs.
  Used the existing forest→sage pigment family for broccoli/avocado skin and
  existing ochre for tapered chicken sear marks. No new hue or style family.
- Final Night review: targeted revisions read successfully, no visible clipping;
  quiet ink/wash style fit. Final Paper review: coherent and broadly on direction,
  intact foods, utensils and labels. Chicken remains label-dependent.
- Both phone contexts: no visible art/readability blocker, quiet scale and clear
  illustration disclaimers. Bottom-edge concern was checked with actual scrolling:
  Night page height 911px, viewport 844px, scrollY 67px; footer was fully reachable
  at top 771.594px / bottom 816.375px after scrolling. Normal page flow, not clipping.
- Optical review of every entry at 64px and 40px in both themes: no hard thumbnail
  blocker in this labeled presentation. Paper 40px protein/drink fallbacks are
  pale and have the least contrast margin. Names must remain adjacent.

### Remaining issues / owner decision

1. Chicken is still a generic pale grilled-protein silhouette without its name.
2. Grains fallback and jasmine rice are intentionally close; do not treat imagery
   as botanical identification or a precise dish/ingredient match.
3. Coffee can read as a generic hot drink; clear soup's wash does not prove clear
   broth. These are illustrations, not recipes or dietary evidence.
4. At 40px Paper, drink/protein fallbacks are faint; 64px is the preferred labeled
   slot. Do not solve this by globally thickening every outline.
5. This is authored vector simulation of pale wash, not physically painted media.
   The broad approved direction is preserved; final subjective approval is Guy's.

## Incremental experiment: what was actually measured

The SKILL.md, template, compiler, verifier and gallery helpers were saved before
avocado authoring. The saved skill and mango source were read back. One avocado
JSON was authored, then the saved `library.py add` command was invoked.

- Command wall time: **2.438695 seconds** (render + catalog/gallery/contact refresh
  + validation in the workflow version exercised at that moment).
- Including instruction/source readback and manual geometry authoring:
  **42.350095 seconds**.
- Existing files: **128** masters/exports retained both SHA-256 and mtime_ns.
- Added: **8** files (2 themed SVG masters + 6 PNG exports).
- Command/raw exit: **0**. Pipeline retries in this timed run: **0**.
- Manual steps: saved instruction/source read; original JSON path authoring;
  invocation through the timing recorder. No external API or generation purchase.

Important limits: later visual review caused **one avocado pigment revision**
(alongside broccoli/chicken revisions). That visual refinement/review time is
NOT included in the 42.35-second addition measurement. The preserved timing is
not an end-to-end approval benchmark. An all-entry optical-sheet helper was
also added after the timing trial; the 2.44-second number is not claimed for
that expanded final command. Final tests separately prove the current no-op,
single-food change and tamper-repair behavior. See incremental-start.json,
incremental.json and incremental-add.log for raw evidence.

## Mechanical and browser gates

Commands are run at the dedicated Morsel worktree root with bytecode disabled.
No repository justfile exists. Direct Python scripts are the canonical gates
for this new design-only package; product Bun/Swift suites are not relevant to
untouched application code and were not claimed or run.

- `python3 skills/food-art/scripts/library.py build`: exit 0.
- `python3 skills/food-art/scripts/verify.py`: exit 0; 17 entries, 13 foods,
  4 fallbacks, 34 editable SVGs, 102 transparent PNGs at 64/192/512 in two themes.
- `python3 skills/food-art/scripts/test_workflow.py`: suite exit 0; actual
  corruption probes exit 1 as expected, then restored fixture exits 0.
  Tests cover no-op hash/mtime stability, isolated one-food rebuild, tamper
  recovery, source/catalog drift, blank PNG, duplicate ID, unsafe ID, forbidden
  pigment, XML injection and skill frontmatter/structure.
- `python3 skills/food-art/scripts/package.py --reproduce`: exit 0;
  34 SVGs match the saved compiler/source, all 102 freshly rasterized PNGs are
  byte-identical to canonical outputs. This is a real fresh renderer execution.
- `python3 skills/food-art/scripts/capture.py`: exit 0;
  four 390×844 screenshots, all image/font loads complete, no horizontal overflow,
  no uncaught page errors. Engine is recorded in browser.json. Browser stderr
  retained separately; host engine diagnostics are not fabricated console output.
- Live CDP navigation: phone footer→Night gallery (17 figures)→Paper gallery;
  all images loaded and theme/class matched. Scroll checks recorded above.
- Contrast: text/heading pairs **14.132:1** in both themes. Control rules
  Paper **4.213:1**, Night **3.355:1**. Focus ring Paper **3.052:1**, Night
  **4.631:1**. No grain behind text. Decorative food washes are not data marks.
- Final SHA manifest is generated after participating docs/proofs and checked
  by `package.py --check-manifest`; raw counts are emitted rather than guessed.

## Ten-tell self-audit

1. Stock gradient aesthetic: absent; pigment gradients confined to food wash.
2. Default type hierarchy: absent; existing Caveat/EB Garamond/IBM Plex roles.
3. Hero plus three cards: absent; specimen index and journal excerpt.
4. Arbitrary saturated accents: absent; closed approved palette only.
5. Generic icons/emoji: absent in authored pages/art; no stock pack.
6. Excess pills/shadows/radii: absent; flat ground and fine rules.
7. Decorative fake data: absent; no calories, portions or user records invented.
8. Repetitive UI box composition: absent; unboxed contact index; shared bowls are
   genuine serving vessels, with intentionally labeled category overlap.
9. Gratuitous motion: absent; static pages work unchanged with Reduce Motion.
10. Content-free layout: absent; every specimen has a stable identity, paths,
    provenance, size comparison and owner-review purpose.

No composition tell requires a new direction. Remaining art ambiguity is named
above rather than hidden by a mechanical PASS.

## Scope

Only `docs/art/food-library/` and `skills/food-art/` are new Morsel source roots.
No app wiring, database, release, PR, merge, deployment, other profile edits,
purchases or fleet operations. Morsel branch remains unpushed. Review mirror is
published only to the standing-authorized design-output repository/gallery.

# Issue 197 — four-subject refinement direction gate

**STOP FOR SAMPLE APPROVAL. The artwork is not approved.**

Current bounded brief:
https://github.com/jirathip-dev/morsel/issues/197#issuecomment-5646236848

## Open these local proofs

- [Comparison gallery](index.html)
- [Paper: before / after + 64px / 40px](comparison-paper.png)
- [Night ink: before / after + 64px / 40px](comparison-night.png)
- [Before Paper phone](phone-before-paper.png) / [After Paper phone](phone-after-paper.png)
- [Before Night phone](phone-before-night.png) / [After Night phone](phone-after-night.png)

One final revised treatment each for **mango, grilled chicken, stir-fried
noodles, coffee**. No other subject was redrawn. The large comparison drawings
are 256px studies; 64px and 40px previews are shown at actual pixel widths.
Phone fixtures are real 390×844 browser captures with 64 CSS-pixel image slots.
Every fixture is labeled illustration, not a meal photo or portion/nutrition
record. The pages are local review fixtures, not deployed UI.

## Control and locked scope

First delivery: `fc5d9a0c406d932c329b088a610d0c987cd0317b`, retained as control,
**not approved artwork**. `control-state.json` snapshots original library files
and existing machinery. The final verifier confirms **217 protected files**
retain both SHA-256 and mtime_ns. This includes the catalog, sources, exports,
proofs and original compiler/build machinery. Stable IDs remain unchanged.

`control/` contains only comparison exports and the previous food-art SKILL.md.
`development/` retains the first sample pass before the single corrective pass;
these are process records, not alternate directions offered for selection.

The original library has not been rebuilt or repackaged. Its historical
manifest remains untouched. The separately versioned repository SKILL.md gains
an exercised sample-first route; do not interpret that as source promotion.

## What changed in the drawing

| Subject | Material / form change from first delivery |
|---|---|
| Mango | Off-axis shoulders and tip, irregular leaf gesture, raised flesh planes rather than a flat scoring grid, overlapping yellow/orange washes, sparse broken contours. A later correction removed the unjustified pale underpainting fringe in Night. |
| Grilled chicken | Asymmetric cooked breast, irregular char patches, broad exposed ivory cut faces, thin browned exterior, restrained fibres and contact separation. A first version's narrow bands looked too much like bread and were replaced. |
| Stir-fried noodles | Varied crossing ribbons and loose ends instead of parallel sine waves, sauce pooled in overlaps, wilted leaf fragments, a less regular bowl with selective wash and ink. |
| Coffee | Dark liquid pool with reserved reflection, visible ceramic rim/handle attachment, uneven glaze shadows, lost-and-found contours and faint irregular steam. |

The illustration grammar is deliberately changed, not simply grain over the
old shapes. Original editable SVG path groups, common wash/drybrush definitions
and closed existing palette are retained in `sources/` and `wash-defs.svginc`.
Night changes the line role to the approved resolved inkline; material pigments
remain descriptive food colours. No new hue, stock art or paid generation.

**Medium honesty:** these are digitally authored SVG ink/wash studies with
seeded pigment-edge and drybrush simulations—not scans of physical watercolor.
The visual reviews found genuine structural/material improvements beyond grain,
but do not establish that the fully naturalist painterly finish is resolved.

## Visual findings — not an approval verdict

Both final comparison sheets and both AFTER phone captures were inspected.

- Mango and noodles make the strongest change from the original icon grammar.
  Mango still has faceted flesh and some muddy/doubled edges. Noodle continuity
  is imperfect; fine strands merge at small size.
- Coffee has a stronger dark-liquid read and retained ceramic silhouette. Some
  bounded shadow patches remain constructed-looking; steam is expendable at 40px.
- **Chicken now reads more readily as sliced cooked meat/protein at study size**,
  rather than just a striped loaf. This is a meaningful correction, not a claim
  of universal recognition. At 64px the pale faces/brown rims can still suggest
  bread at a glance; reliable unlabelled chicken recognition is NOT established.
  At 40px, use the adjacent name. This remains an owner-review concern.
- All four are legible in the labeled 64px phone context. Final Night phone
  review found no excessive glow or outline and no visible clipping. Thin pale
  tableware carries more weight than mango but does not overwhelm the names.
- Clear fixture/illustration disclaimers remain visible. Plated-food drawings
  inherently suggest servings, so never transfer these into actual photo or
  nutrition evidence roles even after art approval.

**Disposition:** cheap sample direction gate delivered; visual/art acceptance
remains open. No broader repaint or production export work follows automatically.
If a more genuinely painted finish is required than this path-based technique
can deliver, request an alternative authoring medium/tool before spending on
or expanding another full set. No new paid service or host install was requested.

## Real timing, separated

All figures below are measured elapsed windows, not active hand-drawing minutes.
See `timing-events.json`, `timing-summary.json`, both export-timing records and
`phone-capture.json`.

| Phase | Seconds |
|---|---:|
| Initial four-subject art-authoring window | 328.468 |
| Initial export of four subjects, both themes, 64/256px | 1.722 |
| Initial comparison composition | 0.226 |
| First visual review + orchestration window | 247.153 |
| One corrective art-authoring pass: chicken + mango | 106.010 |
| Second four-subject export | 1.735 |
| Final comparison composition | 0.240 |
| Post-correction review/browser/capture-tooling window | 344.222 |
| Phone-capture subset of previous row — do not add again | 33.095 |

Observed authoring-start→visual-review-end window: **1029.961 seconds**.
Initial helper setup and final documentation/commit/comment time are excluded.
There was **one corrective art pass**, **zero failed export retries**. The quick
export times are not finished-art speed claims. No provider-price/cost benchmark
was measured or claimed.

## Verification actually exercised

From the Morsel worktree root, with existing tools only:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/sample_gate.py render
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/sample_capture.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/sample_gate.py verify

All returned **raw exit 0**. This is the sample gate, not `library.py build` or
the whole-library gate. It produces only 8 themed candidate SVGs and 16 candidate
PNGs for these four subjects, plus the small comparisons/phone fixtures.

`verification.json`: exact four-source set, XML/closed palette/no embedded
scripts or images, nonblank RGBA exports, ≥6% transparent margin, image sizes,
comparison dimensions, local links, copied-control identity and protected
hash/mtime checks. The 40px view is deliberately downsampled from 64px.

`browser-check.json`: actual clicks from the local gallery to all four phone
pages and back; four loaded image rows per page at 64px, fonts loaded, no
horizontal overflow. Footer bottom 726.234px within the 844px viewport on every
page. `phone-capture.json` records each browser command's exit and duration.

## Ten-tell self-audit

Compare surface, not a product redesign. (1) No stock gradient aesthetic;
(2) existing type hierarchy; (3) no hero/three-card composition; (4) closed
approved palette; (5) no stock icons/emoji; (6) no pills/shadows; (7) no invented
metrics; (8) paired comparison rows earn their repetition, not generic cards;
(9) no motion; (10) every proof serves the exact four-subject approval decision.
This composition audit does not resolve the constructed-looking paint passages
or chicken ambiguity noted above. No broad re-composition or packaging follows.

## Workflow capture and boundary

Updated only the repository-owned food-art skill with an exercised sample-first
route and `references/sample-first-refinement.md`; new sample helpers do not
modify the existing incremental compiler. Candidate geometry has NOT been
promoted into the catalog's original JSON layer schema.

No app/database changes, publishing, push, PR, merge, deploy, fleet changes,
other-profile or shared-skill edits. Local preview only. Conductor handles
review delivery. Stop for the owner's decision on this sample direction.

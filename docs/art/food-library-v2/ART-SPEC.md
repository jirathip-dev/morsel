# Morsel food library · approved ink/wash edition

## Authority and bounds

Owner approval: https://github.com/jirathip-dev/morsel/issues/197#issuecomment-5646485904

Direction control: `3b2d880c65553ef190c7072033cac5904a8c1f87`.
Preserve mango, stir-fried noodles and coffee. Fix chicken recognition and extend
that treatment to the existing 13-food + 4-fallback catalog. This is not a new
redesign. Main/release approval is not granted by this design handoff.

Artifact surface: **Compare** — contact sheets, size checks, labeled fictional
phone contexts and editable/export resources. This is not an app interface redesign.

## Invariants

- Same 17 IDs, names, aliases, categories and food/fallback kinds as first delivery.
- Approved three tokenized SVG sources, theme masters and 64px PNGs byte-identical
  to R1. Shared wash definitions unchanged. First delivery and R1 files intact.
- Original, digitally authored ink/wash, not stock art, a scan or a meal photograph.
- Organic asymmetry, uneven overlapping pigment, selective broken/variable ink,
  quiet negative space and material-specific construction before texture.
- No photo, portion, ingredient, exact cut, allergy or nutrition claims.
- Category fallbacks always accompanied by their category label; not a detected food.
- No app code, asset-catalog wiring, database, runtime generator or profile edits.

## Small system

Colors follow approved R1: Paper `#FFF7E8`, Night `#2A261F`; ingredient palette
cream `#F2E9D9`, sage `#5E7E57`, leaf `#E1E9D7`, forest `#2F654B`, orange
`#E66A2C`, peach `#FBE1C9`, red `#B94738`, gold `#D6A62C`, ochre `#A5750B`,
brown `#655A4B`. Selective line is `#8B7355` on Paper, `#9D917F` on Night.
These are locked supplied tokens, not a newly invented palette.

EB Garamond for labels, Caveat for journal headings, IBM Plex Mono for technical
annotations. Existing bundled fonts and OFL notices travel with proofs. Text uses
Paper/Night inverse contrast, not pigment colors. Grid and hairline separators;
no elevated cards, artificial radii, gradients in layout chrome or motion.
Links have hover/focus states and at least 44×44 CSS pixel targets.

## Asset contract

- Tokenized source SVG: 256×256 intrinsic size and `viewBox="0 0 256 256"`.
- Editable resolved master per theme, same intrinsic dimensions/viewBox.
- Transparent RGBA PNG at 64, 192 and 512 square pixels per theme.
- 64px labeled placement is the review target; 40px is a diagnostic, not a promise
  of ingredient or cooking-method recognition. Tiny grain/char/steam details recede.
- `subjects.json` is editable metadata. `catalog.json` schema 2 / library 2.0.0
  carries the source/master/export paths, dimensions and provenance.
- Descriptions now match refined depictions. Legacy names/aliases remain stable;
  aliases are generic grouping terms, not guarantees that the depicted chicken
  part, vessel, recipe or portion matches a logged food.

## Bounded corrections exercised

Chicken: removed repeated pale slices and loaf-like mass. A bone-in asymmetric
silhouette, patchy skin/char and selective joint edge distinguish it from toast.
Paper bone contrast was corrected after its first rendered check. Label remains
necessary for exact cooking method; 40px is weaker than 64px.

Grains fallback: replace flat surface reading with a dry uneven mound above the
rim and broad kernel marks. Protein fallback: reduce the pale oval's dominance
and give the bean-like cluster comparable visual weight. Neither asserts actual
meal ingredients. Drink and Produce remain generic vessel/assortment cues.

No change to approved mango/noodles/coffee. No general style-normalization pass.

## Controls and verification

`evidence/control-lock.json` pins historical bytes and the owner comment.
`evidence/verify.json` records all current mechanical checks; visual findings are
in `evidence/REVIEW.md`. `evidence/gates.json` contains raw command exits and logs.
The final checksum manifest covers delivered files, not proof of owner/fleet
approval. Exact reproduction and handoff commands are in `README.md`.

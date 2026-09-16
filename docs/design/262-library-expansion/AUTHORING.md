# Issue 262 — production authority and fixed art contract

Surface: Compare. This is an additive ink/wash library study, not an app redesign.
Owner decision: https://github.com/jirathip-dev/morsel/issues/262#issuecomment-5690697676
Approved subject list: morsel design/262-library-expansion @ 88b8d4df7978254d2f0fb0297b8b60bc67153e57.
AMENDED: https://github.com/jirathip-dev/morsel/issues/262#issuecomment-5690755910 promotes batch 5. Batches 1–5 proceed sequentially with no per-batch stop. All 12 batch-5 subjects are evidence-free for this account (0 observed rows), for general coverage only. Pad thai / boba tea dedicated-study versus alias decisions are based only on honest depiction, never effort. Earlier reserve wording in the immutable proposal is historical and superseded. Pixels remain pending owner review.

## Source references (read only)

Product checkout: /Users/jirathip/.herdr/worktrees/morsel/design-262-library-expansion
Read skills/food-art/SKILL.md, docs/art/food-library-v2/ART-SPEC.md and the mango.svg, stir-fried-noodles.svg, coffee.svg controls there.
The approved editable metadata is references/subjects-proposed.json in this bundle.

## Authoring scope

Write ONLY assigned files in library/sources/<id>.svg in this bundle. Do not edit another artist's files, metadata, shared scripts, product sources or shipped art. Do not start later batches.
Original SVG drawing only, no downloaded art, photos, scans, image generators or stock shapes. Every identity needs food-specific organic construction. Shared vessel grammar is fine; cloning a bowl and merely changing color is not.
No rendering in child lanes: the parent serializes export and browser work. No Git operations in child lanes. Validate SVG/XML and palette/token spellings only.

SVG root: xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256".
Exactly one <defs><!-- WASH_DEFS --></defs>. Reuse url(#wash) and url(#dry); shared definitions must stay unchanged.
Named editable groups, title, optional desc. Only SVG tags svg/title/desc/defs/g/path/circle/ellipse/line/polyline/polygon/clipPath. No external resources, CSS, text, raster, script, gradients, symbols or use.
Colors: tokenized fills/strokes only: {{paper}} #FFF7E8, {{cream}} #F2E9D9, {{sage}} #5E7E57, {{leaf}} #E1E9D7, {{forest}} #2F654B, {{orange}} #E66A2C, {{peach}} #FBE1C9, {{red}} #B94738, {{gold}} #D6A62C, {{ochre}} #A5750B, {{brown}} #655A4B, {{dark}} #2A261F, {{line}} #8B7355 Paper / #9D917F Night. Do not introduce blue/purple/pink tokens: represent dark fruit through brown/red/forest/dark overlaps; pale pink through peach/red translucent washes. Palette takes precedence over the proposal's loose hue wording.
Keep food inside roughly x/y 28..228; transparent corners; no rectangular background. Visible content needs >4.5% border at all sizes. Substantial pale underpainting on pale food matters on Night.

## Locked style

Organic asymmetry and selective broken/variable ink (~0.5–1.4 intrinsic px), overlapping uneven pigment and dry-brush highlights. At least several distinct pigment/edge layers, not flat outlined clip art. Wash supplies volume; ink defines only structural edges. Food-specific silhouette and durable cue come before fine texture. At 64px one or two cues must survive: egg yolk, pasta strands, leaf/stalk contrast, wrap cross-section, meat grain, etc. Use 40px only diagnostically.
Quiet negative space. Avoid repetitive confetti, uniform speckle fields, fat cartoon outlines or artificial sheen. Never copy control geometry.
Generic depictions never prove actual recipe, portion, ingredients, cut, allergy or nutrition. Fallbacks must read as category signs, not identified meals; labels will accompany them.

## Evidence

Return assigned IDs, exact file paths, construction/recognition caveats. Do not claim rendered or visually verified; parent does that. Renderers: offline rsvg-convert; proofs use unchanged EB Garamond / Caveat / IBM Plex Mono. No app/Swift/DB/schema edits or bundling.

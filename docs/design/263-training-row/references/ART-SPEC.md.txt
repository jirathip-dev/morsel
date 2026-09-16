# Food studies — art specification, revision 1

PROTOTYPE — awaiting Guy approval. Design-only; no app integration.

## Authority and inspected controls

- Scope: https://github.com/jirathip-dev/morsel/issues/197
- Locked direction: https://github.com/jirathip-dev/morsel/issues/90
- V1 approval: https://github.com/jirathip-dev/morsel/issues/90#issuecomment-5535107693
- Promoted controls: `../../evidence/issue-90/90-V1-today-default-paper.png` and
  `../../evidence/issue-90/90-V1-today-default-night.png`; untouched copies in
  `references/approved-v1-{paper,night}.png` for a self-contained review.
- Exact token authority: `../../DESIGN.md`, `../../evidence/issue-90/tokens.md`.
- The natural-history plate named in #90 is direction context, not an asset
  sampled or traced here. No third-party food artwork or stock pack is used.

Both approved screenshots were visually inspected before production. They show
small, pale three-quarter-view bowls/plates with very thin sepia contours,
restrained sage/ochre/terracotta washes and generous empty space. Their log
thumbnails support the record rather than competing with data. This set follows
that vocabulary; it does not add strip charts, ring variants or new page design.

## Surface and system

Review gallery archetype: Explore (a specimen index, not a marketing hero).
Meal-context archetype: Monitor (a quiet hairline-separated journal excerpt).
No cards, elevation, decorative badges, metrics or invented meal records.
Caveat headings, EB Garamond body, IBM Plex Mono figures; existing bundled OFL
fonts and license files copied without alteration. Space: 8/16/24/32; no new
radius or shadow system. Static art and pages; no animation or transition, so
Reduce Motion has no motion to suppress. Link targets are at least 44px for
primary navigation, keyboard focus is visible, layout reflows at phone width.

## Catalog locked before production

12 starter foods: jasmine-rice, stir-fried-noodles, vegetable-soup,
grilled-chicken, salmon, fried-egg, toast, broccoli, mango, banana, orange, coffee.
4 fallbacks: fallback-grains, fallback-protein, fallback-produce, fallback-drinks.
The further food for the saved-workflow experiment is avocado, not counted as
one of the 12 starter foods. Entries are enumerated in catalog.json; stable IDs
are design identities, never database UUIDs or nutritional reference matches.

## Palette and appearance

Use only approved Orange Hearth + Sage tokens: paper #FFF7E8, cream #F2E9D9,
sage #5E7E57, leaf #E1E9D7, forest #2F654B, orange #E66A2C, peach #FBE1C9,
red #B94738, gold #D6A62C, ochre #A5750B, brown #655A4B, inkline #8B7355.
Night resolves sage→leafSoft, red→accentSoft, brown→line #E3D2BA and
inkline→approved resolved #9D917F. It does not introduce unrelated hues.
Pigments intentionally remain descriptive food color, not chart-data encoding.

Layered wash: pale underpainting at 0.68 alpha inside food silhouettes only;
radial pigment density 0.42–0.91 plus sparse, deterministic 37×43-unit pigment
flecks. This is vector simulation of wash, not a claim of physical watercolor.
No external raster textures, nondeterministic filters, paid generation or API.
No paper tile, rectangular background, cast shadow, glow or opaque halo.
The gallery itself has a flat theme ground to avoid grain reducing text contrast.
Text and control contrast are measured in evidence/contrast.json, not inferred
from token names. Art is decorative and always has adjacent names/alt text;
not every pale internal wash is asserted to meet a data-mark contrast floor.

## Drawing contract

- 256×256 coordinate plane, exported at 512×512, 192×192 and 64×64 per theme.
- Actual food occupies roughly x=40–216 and y=45–200; preserve ≥7% transparent
  margin in raster checks, generally 14–20% optical side padding.
- At 64 CSS px, food reads about 44px wide, comparable to approved thumbnails.
  Gallery also shows 40px optical check: names remain essential at that scale.
- Quiet elevated three-quarter vessel perspective; rim ellipse and shallow
  side wall. Whole fruits may stand alone; avoid adding plates to everything.
- Food-specific contours are authored paths. Gentle asymmetry, restrained line
  rhythm, rim double-line, occasional broken secondary detail. Outline normally
  1.1 units, fine detail 0.5–0.9, selected stems/utensils up to 2.
- One primary food mass, a few identifying details. Avoid glossy realism,
  cartoon faces, black sticker outlines, exaggerated thick food piles.
- Retain JSON layer source plus named SVG layer groups. Edit JSON to regenerate;
  SVG-only changes otherwise get correctly replaced from canonical source.

## Semantics and provenance

Every gallery and context calls these generic illustrations. Never put them in
meal photo storage, label them photo vision, infer portion/macros from them, or
silently replace a real photo. All context rows are fictional art fixtures with
no nutritional numbers. Category fallback is explicit: nonspecific protein may
look like tofu/fish/chicken; it is deliberately not ingredient/allergen evidence.
Aliases support curation lookup only; they do not authorize automatic app mapping.
Rights: original agent-authored geometry for Morsel; no stock artwork. Font OFL
licenses remain alongside the font binaries. Approval is pending per asset set.

## Visual QA checklist

- [ ] Owner finds the actual artwork consistent with approved V1.
- [ ] Silhouette is recognizable at 64px; 40px is checked with adjacent name.
- [ ] Both themes retain rims/pale ingredients with transparent surroundings.
- [ ] Texture remains quiet, with no noisy tile, sticker edge or glossy shine.
- [ ] Similar vessel foods remain distinct through contents, not palette alone.
- [ ] No real meal-photo, portion, nutritional or deployment implication.
- [ ] Generic category fallbacks remain explicitly labeled.
- [ ] Mechanical gates, source reproduction and incremental evidence pass.

Checkboxes here are review criteria, not a pre-filled claim of visual approval.
The actual visual verdict and remaining issues are in evidence/REVIEW.md.

## Skill discovery decision

Inspected active enabled skills and searched shared Brain for food/watercolor.
Reuse: app-icon-design's editable SVG→deterministic raster pattern and
reproducible-design-artifacts' source/evidence discipline. Searched skills.sh
for food illustration and wider hub for watercolor asset workflow. Inspected
`skills-sh/sfkislev/flue/illustrator` (community): Adobe Illustrator/Flue bridge
and foreign local paths; rejected as unnecessary coupling/dependency. Wider hub
returned no matching workflow. Created repository-local `skills/food-art` for
Morsel's exact catalog + themed exports + incremental contract. No installation
or shared/profile skill mutation. No model names hardcoded.

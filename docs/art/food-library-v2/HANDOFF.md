# Designer → orch-morsel · issue197

## Authority

Owner comment: https://github.com/jirathip-dev/morsel/issues/197#issuecomment-5646485904

Accepted direction/control: `3b2d880c65553ef190c7072033cac5904a8c1f87`.
The final exact branch head is supplied in the issue delivery comment and direct
orch handoff; use that immutable SHA, not an assumed moving branch tip.

## Delivered scope

`docs/art/food-library-v2/` is the active art bundle. Exactly13 foods +4 fallbacks,
17 tokenized SVG sources,34 resolved theme SVG masters and102 RGBA PNGs at
64/192/512. Stable IDs/names/aliases/categories/kinds preserved. Descriptions
updated for actual refined depictions; alias matches do not promise exact cuts.

Approved mango/noodles/coffee sources, masters and64px outputs byte-identical to
R1. First-delivery/R1 files retained. Chicken's repeated slice/loaf construction
replaced by bone-in asymmetry. Grains/Protein fallbacks corrected after visual
review. No broader redesign, stock pack, runtime generation or nutrition claims.

Repository-owned `skills/food-art/` updated to0.3.0 with exercised SVG authoring,
cache, addition, negative probes, rendering, capture and packaging procedures.
Old JSON machinery remains for historical reproduction, not the approved art.

## Reviewer commands and focus

From a checkout of the exact delivered head:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_package.py check
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_gate.py

Package check first verifies committed bytes. Running the gate intentionally
refreshes timing/log evidence; do not mistake those changes for artwork drift.
`ink_tests.py` separately proves all136 master/PNG bytes reproduce in a clean
fixture, no-op hash+mtime stability, source mutation and repair locality, reject
paths and a synthetic addition. The release gate rejects an eighteenth entry.

Inspect `contact-paper.png`, `contact-night.png`, `optical-both.png`,
`fallbacks-both.png`, `proofs/phone-all-paper.png`, `proofs/phone-all-night.png`
and `evidence/chicken-gate/comparison.png`. Read `evidence/REVIEW.md` and
`evidence/TIMING.md`; do not substitute mechanical PASS for a visual verdict.

Specific checks:

- Chicken no longer reads as sliced bread at labeled64, both themes.
- Mango/noodles/coffee remain the accepted controls; no normalization pass.
- Grains fallback reads as dry piled contents, not broth. Protein remains a
  balanced generic grouping, with mandatory label and no identified-food claim.
- All17 IDs and all target sizes exist; full theme/phone coverage is real.
- Ordinary40px material-detail loss and label-dependent exact food varieties are
  disclosed, not a hidden screenshot or portion-recognition claim.
- Timing tables separate overlapping source windows, corrective review window,
  compiler/export work, proof composition, browser capture and tests. Not measured
  separately: active drawing time, fallback edit alone, tool authoring alone,
  final documentation/Git handoff. No invented aggregate drawing estimate.

## Ownership boundary

Orch owns PR, independent review, CI and staging landing. Designer branch push
was authorized; designer does not open a PR or merge. Integrating bundled PNGs
into the native app is a dependent implementation issue, not part of this lane.
No app code/asset-catalog wiring, database, runtime art generator, deployment or
other profile edits were made by the designer. Main/release remains human-gated.

On AC-versus-prototype conflict: prototype wins for look/interaction; AC wins for
behavior/tests. Keep the existing approved direction, not a new redesign.

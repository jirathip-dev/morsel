# Neutral food fallback · design handoff #223

## Purpose and meaning

`fallback-neutral` depicts an empty irregular ceramic plate and a plain spoon.
It is a neutral eating sign for unknown foods and mixed meals, deliberately
without a depicted ingredient, dish, liquid, garnish, steam or portion.

Category artwork travels with its category label. The neutral study must never
be presented as an identified food. `category: neutral` is a sentinel, not a
nutritional category. Preserve the logged food's own name; never infer an
ingredient from this art. Food rows always use illustrations even when a real
photo exists. The separate implementation lane owns nonblank unknown/mixed-meal
resolution and the always-illustrated rule; no Swift file was changed here.

## Direction and small system

Surface: Compare — native-size art, theme comparisons and fictional phone proofs.
Locked Paper #FFF7E8 / Night #2A261F, cream wash, quiet brown/sage ceramic shade,
Paper/Night line tokens. No invented palette. Existing seeded wash/dry definitions,
256×256 tokenized master frame, selective broken ink, organic asymmetric curves,
transparent RGBA exports at 64/192/512px. No typography embedded in the icon.
Proof labels use existing EB Garamond/Caveat/IBM Plex Mono. No motion.

The plate is intentionally empty: a symbol of eating, not a literally identified
food. At 64px it remains a plate/spoon sign; exact tableware or meal identity is
not promised. The plate is quieter on Paper than Night, consistent with the
approved ceramics. New aliases are generic lookup terms, not detections.

## Verification and visual correction

Initial mechanical gate passed, but a native Paper browser inspection found the
spoon/rim too faint. `evidence/neutral-initial/` retains rejected optical and phone
proofs, not current art. The correction strengthened only the neutral defining
contours and spoon pigment. The next incremental build rebuilt only
`fallback-neutral` and skipped the original 17. Final native Paper and Night
phone screenshots and the both-theme comparison were independently image-reviewed:
plate and spoon legible, no clipping or misleading depicted food, same ink/wash
family. This is a designer visual verdict, not final owner or fleet approval.

The final full gate raw exits were all 0: build, proofs, chicken, browser, assets,
neutral, workflow (`ink_tests.py`), local. See `evidence/gates.json` for real commands
and raw logs. Fourteen browser captures cover five phone cohorts in both themes
and desktop/mobile galleries; console/font/image/native-64px checks passed.
`evidence/neutral-verification.json` records the decoded bundled catalog entry,
total 18 assets, six export SHA-256 values, two fresh render hashes per PNG,
side-by-side export/bundle hashes and exact neutral-kind/missing-neutral rejection
probes. All six first/second/export hashes agree; both 64px bundled copies agree.
The existing full clean-room workflow reproduced all 144 masters/PNGs.
All 154 original source/master/export/shared-wash baseline files remain identical.

## Ten-tell self-audit

1. No stock or borrowed food art: original editable geometry.
2. No invented palette or type system: approved supplied tokens/fonts.
3. No generic hero/three-card composition: retained Compare contact/size layout.
4. No decorative gradient chrome: washes belong to the illustration material.
5. No uniform icon traced shape: irregular contours and selective line weight.
6. No texture-only disguise: plate/spoon geometry communicates before texture.
7. No fabricated metrics, testimonials or food claims: technical sizes are measured.
8. No nested card dashboard: grid, labels, hairlines and native-size rows only.
9. No gratuitous motion, badges or ingredient decorations.
10. No one-size framing shortcut: native 64px phone inspection caused a real
    optical correction, with final exported pixels inspected in both themes.

## Provenance and boundaries

Schema 2 / library 2.1.0 adds exactly one neutral fallback to the previous 17.
`kind` remains `fallback` (offline decoder compatible); `category` is `neutral`,
distinct from drinks/grains/produce/protein fallbacks. Original metadata and art
remain unchanged. Direction provenance cites issue 197; addition authority cites
issue 223. Approval remains `approved-direction-neutral-study-awaiting-fleet-review`.

The existing Swift resolver calls every fallback a category fallback. The impl
lane must distinguish this sentinel explicitly. No app build, runtime resolver,
actual photo/unknown-row behavior, native UI or deployment was verified here.
No new dependency, network-fetched art or AI generation service was used.

## Reproduce

Exact commands: `README.md` and
`skills/food-art/references/neutral-fallback.md` from repository root.
`ink_neutral.py --bundle` is the scoped resource-copy step; `ink_gate.py` verifies
without app writes. Run `ink_package.py write` then `ink_package.py check` only
after all final docs/evidence edits. SHA256SUMS.json pins the delivered package,
not uninterrupted hand time, owner approval or a deterministic browser log.

# Morsel ink/wash library · issue 223

Current release: schema 2 / library 2.1.0. Exactly 13 food studies, 4 labeled
category fallbacks and 1 neutral eating sign. Approved-direction artwork;
neutral study pending fleet review. No main/release or final owner approval implied.

## Review first

- [Neutral study, native 64px and larger, both themes](neutral-both.png)
- [Neutral semantics, results and limitations](NEUTRAL-FALLBACK.md)
- [Paper neutral phone fixture](proofs/phone-neutral-paper.png)
- [Night neutral phone fixture](proofs/phone-neutral-night.png)
- [Local gallery](index.html), [Paper](gallery-paper.html), [Night](gallery-night.html)
- [Paper contact sheet](contact-paper.png), [Night contact sheet](contact-night.png)
- [All labeled 64/40px checks](optical-both.png)
- [Four category fallbacks](fallbacks-both.png)
- [Machine-readable neutral verification](evidence/neutral-verification.json)
- [Raw gate exits](evidence/gates.json)

Phone proofs are real 390×844 browser captures of fictional art fixtures, not
implemented UI. All 18 entries appear once per theme across five cohorts; each
phone strip places five captures beside one another without scaling. The browser
gate also checks desktop/mobile galleries, fonts, images, console and 44px links.

## What is supplied

18 editable tokenized source SVGs, 36 resolved Paper/Night masters, and 108
transparent RGBA PNGs at 64/192/512px. `subjects.json` is editable metadata.
The neutral 64px Paper/Night PNGs and full catalog are copied byte-identically to
`app/Resources/FoodArt/`. Existing 17 studies retain identities and art bytes;
`evidence/neutral-baseline.json` pins their 154 source/master/export/wash files.
The original approved mango/noodles/coffee and earlier historical controls remain
unchanged, verified by the existing gate.

The new neutral mark is an empty ceramic plate and spoon, not an identified food.
Category artwork always travels with its category label. The neutral mark must
never be presented as an identified food, ingredient, portion or category.
Food rows always use illustrations, even when a real photo exists. The separate
implementation lane must use the neutral sign for unknown/mixed meals rather than
blank rows; this delivery does not implement or test that Swift behavior.

## Reproduce and verify

From repository root with existing Python/Pillow, librsvg and headless Chromium:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_library.py build
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_neutral.py --bundle
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_gate.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_package.py write
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_package.py check

The normal gate runs build, proofs, historical chicken proof, real browser
capture, asset verification, neutral fresh-render/bundle/negative checks,
`ink_tests.py` and local skill/link checks. Raw exits and logs are retained in
`evidence/gates.json`. No runtime generator, dependency installation or external
art source is used. Only `ink_neutral.py --bundle` writes app resource copies;
normal verification never writes app files.

See [neutral authoring reference](../../../skills/food-art/references/neutral-fallback.md)
for first registration and exact regeneration details. The normal release gate
requires the closed set of original 17 plus `fallback-neutral`, not arbitrary
additions. An isolated nineteenth fixture is deliberately rejected.

Deterministic art bytes are distinct from measured timing/browser logs, which
vary between runs. Regenerate the final manifest after intentional evidence/docs
changes. `ink_neutral.py` renders each neutral PNG twice and compares those bytes
with the delivered export; the full workflow test regenerates all 144 masters/PNGs
in an isolated source fixture and checks cache no-op, real mutation and repair.

## Historical direction context

Owner direction approval:
https://github.com/jirathip-dev/morsel/issues/197#issuecomment-5646485904
Control: `3b2d880c65553ef190c7072033cac5904a8c1f87`.
Addition authority: https://github.com/jirathip-dev/morsel/issues/223 and its
explicit design brief. This is not approval of the new final pixels by that
historical comment.

[ART-SPEC](ART-SPEC.md) preserves the original normative palette and art grammar,
with an explicit issue-223 additive amendment. [Historical review](evidence/REVIEW.md),
[historical timing discussion](evidence/TIMING.md) and chicken proofs describe the
issue-197 round, not new review verdicts or uninterrupted authoring time.

## Handoff

Orch owns PR, independent review and integration. This lane changes only art,
app food-art resources and the food-art skill. No Swift/project/tests/workflows,
server/database, deployment or production writes. Native 64px is the review
placement; 40px remains diagnostic, not a recognition promise.

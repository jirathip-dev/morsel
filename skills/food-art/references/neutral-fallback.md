# Neutral food fallback · issue 223

The authorized addition is `fallback-neutral`, `kind: fallback`,
`category: neutral`, display name `Food · fallback`. It depicts an empty,
irregular cream ceramic plate with a plain spoon. It is a neutral eating sign,
not a claim that an unknown food contains a depicted ingredient or dish.

Category artwork travels with its category label. The neutral study must never
be presented as an identified food. `neutral` is a resolver sentinel, not a
nutrition category to display or infer. Preserve the user's actual food name;
do not relabel their food as a plate, spoon or an invented dish. The aliases
are generic lookup terms, not inference rules or ingredient detections.

Owner correction: food rows always use illustrations, even when a real photo
exists; unknown and mixed meals must never render blank. This asset lane supplies
the fallback; the implementation lane owns all Swift resolver/presentation changes.
The existing Swift `isCategoryFallback` treats every fallback alike and therefore
needs explicit neutral handling. No runtime behavior is claimed by this delivery.

## Release contract

Issue 197's 17-entry release is historical. Issue 223 explicitly authorizes exactly
those 17 stable entries plus this neutral study; schema 2 remains compatible and
library version advances from 2.0.0 to 2.1.0 (additive asset, same schema).
The normal gate still rejects missing and unexpected IDs; only the isolated
future-addition fixture uses `allow_additions=True`. The current fixture is the
nineteenth entry and must fail the release gate. Existing studies and shared wash
bytes remain pinned in `evidence/neutral-baseline.json` and the historical locks.
Pipeline edits invalidate its compiler cache, so the first build may rebuild all
studies; identical bytes, not a false claim of skipped work, prove preservation.

Direction approval remains the issue-197 comment. Neutral addition authority is
issue 223 and the supplied design brief. Metadata explicitly retains pending
fleet review; this is not new owner approval of the final pixels or deployment.

## Reproduce from repository root

Existing Python/Pillow and rsvg-convert only; no installs, downloads or generation
services. First registration on a checkout without the neutral study (after the
issue-223 pipeline change):

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_add.py skills/food-art/templates/ink-neutral.json skills/food-art/templates/ink-neutral.svg

Normal regeneration after registration:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_library.py build
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_neutral.py --bundle
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_gate.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_package.py write
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_package.py check

Canonical geometry is `sources/fallback-neutral.svg`; keep its retained template
`skills/food-art/templates/ink-neutral.svg` identical when deliberately refining.
`ink_neutral.py` renders each of six PNGs twice into a fresh temporary directory,
compares both SHA-256 values with the delivered export, checks both bundled 64px
copies and the entire bundled catalog, prints the neutral entry and asset count,
rejects a food-kind mutation and a missing neutral study, and composes
`neutral-both.png` from actual native-size pixels and labeled family controls.
The normal gate also captures a neutral phone fixture in each theme, with DOM,
image/font, console, viewport and native 64px checks. Those are fictional art
fixtures, not a deployed app or proof that the app already uses this artwork.

Review the neutral PNG and phone screenshots sequentially; Paper is deliberately
quiet and its spoon/rim are weaker than Night. No 40px recognition promise.
The final manifest must be regenerated after all evidence/docs edits.

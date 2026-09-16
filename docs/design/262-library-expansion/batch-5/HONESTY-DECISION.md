# Batch 5 — evidence and alias/study decision

All 12 identities are **evidence-free for this account (0 observed rows)** in the frozen read-only observation window. They exist for **general coverage only**, not observed demand. `coverage.json` records zero added observed rows/names and no observed-coverage uplift from batch 4.

## Decision: retain dedicated generic studies

- **Pad thai:** a labeled, generic flat-noodle plate with lime/garnish cues. It is not an assertion about any logged meal, exact recipe, protein, portion, ingredient list or nutritional contents. Those cues are visible at native 64px. The existing shipped `stir-fried-noodles` source, exports and metadata remain unchanged; vague noodle inputs must not become a Pad-thai claim merely because this image exists.
- **Boba tea:** a labeled, generic pearl-milk-tea cup with a broad straw and visible dark pearls at native 64px. Those visible distinguishing cues justify a study rather than an alias-only shortcut. It is not evidence of a drink consumed by this account or of its recipe/sugar content.

This is an honesty decision, not an effort decision. The images are defensible generic illustrations under their labels, so no alias-only exception was taken and all 12 approved identities have original editable sources and both-theme exports.

## Integration boundary

Approved alias metadata is retained, not silently reassigned. In particular, the earlier broad `milk-tea` entry includes aliases such as `bubble tea`; this art delivery does not resolve future runtime precedence merely by adding a `boba-tea` study. Generic labels or different forms (for example peanuts versus peanut butter) also require conservative representation choices. Matcher policy, ambiguity handling, alias routing, asset catalogs and bundling require their own implementation/approval lane. None were changed here.

The study is not a substitute for food identification. Where an input is vague, conflicting or unsupported, a category fallback or neutral representation is more honest than asserting the depicted dish.

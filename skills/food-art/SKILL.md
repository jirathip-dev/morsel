---
name: food-art
description: Use when adding Morsel ink-and-wash food art.
version: 0.4.0
author: Guy (jirathip-k), Hermes Agent
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [design, food, svg, incremental]
    related_skills: []
---

# Morsel food art

Author original generic food illustrations and export them offline. No runtime
generation, app asset wiring, database, profile, photo or nutrition changes.
The current edition is `docs/art/food-library-v2/`; the first delivery and
four-subject R1 gate remain historical controls, not the current authoring target.

## Current release · issue 223

Issue 223 authorizes exactly the original 17 entries plus `fallback-neutral`
(schema 2 / library 2.1.0). Category artwork travels with its category label;
the neutral study must never be presented as an identified food.
Read `references/neutral-fallback.md` for current registration, bundled-copy,
determinism and review commands. The 17-entry instructions below describe the
historical issue-197 round; the current release gate requires exactly 18 and
rejects a nineteenth fixture. App integration remains a separate lane.

## When to Use

- Add or refine an original food study within Morsel's approved ink/wash grammar.
- Export Paper/Night with stable IDs, transparent PNGs and honest provenance.
- Do not use for actual meal photos, ingredient/allergy recognition, portion
  estimation, new art directions, app integration or unauthorized publishing.

## Prerequisites

Use `terminal` from the repository root. Existing Python 3, Pillow and
`rsvg-convert` are required. Browser capture needs an existing headless engine;
set `CHROME_HEADLESS_SHELL` when it is not discoverable. No installs or API keys.
These scripts use portable stdlib/Pillow apart from external renderer/browser
commands. macOS exercised; Linux engine discovery uses PATH or the override.

Read `docs/art/food-library-v2/ART-SPEC.md`, the current issue approval and the
actual Paper/Night contact sheets using `read_file` and `vision_analyze`.
Inspect `sources/mango.svg`, `sources/stir-fried-noodles.svg` and
`sources/coffee.svg`: these are approved controls. Transfer their grammar, not
geometry. Do not return to the first delivery's uniform JSON path construction.

## How to Run

Short invocation: “Use food-art; preserve approved controls, refine <food>.”

1. Record the issue's bounded delta. Use `terminal` to append a phase:

       PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_library.py event --phase authoring-start

2. With `write_file`/`patch`, author the named SVG under
   `docs/art/food-library-v2/sources/`. It uses a 256×256 viewBox and dimensions,
   named editable groups, exactly one `<!-- WASH_DEFS -->` insertion and palette
   tokens. `wash-defs.svginc` supplies the unchanged seeded wash/dry filters.
   Metadata is in `subjects.json`; never rename an existing ID to hide a revision.
   Completion means food-specific organic geometry, not just grain over an icon.
3. Use `terminal` for an incremental build:

       PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_library.py build

   Check `rebuilt`/`skipped` IDs and raw exit. One changed source rebuilds its two
   masters and six PNGs, not neighboring foods. Final sizes: 64/192/512.
4. Refresh proofs through `terminal`, then inspect them with `vision_analyze`
   sequentially, especially labeled native 64px and the diagnostic 40px image:

       PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_proofs.py
       PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_capture.py

   All catalog IDs must appear in phone fixtures in both themes. Changes after
   a capture invalidate it. Mechanical PASS does not equal visual approval.
5. Append authoring/review phase ends separately. Report wall-clock windows
   honestly: prerequisite reads and tool waits are not uninterrupted hand time.
   Renderer time, proof composition, capture, verification and packing remain
   separate. Parallel authoring windows overlap; do not sum them as project time.
6. Run the full gate through `terminal` and read actual logs. Update checksum
   packaging only after final evidence/docs edits. Post the committed exact head
   to the authorized owner; orch owns product PR/review/staging integration.

## Quick Reference

Use `terminal` at repository root:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_gate.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_library.py verify
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_tests.py
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_package.py write
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_package.py check

For a separately authorized future addition (not this 17-entry release), author
one SVG and metadata matching `templates/ink-food.json`, then use `terminal`:

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_add.py path/to/metadata.json path/to/study.svg

The add helper validates before registration, rejects an existing ID, exports
only the new asset and verifies with explicit additions allowed. It does NOT
approve new art. The issue-197 release gate intentionally rejects an 18th entry.
A future issue must update its acceptance set, proof cohorts and version policy;
never silently relax this round's closed-set release gate. The additive path was
exercised with a synthetic copied-geometry fixture, not an extra delivered food.

## Sample-first versus approved expansion

`references/sample-first-refinement.md` records the earlier four-subject gate.
Issue 197 approval comment `5646485904` accepted the direction at
`3b2d880c65553ef190c7072033cac5904a8c1f87` and superseded that sample-only stop.
For a newly rejected direction, still use a cheap named-subject gate before a
full build. `references/approved-expansion.md` records this exercised expansion,
chicken/fallback corrections, cache tests and review boundary.

## Cache and source contract

Canonical editable geometry is now SVG, with shared seeded wash definitions.
Metadata is separate. Generated theme masters remain editable, but deliberate
edits must be ported into the tokenized source before rebuilding. Compiler,
shared helpers, renderer version, source bytes and wash definitions key the
cache; output hashes are checked before a skip. Missing/tampered outputs rebuild
only their owner. Source validation runs even on hits. Untouched exports keep
both SHA-256 and mtime; aggregate proofs and timing reports are separate.

## Pitfalls

- The old `library.py`/JSON pipeline is retained for first-delivery reproduction,
  not for authoring the approved refinement. Do not regenerate old controls.
- A strong bone silhouette resolves chicken/bread ambiguity more effectively
  than adding fibres to evenly cut pale slices. Keep the Paper bone edge visible.
- A flat grain surface looks like broth. Break the rim with a dry irregular heap.
- A single large egg overpowers Protein. Balance the grouping; require a category
  label. The art does not identify the meal's actual ingredients or cut.
- Pale vessel edges and fine texture weaken at 40px. The accepted placement is
  labeled 64px; exact food variety/cooking method is not image-only recognition.
- Preserve the approved three controls byte-for-byte, including shared wash
  definitions. Never “harmonize” them to match later additions.
- No external SVG resources, scripts, event handlers, unresolved tokens or new
  palette values. A transparent canvas is not an instruction to erase cream food.
- Build is not a transaction: a renderer failure can leave partial new outputs.
  Fix the cause and rerun; do not report complete until verify/capture pass.
- Use fresh temporary browser profiles. No installs, user browser or shared
  session mutation. Headless captures are real; composed contact sheets are not
  screenshots of a deployed app.
- Source-batch JSONs describe the initial stage; final parent corrections are
  named separately. Their old source hashes are not the release manifest.
- Optional real-click probe: run `references/browser-interaction-probe.py` through
  `browser_exec` with the repository `ROOT` prebound. After navigation, body/root
  can briefly be null; guard both and wait for URL/load/fonts before assertions.
  A probe-read race is not a page JavaScript error. Its final evidence is separate
  from the standalone screenshot gate.
- This repo lacks the Hermes Brain docs generator/validator. Use the repository
  gate's local frontmatter/reference tests, not another profile's tools or state.

## Verification

`ink_library.py verify` checks the exact 17 IDs, preserved identity metadata,
source/catalog/master parity, SVG safety/palette, alpha/padding, cache hashes,
first-delivery/R1 control hashes and approved three source/master/64px bytes.
`ink_tests.py` exercises clean-room byte reproduction, no-op, real-pixel source
mutation, missing/tampered export repair, reject paths and one-item addition in
an isolated fixture. `ink_capture.py` checks fonts/images, console errors,
44px links, native 64px placement, row visibility and all-ID theme coverage.
`ink_gate.py` retains raw exits and logs; `ink_package.py` pins the final files.
The visual review and fleet review verdict are separate from those checks.

# .brief.md — DESIGN LANE #228: tactile food journal — bounded art & interaction comparison

ABSOLUTE CHECKOUT PATH: `/Users/jirathip/.herdr/worktrees/morsel/design-tactile-journal`
(`cd` there first; read THIS file from that directory and execute it fully.)

**Gate-role note:** this lane is registered for gate compatibility; the real contract is a
**design deliverable — you MUST create and write the specified artifacts** (prototypes,
screenshots, documentation). Do not self-limit to read-only.

## Goal

Owner-approved **bounded design exploration, NOT implementation** (issue #228). Produce **two
interactive phone-size versions of the SAME screen and the SAME data** so the owner can choose:

- **Variant A** — refined *current* ink-wash journal, with cleaner rows.
- **Variant B** — a **simplified tactile** journal: stronger food silhouettes, broad colour
  shapes, restrained texture, deliberate spacing.

Inspiration: the tidying-game principles referenced in the issue — **never trace, copy or
closely imitate its assets or distinctive compositions**. Morsel's palette, typography,
navigation and calorie calculation must be preserved. **No full reskin and no wholesale
food-library rewrite.**

## Required content (identical data across both variants)

- A **fictionalized fixture** matching the owner's lunch foods: **focaccia, mortadella,
  stracciatella cheese, grilled vegetables**.
- Include an **unknown-food fallback** case and a **stored-photo** case.
- **Paper and Night** for both variants.
- Apply the already-decided product rules in the prototypes: **rows are always illustrations**
  (a real photo appears **only inside detail**, per #223), and **confidence/source/notes live
  inside the detail sheet** — no row verify/manual/confidence text and no "Needs Review"
  section (per #227).
- **Label proposed/unshipped behaviour honestly** in the artifacts (these are concepts, not
  shipped UI).

## Interactions (exactly two — do not add more)

1. **Tap a food row → detail sheet** (a subtle lift is optional).
2. **Save an edit → return to the updated row** with restrained confirmation.

For both: demonstrate the **pending vs failure** distinction, **no fake server success**,
and a **Reduce Motion alternative**. Prototype state only — **no backend calls and no
user-data writes**. Do not add drag-to-log, rewards for undereating, or new page-turn
mechanisms.

## Deliverable & acceptance

- **Two live mobile previews** (phone-size), plus **side-by-side screenshots** and a
  **written recommendation**.
- **Reproducible source artifacts and verification** (someone else must be able to re-run and
  get the same result; state the exact command).
- Exercise **both interactions, the failure state and the reduced-motion state**; **no clipped
  content at phone size**; food **recognizable without zoom**; nutrition **easy to scan**;
  clear **accessible detail access**; fast tactile response; **distinctly original** Morsel art.
- Use **original representative art only** — do **not** replace or modify the shipped catalog
  in `app/Resources/FoodArt/` or the approved library in `docs/art/`.
- Read the current design tokens and art (`docs/DESIGN.md`, `docs/art/food-library-v2/ART-SPEC.md`)
  and the relevant issue specs (#223, #227) before drawing.

## Fence — touch ONLY these paths

- Your prototype/docs output directory for this lane (e.g. `docs/design/tactile-journal/` or
  the lane's own artifact folder) and its screenshots.
- Nothing under `app/` (no Swift, no `project.yml`, no bundled resources), nothing under
  `docs/art/food-library-v2/`, no tests, no workflows, no server/db/migrations.

## Stop contract (explicit)

**Stop at the design handoff.** Do **NOT** open a PR, do **NOT** merge, and take **no main /
release / TestFlight / deploy action**. Future row/detail implementation and any further
library expansion require **separate owner approval** — do not start them.
Commit on your own branch only: `git push -u origin design-tactile-journal`.

## Evidence to deliver

- The two previews (paths/URLs), the side-by-side screenshots (Paper + Night), the failure and
  reduced-motion states, the fixture used, the exact reproduce command, and a short
  recommendation for A vs B with the trade-offs.
- `.report.md` in the worktree: branch + head sha, artifacts + paths, the reproduce command,
  what you verified, and what remains **unverified** (e.g. anything only a physical device or
  the owner's judgement can settle).
- End `.report.md` with: `NOT MERGED; not opened as PR; no deploy; no production writes.`

## Model policy (registry-derived; do not hand-edit)

- ORCH: backend=hermes profile=fleet-orch.
- DESIGN: this lane runs on the **designer** profile.
- NO FALLBACK: false.
- Model and reasoning effort are profile-owned: read the live values with `hermes config get`;
  **never hand-edit the profile**.

## Output contract

Final message: branch, exact head sha, pushed confirmation, artifact paths, the reproduce
command, and the `.report.md` path.

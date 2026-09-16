# Issue 262 subject-list round (current work, pre-approval)

Issue 262 expands the shipped ink/wash library toward ≥100 food identities in
review-gated batches of ~20–25. **This round delivers the proposed subject list
only.** `expansion-262/subjects-proposed.json` is the editable proposal metadata;
`ink_expansion_plan.py render` deterministically renders `SUBJECT-LIST.md`,
`coverage.json`, `alias-proposals-260.json` and `SHA256SUMS.json` from it, and
`check` verifies reproduction. Nothing in the expansion directory is approved
artwork, and no source/master/export/catalog/bundled file is created or modified
until the owner approves the list and each production batch.

## Commands (repository root)

    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_expansion_plan.py render
    PYTHONDONTWRITEBYTECODE=1 python3 skills/food-art/scripts/ink_expansion_plan.py check

`render` is deterministic: same inputs → byte-identical outputs. `check` re-renders
into a temp dir, compares hashes, and fails (exit 1) on proposal invariants
(duplicate/colliding IDs or aliases against the shipped catalog), manifest drift,
tampered committed outputs, or raw logged names leaking into tracked files.
Without the private local dump, coverage-bearing files are verified against the
committed manifest only (tamper detection), never re-derived.

## Privacy contract

The repository is public. Raw `public.meal_items` names are read once via a
read-only Management API SELECT and stored **only** in untracked `.lane-logs/`.
Aggregate counts and the five names already published in issue #262/#260 are the
only row-level names in tracked outputs; `check` enforces this leak gate.

## Shipped-asset immutability

`SHA256SUMS.json` pins `subjects.json`, `catalog.json` and the library's
`SHA256SUMS.json` before any production batch. Batch 1 (after owner approval)
must prove byte-identity of all 18 shipped assets by hash comparison, per the
issue's acceptance criteria.

## Batch process (post-approval, per batch)

Follow the existing pipeline conventions: tokenized 256×256 sources with the
shared `wash-defs.svginc`, per-theme masters, 64/192/512 RGBA exports,
`subjects.json` + `catalog.json` entries via `ink_add.py`, reproducible rebuild,
contact sheets and labeled 64 px proofs in both themes, then STOP for owner
review. The release gate's acceptance set, proof cohorts and library version are
re-pinned explicitly per batch; they are never silently relaxed.

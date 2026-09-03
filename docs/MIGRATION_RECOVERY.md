# Production schema reconciliation runbook (issue #76)

Morsel's production Supabase project was provisioned out of band: it has **no
migration ledger**, and the live schema drifted from the canonical chain in
`db/migrations/0001..0009`. Issue #76 documented the missing pieces
(`weight_logs.measured_at` rename, `food-images` storage assets/policies,
`upsert_food_catalog` provider-cache routine/grants, `energy_burned_logs`,
fractional-calorie goals) — but *the exact applied-vs-pending state must be
classified, never assumed*.

This repository ships a **fail-closed, idempotent reconciliation runner** that
inventories the live schema against the complete authoritative end-state
contract of every migration, classifies each migration
`VERIFIED_PRESENT` / `REPAIR_REQUIRED` / `BLOCKED_AMBIGUOUS`, converges
missing/partial end states with explicit idempotent SQL inside **per-step
atomic transactions**, records the ledger row **only after that step's
in-transaction postcondition passes**, and re-verifies the full chain before
reporting success.

> IMPORTANT: no command in the issue #76 implementation lane was run against
> the production project, and nothing below touches production until a human
> explicitly performs step 3.

## Confirmation phrase

`morsel-issue-76-prod-schema-reconcile-apply` — byte-exact, tied to issue #76,
required by `--apply`. This is an anti-footgun token, not a credential; the
current human gate is **privileged manual dispatch** (only users with write
access can dispatch a `workflow_dispatch` run) plus this exact phrase. It is
documented here and pinned in `scripts/migration-recovery.mjs`.

## The five phases

### 1. Read-only reconciliation/report (no production risk)

Requires the two repo secrets as **environment variables only**:

```bash
SUPABASE_PROJECT_REF=<20-char ref> SUPABASE_ACCESS_TOKEN=<token> \
  node scripts/migration-recovery.mjs
```

No flags = plan mode. It issues only a fixed, allowlisted set of `SELECT`
statements (verified by unit tests), prints a deterministic classification
table for 0001..0009 with object-level reasons and row counts, and exits:

- `0` — nothing blocked; a repair plan exists or everything is already canonical;
- `1` — plan blocked (ambiguous/conflicting drift, data dependencies, unknown
  or gapped ledger rows);
- `2` — usage error (missing/malformed env or arguments).

Read-only data dependencies block BEFORE any write when a repair would
silently change or destroy data, including: duplicate `(user_id, timestamp)`
rows or non-positive `kg` before 0007/0008 constraints, and — for 0009 —
`goals.calorie_target_kcal` values that would change or overflow under the
canonical `numeric(10,1)` type (e.g. `100.05` would round to `100.1`;
magnitudes above `9,999,999,999.9` overflow). The dependency query is a fixed
allowlisted `SELECT` that only counts rows, never outputs values, and only
casts values of supported numeric-family types (any other observed type with
rows fails closed). A blocked 0009 means a human must reconcile the offending
values to one-decimal precision (or remove them) before apply; the conversion
itself then stays lossless.

Secrets and response contents never appear in output; raw env values with
leading/trailing whitespace or control characters are rejected before any
request. This phase is safe to run from any checkout.

### 2. Reviewed code/CI

Merge the reviewed PR to `main` first. A normal merge causes **ZERO
production SQL**: the apply workflow is `workflow_dispatch`-only and every
runner write path needs `--apply --confirm`.

### 3. Explicit human-approved production workflow dispatch (the only write step)

1. Open **Actions → Deploy Migrations (Recovery Apply)** on `main`.
2. The job targets the **`production` environment**. Repository environment
   reviewer protection is **NOT currently configured** (GitHub API
   `protection_rules=[]`); the current human gate is privileged manual
   dispatch plus the exact confirmation phrase. As optional human settings
   hardening BEFORE any apply, enable environment protection rules (required
   reviewers/approvals) for `production` in repository settings — this is a
   settings change outside this repository's code.
3. Type the exact confirmation phrase from above into the required
   `confirmation` input and dispatch.
4. The job **fails closed** (nonzero) when secrets or the confirmation are
   missing — it never skips green.

The job runs, from the exact `main` SHA:

```bash
node scripts/migration-recovery.mjs --apply --confirm "$CONFIRMATION"
```

Inside the runner: fresh inventory → per-migration classification → if any
`BLOCKED_AMBIGUOUS` or plan-level conflict exists, **no write statement is
executed** and the run exits 1 → otherwise one `BEGIN..COMMIT` transaction per
migration (converge SQL + in-transaction postcondition guard + ledger insert)
→ full read-only re-inventory proving every 0001..0009 contract and preserved
row counts. A failed/partial step can never leave DDL applied without its
ledger row, and re-running is always safe (idempotent, resumable).

CLI usage for operators who run it themselves (same guards apply; apply
requires a **current `main` checkout** and refuses non-main branches):

```bash
SUPABASE_PROJECT_REF=... SUPABASE_ACCESS_TOKEN=... \
  node scripts/migration-recovery.mjs --apply --confirm 'morsel-issue-76-prod-schema-reconcile-apply'
```

### 4. Post-apply read-back

The runner already prints the post-apply ledger, per-migration verification
and row counts. Independently verify with read-only queries:

```sql
select name from public.migration_ledger order by name;           -- 9 canonical rows
select column_name from information_schema.columns
  where table_schema = 'public' and table_name = 'weight_logs'    -- measured_at, source, ...
  order by column_name;
select count(*) from public.weight_logs;                           -- unchanged
select count(*) from public.energy_burned_logs;                    -- unchanged
```

The plan-mode report (`node scripts/migration-recovery.mjs`) is the cheapest
post-apply proof: every migration must read `VERIFIED_PRESENT`.

If 0009 was blocked pre-apply by the precision data dependency, the read-back
must confirm the reconciled `goals.calorie_target_kcal` values survived
unchanged (one-decimal values; nothing rounded by the conversion):

```sql
select user_id, calorie_target_kcal from public.goals order by user_id;
```

### 5. Human live-app acceptance (NOT automatic)

The runner only proves schema contracts. Do not claim app/runtime closure
until a human verifies the app path that errored in issue #76:

- skip onboarding → weight trend/dashboard loads (uses `measured_at`);
- `get_energy_burned` returns (table + RLS owner policy);
- an uploaded meal's `food-images` storage path resolves (bucket + owner
  policies).

## Rules for future migrations (000N)

- New migrations are append-only `db/migrations/000N_name.sql`.
- Once the ledger exists (created by the recovery runner), **`node
  scripts/apply-migrations.mjs`** applies only migrations newer than the
  newest recorded row and refuses anything older. It NEVER bootstraps the
  ledger: a missing or empty ledger fails with ZERO writes, so it cannot be
  used to adopt an unverified schema.
- Each allowed append executes as ONE Management API request: the migration
  SQL and its ledger insert run inside a single `BEGIN..COMMIT` transaction,
  so a crash can never leave DDL applied without its ledger row. Migration
  files containing their own transaction control (`begin`/`commit`/
  `rollback`/`savepoint`/`end` at statement level) are rejected before any
  write — plain DDL/DML only, the wrapper owns the transaction.
- **There is no blind adoption anymore**: `--adopt` was removed in issue #76.
  A migration may be recorded only after the recovery runner verifies its
  complete authoritative end-state contract under the human confirmation.
- The recovery runner refuses any checkout whose manifest is not exactly
  0001..0009; extending the canonical set is a reviewed code change.

## Guardrails

- `scripts/migration-reconcile.mjs` stays read-only (fixed SELECT allowlist).
- Recovery runner statement surface: fixed inventory SELECTs; write surface is
  a fixed set of assembled transaction strings built from static fragments.
  No SQL text, migration filename, project URL, or query text is accepted from
  CLI input.
- `db/migrations/0001..0009` are byte-immutable; the runner never executes
  them (convergence SQL is pinned by tests to the same definitions).
- Missing/unknown ledger rows, gapped ledger prefixes, ambiguous
  `weight_logs` timestamp columns, duplicate data rows, and non-canonical
  constraints/policies/unique indexes all fail closed.

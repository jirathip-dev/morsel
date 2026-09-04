# Morsel infrastructure as code (issue #78)

Committed source of truth for recreating and day-2-operating the live Morsel
stack: Fly.io (MCP origin), Supabase (Auth/Postgres/RLS + retained legacy Edge
Function), Vercel (consent skin), and Resend (email). This directory is
file-only: nothing here runs against the live stack by itself.

## Surfaces and where their source of truth lives

| Surface | Source of truth | Operator scripts (this dir) | Runbook |
| --- | --- | --- | --- |
| Fly.io app `morsel-mcp` | `fly.toml`, `Dockerfile`, `server/fly-entrypoint.ts` | `fly/app-create.sh` (guarded), `fly/check-machine-count.sh` (read-only) | `docs/FLY_DEPLOY.md` |
| Supabase project (Auth config, secrets by name) | `supabase/config.json` (canonical auth/SMTP/template values), `supabase/secrets.json` (secret NAME mapping) | `supabase/config.mjs`, `supabase/secrets.mjs` | `docs/SUPABASE_OPERATIONS.md` |
| Supabase schema + migration ledger | `db/migrations/*.sql`, ledger tracked by `scripts/migration-reconcile.mjs` (read-only) + `scripts/migration-recovery.mjs` (human-gated apply, issue #76) | — | `docs/MIGRATION_RECOVERY.md`, `docs/SUPABASE_OPERATIONS.md` |
| Vercel consent skin | `authorize-ui/` (repo-committed, auto-deploys from `main`) | `vercel/README.md` captures the one-time project creation | `docs/VERCEL_OPERATIONS.md` |
| Resend | sender + key NAMES in `supabase/config.json` / `supabase/secrets.json` (values only in the local store) | — | `docs/SUPABASE_OPERATIONS.md` |

## Why each choice exists

`docs/INFRA_DECISIONS.md` — the decision log. Read it before changing any
surface; every entry names the issue that drove the choice and the trap that
must not be re-litigated.

## Drift policy (read-only)

`docs/DRIFT.md` — what drift means per surface, the exact read-only commands,
and the fail-loud contract. Drift checks never mutate: they exit nonzero on
any mismatch so a human can decide.

## Secret policy (names only, always)

- **No secret VALUE is ever committed in this repo.** This directory contains
  names, target mappings, and documented references to the local store.
- The local store is `~/.config/zsh/secrets.zsh` (or a store path given by
  the `SUPABASE_SECRET_STORE` environment variable). Scripts read values from
  the store **by name** at run time; they never print or log values, and every
  error path suppresses raw response/request text that could carry a value.
- Supabase Management API access uses environment names
  `SUPABASE_PROJECT_REF` and `SUPABASE_ACCESS_TOKEN` (the same convention as
  `scripts/migration-reconcile.mjs`); locally their values come from the
  store names `SUPABASE_PROJECT_REF_MORSEL` / `SUPABASE_ACCESS_TOKEN_MORSEL`.
- The SMTP password on Supabase is the Resend API key; its store name is
  `RESEND_API_KEY_MORSEL` and the bootstrap/apply scripts read it by that
  name only when a human runs an apply.

## Mutation guards (static proof target)

Every script in this directory is either read-only or defaults to dry-run
and refuses to act without an explicit operator flag (`--apply` / `--yes`):

- `fly/check-machine-count.sh` — read-only (`fly machine list`).
- `fly/app-create.sh` — dry-run by default; `--apply` required; refuses the
  live app name `morsel-mcp` unconditionally.
- `supabase/config.mjs check|diff` — read-only GETs against the Management
  API; only `apply` writes, and only with `--yes`.
- `supabase/secrets.mjs` — dry-run by default; `--apply` required to POST
  secret values to the Management API.
- `supabase/config.json` / `secrets.json` — declarative values and name
  mappings; nothing executes.

## Fresh-project recreation (DRY RUN)

`docs/FRESH_PROJECT_DRY_RUN.md` documents a from-scratch recreation (new Fly
app + new Supabase project + new Vercel project) with the full verification
checklist. This lane wrote the doc and scripts only; actually executing a
fresh-project dry run against real new projects is a human-gated action.

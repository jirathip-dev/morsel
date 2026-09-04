# Morsel Supabase operations (issue #78)

Supabase is the Auth/Postgres/RLS/data store behind the Morsel stack
(project ref in the local store as `SUPABASE_PROJECT_REF_MORSEL`, Tokyo
region). This runbook covers the **day-2 operations** for the parts of
Supabase that are NOT schema: Auth config (custom SMTP, magic-link template,
rate limits) and project secrets for the retained legacy Edge Function.
Schema/migration operations live in `docs/MIGRATION_RECOVERY.md` and the
canonical SQL in `db/migrations/`.

Committed sources of truth in `infra/supabase/`:

| File | Role |
| --- | --- |
| `config.json` | Canonical Auth config values (no secrets): SMTP host/port/user/sender, OTP length, email rate limit, magic-link subject + `{{ .Token }}` template invariant |
| `config.mjs` | Management API tool: `check` (read-only drift), `diff` (read-only), `apply` (human-gated) |
| `secrets.json` | Secret NAME mapping: project secret target -> local-store variable name |
| `secrets.mjs` | Bootstrap project secrets BY NAME from the local store (dry-run default, `--apply` human-gated) |
| `config.test.mjs` | Unit tests for payloads and pure logic (no network, no live project) |

## Environment (names only — values from the local store)

| Env var used by scripts | Local store name that holds the value |
| --- | --- |
| `SUPABASE_PROJECT_REF` | `SUPABASE_PROJECT_REF_MORSEL` |
| `SUPABASE_ACCESS_TOKEN` | `SUPABASE_ACCESS_TOKEN_MORSEL` (Management API token) |
| `RESEND_API_KEY_MORSEL` | same name (SMTP password == Resend API key; used by `apply` only) |
| `SUPABASE_SECRET_STORE` (optional) | path override for the store (default `~/.config/zsh/secrets.zsh`) |

Loading them locally is a shell action in the human's environment, e.g.:
`source ~/.config/zsh/secrets.zsh`, then
`export SUPABASE_PROJECT_REF="$SUPABASE_PROJECT_REF_MORSEL"` and
`export SUPABASE_ACCESS_TOKEN="$SUPABASE_ACCESS_TOKEN_MORSEL"`. These exact
export lines are never committed; they reference store names only.

## Canonical Auth config (what `config.json` pins)

Values come from the live-stack inventory in issue #78 and the #60/#74
decisions (`docs/INFRA_DECISIONS.md` D3/D4):

- SMTP: host `smtp.resend.com`, port `465`, user `resend` (literal), sender
  `Morsel <onboarding@resend.dev>` (`smtp_sender_name` + `smtp_admin_email`).
  The SMTP password is the Resend API key — a SECRET, never in `config.json`;
  `config.mjs` guards against ever pinning it.
- Email OTP length: `6` (`mailer_otp_length`).
- Email rate limit: `30` per hour (`rate_limit_email_sent`).
- Magic-link template: subject `Your Morsel sign-in code`; the template body
  is pinned by INVARIANT only — it must contain `{{ .Token }}`
  (`templateInvariant` in `config.json`). The full human-authored body is
  preserved by `apply` (never overwritten wholesale).

## Drift check (read-only, fail loud)

```bash
node infra/supabase/config.mjs check   # default command; same as `check`
```

- GETs `/v1/projects/{ref}/config/auth` and asserts every pinned value plus
  the `{{ .Token }}` invariant.
- Exit 0 = no drift; exit 1 = drift (each mismatch printed); exit 2 = usage
  or missing env. It never writes. Safe to run from a cron or a read-only CI
  job; see `docs/DRIFT.md`.

## Previewing a re-apply (read-only)

```bash
node infra/supabase/config.mjs diff    # prints intended vs live mismatches
```

## Config re-apply (MUTATING — human-gated)

```bash
node infra/supabase/config.mjs apply --yes
```

Behavior: GET live config -> overlay the pinned canonical keys (everything
else, including the template body and unknown keys, is preserved) -> PUT ->
re-GET and re-run the `check` assertions; exit 0 only when the postcondition
passes. The SMTP password comes from env `RESEND_API_KEY_MORSEL` when set,
otherwise the live `smtp_pass` is preserved; if neither exists the script
refuses to PUT. Run `diff` first and read the output before `apply`.

Rollback of a bad re-apply: re-run `apply` from the previous good commit of
`infra/supabase/config.json` (the script converges pinned values; template
body and secrets are preserved), then re-run `check`. There is no other
state to undo — `apply` touches only Auth config.

## Project secrets bootstrap (MUTATING — human-gated, by NAME)

The retained legacy Edge Function reads `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
and `MORSEL_OAUTH_SIGNING_KEY` from its project environment. Their values
live in the local store only:

```bash
node infra/supabase/secrets.mjs          # DRY RUN: prints target names only
node infra/supabase/secrets.mjs --apply  # human-gated write
```

- Values are read from the store by name (`infra/supabase/secrets.json`
  mapping) and POSTed to the Management API secrets endpoint; they are never
  printed, logged, or committed.
- A missing store name fails loudly and nothing is applied (no partial
  secret set).
- `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` is deliberately excluded: per
  `authorize-ui/README.md` the repository never sets that live secret; it is
  a human-gated config step (issue #74).

## Schema + migration ledger (reproducibility integration from #76)

Reproducing the stack includes the schema ledger, not just config:

- Read-only reconcile (drift): `node scripts/migration-reconcile.mjs`
  (no arguments; env `SUPABASE_PROJECT_REF` + `SUPABASE_ACCESS_TOKEN`).
  Inventories the hosted schema and reports ledger/sentinel presence —
  see `docs/MIGRATION_RECOVERY.md` and `docs/DRIFT.md`.
- Apply path (human-gated): `scripts/migration-recovery.mjs --apply` with the
  byte-exact confirmation phrase via the `Deploy Migrations` workflow
  (workflow_dispatch only; apply OFF by default, #83) or the documented CLI.
- Fresh project: apply `db/migrations/*` in numeric order with ledger
  bootstrap per `docs/FRESH_PROJECT_DRY_RUN.md` step S2.

## Verification checklist (live probes)

Run after any Supabase config/secrets change (read-only probes):

1. `node infra/supabase/config.mjs check` -> exit 0 (all pinned asserts).
2. `node scripts/migration-reconcile.mjs` -> exit 0 and ledger/local
   migration sets consistent.
3. End-to-end auth smoke through the stack (human, read-only against live
   endpoints): the Fly health/metadata/session-regression and consent-POST
   probes in `docs/FLY_DEPLOY.md` and `docs/VERCEL_OPERATIONS.md`, because
   Supabase Auth sits behind the Fly origin.

# Morsel infrastructure drift checks (issue #78)

Drift = the live stack no longer matches the committed source of truth.
Every check below is READ-ONLY: it reads live state and exits nonzero on
mismatch so a human can decide. No check deploys, scales, writes config, or
sends email. Mutating fixes are separate human-gated actions named in each
runbook.

## Policy

- Run `check`-class commands after any change to the corresponding surface,
  and on a schedule/cron or read-only CI job where convenient. Exit 0 = no
  drift. Fail LOUDLY (nonzero + message) — never a silent skip.
- When a check reports drift, first confirm it is real (read the reported
  mismatch), then apply the human-gated fix from the runbook, then re-run
  the check to green.
- The checks require the operator environment (auth) but no secret VALUES
  pass through the terminal: Supabase env names come from the local store
  (`docs/SUPABASE_OPERATIONS.md`), Fly uses `fly auth` in the human
  environment, and the consent/health probes are unauthenticated GETs/POSTs
  against public endpoints.

## Per-surface checks

### Supabase Auth config (SMTP / OTP / template / rate limit)

```bash
node infra/supabase/config.mjs check
```

Asserts against the live Auth config: SMTP host `smtp.resend.com`, SMTP user
`resend`, sender `Morsel <onboarding@resend.dev>`, OTP length `6`, email rate
limit `30`, magic-link subject, and template contains `{{ .Token }}`.
Exit 1 on any mismatch. Read-only (one GET). Fix: `apply` (human-gated) per
`docs/SUPABASE_OPERATIONS.md`.

### Supabase schema + migration ledger

```bash
node scripts/migration-reconcile.mjs
```

Read-only reconcile of the hosted schema against `db/migrations/*` and the
`public.migration_ledger` (issue #76/#12); exits nonzero on inconsistency.
Fix: human-gated recovery apply per `docs/MIGRATION_RECOVERY.md`.

### Supabase project secrets (by name)

No value-level drift check exists (secret VALUES are never readable back by
design). The name-level check is the bootstrap dry run:

```bash
node infra/supabase/secrets.mjs
```

Exit 0 means every mapped store name exists and the targets are ready to
write; exit 2 (fail loud) means the store is missing a name or the mapping
is invalid. The `--apply` write is human-gated (`docs/SUPABASE_OPERATIONS.md`).

### Fly machine count

```bash
infra/fly/check-machine-count.sh [app-name]   # default: morsel-mcp
```

Read-only `fly machine list`; exits 0 only when exactly one machine exists
and is started. Exit 1 = drift (fix: `fly scale count 1 -a <app>` — human
action, `docs/FLY_DEPLOY.md`). Exit 2 = CLI/auth/parse problem.

### Vercel consent surface

No Vercel token is stored or referenced (none exists on the project), so
drift detection is the deployed-page probe in `docs/VERCEL_OPERATIONS.md`
(checklist item 1): the live `/authorize` page must carry the committed Fly
form action `https://morsel-mcp.fly.dev/mcp/authorize`. Source-level pin:
`authorize-ui/authorization.test.js` under `npm test`.

### Fly origin health/metadata (whole-stack liveness)

The probes in `docs/FLY_DEPLOY.md` step 6 are the stack-level read-only
verification: `/health`, OAuth metadata on the Fly base, the 401 challenge,
and the session regression (three requests, one process). The session
regression also runs offline against committed code via
`npm run test:fly` (Bun) — see `docs/FLY_DEPLOY.md`.

## The one write each check is allowed to recommend

| Check | Human fix (mutating) |
| --- | --- |
| Supabase config | `node infra/supabase/config.mjs apply --yes` |
| Schema reconcile | `scripts/migration-recovery.mjs --apply` (confirmation phrase) |
| Fly machine count | `fly scale count 1 -a morsel-mcp` |
| Vercel page | merge the `authorize-ui/` fix on `main` |

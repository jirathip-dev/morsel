# Morsel infrastructure decision log (issue #78)

WHY the live stack is shaped the way it is. Every entry names the issue that
drove the choice and the platform trap it avoids. Before changing a surface,
read this log: the entries below are the recorded reasons future changes must
not silently re-litigate. Companion documents: runbooks
(`docs/FLY_DEPLOY.md`, `docs/SUPABASE_OPERATIONS.md`,
`docs/VERCEL_OPERATIONS.md`), drift checks (`docs/DRIFT.md`), and the
from-scratch recreation dry run (`docs/FRESH_PROJECT_DRY_RUN.md`).

## D1. MCP hosting: single-process Fly origin, not Supabase Edge Function isolates (#71, #72)

Supabase Edge Function isolates cannot hold the in-memory MCP session map:
`initialize`, `notifications/initialized`, and `tools/list` land on different
isolates, so sessions are lost between requests and clients see 0 tools
(live reproduction in #72). The canonical MCP endpoint is therefore one long-
lived Bun process on Fly (`server/fly-entrypoint.ts`, `Dockerfile`,
`fly.toml`) that owns the session map for its lifetime. Supabase remains the
Auth/Postgres/RLS store; only the MCP hosting origin moved.

Consequences pinned by tests: one process (`fly.toml` `min_machines_running
= 1`, `auto_stop_machines = false`), one machine (operational state — see
D6), route shape on the origin root (`/health`, `/mcp`, no doubled prefixes),
canonical URL `https://morsel-mcp.fly.dev/mcp` referenced by build config,
onboarding copy, OAuth metadata, and the consent page (#74/#75).

## D2. Consent surface: static Vercel page posting DIRECTLY to the Fly OAuth backend (#74)

The browser consent page must post OAuth stage forms to a backend that
implements `/mcp/authorize`. Two platform traps force the current shape:

- **Supabase free shared domain rewrites Edge Function HTML to `text/plain`**
  (the #66/#68 regression): serving consent HTML from a Supabase Edge
  Function is impossible on the free tier, so the HTML lives on Vercel.
- **Vercel legacy `routes` cannot proxy external POSTs**: `vercel.json`
  routes are static rewrites only. The consent skin therefore does a direct
  cross-origin form POST from the browser to the Fly origin
  (`authorize-ui/params.js` `AUTHORIZE_URL`), with no fetch/XHR, no CORS, no
  proxy, and no analytics.

After the Supabase gateway began 401-Basic-challenging Edge Function form
POSTs, the destination moved to Fly (`/mcp/authorize` on the Fly origin) and
the authorize-ui test pins that action URL (#74, PR #77).

## D3. Sign-in path: email one-time code (OTP), no Apple web OAuth (#60)

The consent/sign-in path is a generic page with an email one-time code
(six digits) — a deliberate product decision recorded in #60: no Apple web
OAuth for the browser flow. Auth stays on Supabase Auth (email OTP for
existing users, plus refresh), the MCP server authenticates with the user's
access token, and every table stays user-scoped under RLS.

## D4. Email: Resend via custom SMTP, with the sender constraint (#60 context)

Transactional email (magic-link OTP) goes through Resend as custom SMTP on
Supabase Auth: `smtp.resend.com:465`, SMTP username literally `resend`,
password = the Resend API key. The free-tier sender constraint is recorded in
the issue inventory: `onboarding@resend.dev` delivers **solely to the Resend
account owner**, so the OTP recipient is the account owner. Two Resend API
facts matter operationally: requests need a `User-Agent` header (else 403
code 1010) and the SMTP username is the literal `resend`, not an email
address. Canonical values: `docs/SUPABASE_OPERATIONS.md`; secret VALUE never
leaves the local store (`RESEND_API_KEY_MORSEL`, name only).

## D5. Legacy Supabase Edge Function `mcp`: retained, not client-facing

The Edge Function transport is legacy/retired for clients: no client-facing
URL publishes it (the pre-#57 `/mcp/mcp` alias is not published), but the
function stays deployed for backend/rollback compatibility until it is
separately retired (a human decision). Its project secrets are kept in sync
by name (`infra/supabase/secrets.mjs`); the deploy workflow
(`deploy-edge-function.yml`) runs only on human `workflow_dispatch`. The
legacy share of the OAuth signing key (`MORSEL_OAUTH_SIGNING_KEY`) must stay
the same value as Fly's while the function is retained.

## D6. Fly machine count is OPERATIONAL state, not toml state

`fly deploy` auto-created a second HA machine once; machine count lives in
Fly, not in `fly.toml`. The count is pinned to exactly one after every
launch/deploy with `fly scale count 1 -a morsel-mcp` (human action), guarded
by the read-only `infra/fly/check-machine-count.sh` drift check and the
`fly.toml` comment header. A second machine is not just cost: an idle extra
machine changes nothing functionally, but a redeploy race that briefly runs
two session maps would make clients' sessions land on the wrong process.

## D7. Database state: migrations as canonical SQL + migration ledger (#76)

The schema source of truth is `db/migrations/000N_name.sql`; `db/seed.sql`
loads the deterministic reference rows. Issue #76 found live drift because
no ledger existed. The fix (merged) adds the `public.migration_ledger` plus
a fail-closed recovery runner (`scripts/migration-recovery.mjs`, human-gated
`--apply` with a byte-exact confirmation phrase) and a read-only
reconciliation script (`scripts/migration-reconcile.mjs`). Reproducibility
includes the ledger: a fresh project applies migrations in order with the
ledger, and day-2 drift detection runs the read-only reconcile
(`docs/SUPABASE_OPERATIONS.md`, `docs/MIGRATION_RECOVERY.md`). Migration CD
(`deploy-migrations.yml` and friends, #83) exists with the production apply
step OFF by default behind a flag; enabling it is a human decision recorded
in that lane's docs.

## D8. Secrets: names in the repo, values in the local store

No secret value exists anywhere in this repository. The committed artifacts
reference secret NAMES (`~/.config/zsh/secrets.zsh` variables
`SUPABASE_URL_MORSEL`, `SUPABASE_ANON_KEY_MORSEL`,
`MORSEL_OAUTH_SIGNING_KEY`, `RESEND_API_KEY_MORSEL`, plus
`SUPABASE_ACCESS_TOKEN_MORSEL` / `SUPABASE_PROJECT_REF_MORSEL` feeding the
Management API env names `SUPABASE_ACCESS_TOKEN` / `SUPABASE_PROJECT_REF`).
Apple `.p8`/ASC items belong to the #32 release track, not this stack.
`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` is deliberately never set by the repo
(human-gated config step per `authorize-ui/README.md`).

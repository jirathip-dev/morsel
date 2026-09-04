# Morsel fresh-project recreation — DRY RUN (issue #78)

This document is the from-scratch recreation procedure for the Morsel stack:
a NEW Fly app + a NEW Supabase project + a NEW Vercel project, provisioned
from committed sources plus the local secret store, ending with the
verification checklist below. It is written so that a runbook-only operator
(no tribal knowledge, no undocumented dashboard clicks) can recreate the
stack and PASS the checklist.

Status: **documented, NOT executed.** Executing a fresh-project dry run
creates real new projects, which is a human-gated action outside this lane
(issue #78 scope: "file-only"). The lane that executes it must follow this
doc exactly, use new names (never the live ones), and then tear the scratch
projects down again (cleanup in step S5).

Preconditions (human environment):

- `fly` CLI authed (`fly auth login`), `supabase` CLI or curl access with a
  Management API token, `node` >= 18, access to the local secret store
  `~/.config/zsh/secrets.zsh`.
- The local store has the values behind the names listed in
  `infra/supabase/secrets.json` and
  `docs/SUPABASE_OPERATIONS.md` (env table). No value is ever typed into a
  command line; scripts read by NAME.
- Pick scratch names for the dry run, e.g. `morsel-mcp-dryrun`,
  project ref from `supabase projects create`, `morsel-authorize-ui-dryrun`.
  Live names (`morsel-mcp`, the live Supabase project ref,
  `morsel-authorize-ui`) are FORBIDDEN targets for any step; the Fly app
  script refuses the live Fly name outright.

## S1 — Fly origin (new app)

1. Create the app (guarded script; dry-run first):
   `infra/fly/app-create.sh morsel-mcp-dryrun --org <fly-org>`
   then with `--apply`. (Manual equivalent: `fly apps create`.)
2. Fly secrets — import the five names from the store without printing them
   (runbook `docs/FLY_DEPLOY.md` step 3; values from the local store names
   listed there).
3. Deploy the committed image: `fly deploy -a morsel-mcp-dryrun`.
4. Pin machine count to one (operational state, decision D6):
   `fly scale count 1 -a morsel-mcp-dryrun`, then prove it with
   `infra/fly/check-machine-count.sh morsel-mcp-dryrun` -> exit 0.
5. Wait for the health check to pass (fly.toml check on `/health`).

## S2 — Supabase project (new)

1. Create the project in the dashboard or `supabase projects create`
   (free tier, Tokyo region). Note the new project ref.
2. Point the Management API env at the NEW ref:
   `export SUPABASE_PROJECT_REF=<new-ref>` (+ `SUPABASE_ACCESS_TOKEN` from
   the store, as in `docs/SUPABASE_OPERATIONS.md`).
3. Apply the schema with the migration ledger: run the human-gated migration
   apply (`scripts/migration-recovery.mjs --apply`, confirmation phrase)
   against the new project, or apply `db/migrations/*.sql` in numeric order
   followed by `db/seed.sql` and bootstrap the ledger exactly as
   `docs/MIGRATION_RECOVERY.md` describes. Then prove ledger consistency:
   `node scripts/migration-reconcile.mjs` -> exit 0.
4. Apply the canonical Auth config: `node infra/supabase/config.mjs diff`
   (expect drift on a fresh project), then
   `RESEND_API_KEY_MORSEL=<from store, by reference> node infra/supabase/config.mjs apply --yes`
   (or export the env name first). Postcondition: the script re-checks and
   exits 0.
5. Bootstrap project secrets by name:
   `node infra/supabase/secrets.mjs` (dry run), then `--apply`.
6. Verify: `node infra/supabase/config.mjs check` -> exit 0; the secrets dry
   run lists the three targets.

## S3 — Vercel consent skin (new project)

1. Create project `morsel-authorize-ui-dryrun` in the Vercel dashboard
   (free tier): framework Other/static, root `authorize-ui/`, no build, no
   env — the one-time manual capture is in `infra/vercel/README.md`.
2. For a dry run against the scratch stack, the committed `params.js`
   `AUTHORIZE_URL` and the advertised `authorization_endpoint` must point at
   the NEW Fly origin (`https://morsel-mcp-dryrun.fly.dev/mcp/authorize`).
   In the real recreation this is a code change merged to `main` before the
   project import (auto-deploy). In the dry run, verify the mechanism
   instead: the deployed page must carry exactly the committed action URL —
   the pinning test is `authorize-ui/authorization.test.js` and the live
   grep probe in `docs/VERCEL_OPERATIONS.md`.

## S4 — Resend (no new account)

The Resend account is shared (free tier): sender constraint and OTP
recipient are account-level facts (decision D4). Recreating the stack does
NOT create a new Resend account; the SMTP password for the new Supabase
project is the same store value (`RESEND_API_KEY_MORSEL` by name). If the
account owner ever changes, the OTP recipient changes with it — that is a
product/human decision recorded in `docs/INFRA_DECISIONS.md` D4.

## S5 — Verification checklist (acceptance)

Run every check; the dry run PASSES only when all of these hold:

1. Fly health: `curl -s https://morsel-mcp-dryrun.fly.dev/health` -> 200
   `{"ok":true}`.
2. Fly metadata: GET `/mcp/.well-known/oauth-authorization-server` -> 200,
   `issuer`/`token_endpoint`/`registration_endpoint` on the NEW Fly base,
   `authorization_endpoint` = the NEW Vercel page.
3. Session regression against the NEW origin: initialize -> 200 +
   `mcp-session-id`; `notifications/initialized` with that id -> 202;
   `tools/list` with that id -> 200 with the full tool list (same shape as
   `docs/FLY_DEPLOY.md` step 6; offline mirror: `npm run test:fly`).
4. Consent POST target: the NEW Vercel `/authorize` page's form action is
   the NEW Fly `/mcp/authorize` (live grep probe, `docs/VERCEL_OPERATIONS.md`).
5. Supabase config drift: `node infra/supabase/config.mjs check` -> exit 0
   (SMTP host/user/sender, OTP length 6, template `{{ .Token }}`, rate limit
   30 all asserted against the NEW project).
6. Schema/ledger drift: `node scripts/migration-reconcile.mjs` -> exit 0
   with the ledger and local migrations consistent.
7. Fly machine count: `infra/fly/check-machine-count.sh morsel-mcp-dryrun`
   -> exit 0 ("exactly one started machine").

Cleanup after the dry run (human): destroy the scratch Fly app, the scratch
Supabase project, and the scratch Vercel project; confirm no scratch secret
or value remains referenced anywhere. The live stack must be untouched: the
live checks (docs/DRIFT.md) still pass afterward.

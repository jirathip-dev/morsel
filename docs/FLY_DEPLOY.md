# Morsel MCP on Fly.io — single-process hosting (issue #72)

Status: **deployed; canonical on the custom domain.** The Fly origin (Bun
entry point, `Dockerfile`, `fly.toml`, tests) is live: the canonical MCP
endpoint is `https://mcp.morselfood.app/mcp` (the morselfood.app custom
domain over the Fly deployment, issue #130) — the value the app build
configuration (`CANONICAL_MCP_URL`, issue #75), onboarding copy, and OAuth
discovery publish, and the base the Vercel consent page (issue #74) targets.
The legacy `https://morsel-mcp.fly.dev/mcp` origin still serves the identical
endpoint, metadata, and 401 challenges until it is retired. The deploy steps
below are retained as the runbook for that deployment and remain the
reference for redeploys and rollbacks (Guy's Fly account/auth). Remaining
human gates: the next TestFlight build that carries the canonical copy/URL
into the built app, live Claude connector acceptance on the canonical URL,
and separately retiring the Supabase Edge Function transport. No
authenticated live acceptance is claimed here.

## Why Fly

Supabase Edge Function isolates cannot hold the in-memory MCP session map:
initialize, notifications/initialized, and tools/list land on different
isolates, so sessions are lost between requests (issue #71, live reproduction
in #72). A single Bun process on Fly keeps one session map alive for the
process lifetime. Supabase remains the Auth/Postgres/RLS store, Resend stays
the email path, Vercel stays the browser consent page, and all
OAuth/OTP/PKCE/tool behavior is unchanged — only the MCP hosting origin moves.

## Route shape on the Fly origin (mirrors the Edge Function's public shape)

No Supabase gateway strips `/functions/v1` on Fly, so the app runs with
`basePath: '/mcp'` and the raw origin serves:

| Path | Purpose |
| --- | --- |
| `/health` | health check (`{"ok":true}`), origin root (fly.toml check) |
| `/version` | build identity of the RUNNING image (issue #261): `MORSEL_BUILD_REVISION` + `FLY_IMAGE_REF`/`FLY_MACHINE_ID`/`FLY_APP_NAME` |
| `/mcp` | **canonical MCP transport** (streamable HTTP; POST/GET/DELETE/OPTIONS) |
| `/mcp/.well-known/oauth-authorization-server` | authorization-server metadata (RFC 8414 path for the `/mcp` path issuer) |
| `/mcp/.well-known/openid-configuration` | same document at the OIDC-appended path (issue #59) |
| `/mcp/.well-known/oauth-protected-resource` (+ `/mcp`) | protected-resource metadata |
| `/mcp/register`, `/mcp/authorize`, `/mcp/token` | dynamic client registration, consent backend, token exchange |

Deliberately absent: `/mcp/mcp` (the pre-#57 Edge compatibility alias has no
clients on this origin), `/mcp/health` (health lives at the origin root
only), and origin-root discovery (no metadata duplication). That route shape
is what both origins serve; the canonical client transport is
`https://mcp.morselfood.app/mcp` (issue #130), and the legacy
`https://morsel-mcp.fly.dev/mcp` origin serves the same routes identically
until retired.

## Deployed revision: source of truth and failure modes (issue #261)

The Fly deploy is human-dispatched, so a lagging production is invisible unless
something compares what is **RUNNING** with `main`. This is that comparison.

**Source of truth — the running process, not a workflow.** The image carries the
git revision it was built from, and the running server publishes it:

| Field of `GET /version` | Where the value comes from |
| --- | --- |
| `revision` | `MORSEL_BUILD_REVISION`, a Docker **build arg** passed by `.github/workflows/deploy-fly.yml` (`flyctl deploy --build-arg MORSEL_BUILD_REVISION="$(git rev-parse HEAD)"`), baked with `ENV` in the `Dockerfile`, read by `buildIdentity()` in `server/app.ts` and served at the origin root |
| `image` | `FLY_IMAGE_REF` — the image THIS machine runs |
| `machineId` / `app` | `FLY_MACHINE_ID` / `FLY_APP_NAME`, injected by the Fly platform |

`curl https://mcp.morselfood.app/version` →
`{"revision":"<40-hex sha>","image":"registry.fly.io/morsel-mcp:deployment-…","machineId":"…","app":"morsel-mcp"}`
(the legacy `morsel-mcp.fly.dev` origin answers identically until retired).

Two tempting sources are deliberately NOT used: the image **tag**
(`deployment-01M2KRMKT3W7EX5SGVYRNPM66V` does not encode a git revision), and
**the last green deploy run** — a claim about intent, not about what is
executing. `/health` is not evidence either: it answered 200 throughout the
2026-09-15 incident while the deployed code was 3 days old.

**The check.** `node scripts/fly-revision-watchdog.mjs` (READ-ONLY; GET requests
only) reads the two revisions and reports one verdict, machine-readable on
stdout (`VERDICT=`, `BEHIND=`, `FLY_REVISION_JSON={…}`):

| Verdict | Meaning | Exit | Scheduled workflow |
| --- | --- | --- | --- |
| `IN_SYNC` | the deployed revision IS `main`'s HEAD | 0 | silent, no issue |
| `BEHIND` | a different revision is running; the commits `main` is ahead by are listed | 0 | opens/refreshes exactly one issue |
| `UNKNOWN` | the deployed revision could not be observed | 1 | **fails closed** (never a green skip) |

`.github/workflows/fly-revision-watchdog.yml` runs it daily (02:00 UTC) and on
dispatch; the issue it files is titled
`Morsel Fly revision drift: deployed morsel-mcp is behind main` and an existing
open issue is refreshed with a comment instead of duplicated.

**Failure modes, stated honestly:**

- **No bake / malformed revision** (image built without the build arg, or
  `MORSEL_BUILD_REVISION` is not a full 40-hex revision): `/version` reports
  `revision: null` and the watchdog reports `UNKNOWN` + exit 1. It never
  degrades to a green `IN_SYNC`. This is the expected state for any image built
  BEFORE this change, so production reports `UNKNOWN` until the next
  human-dispatched deploy carries the bake.
- **A runtime `MORSEL_BUILD_REVISION` env/secret would shadow the baked value.**
  The deploy-time postcondition below catches exactly that: a deploy fails when
  either origin reports a revision other than the one it shipped.
- **Origin unreachable, non-200, or non-JSON:** `UNKNOWN` + exit 1 with the
  reason; no cached or assumed value is substituted.
- **GitHub read API unreachable:** `main` is unavailable → `UNKNOWN`; the
  watchdog never assumes "in sync".
- **Divergence** (production rolled back/forward to a commit that is not an
  ancestor of `main`): reported `BEHIND` with the compare `status` named, and the
  commit list is explicitly labelled as not necessarily a fast-forward.
- **Privacy:** the response and the report carry a public git revision plus
  machine/image identifiers for a public repo — no secret, token, or user data;
  the watchdog never prints the token it sends to the GitHub API.
- The watchdog is READ-ONLY and fixes nothing: the fix is the human-dispatched
  `Deploy Fly (morsel-mcp)` workflow.

**Deploy-time verification:** `deploy-fly.yml` resolves the head revision
fail-closed, passes it as the build arg, and — after the machine-count and
health postconditions — asserts that BOTH origins report exactly that revision
on `/version`. A broken bake therefore fails the deploy instead of silently
disarming the watchdog.

## Metadata contract (served values)

The served values derive from the deployed `MORSEL_PUBLIC_BASE_URL` secret —
never from the incoming Host header in production — whose value is the
canonical base `https://mcp.morselfood.app/mcp` (flipped in the Fly secret on
2026-09-07, release `84ed375b2d27`, issues #130/#170).

- `issuer` = `https://mcp.morselfood.app/mcp`.
- `authorization_endpoint` = `https://morsel-authorize-ui.vercel.app/authorize`
  (the Vercel consent page) when `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` is set;
  unset keeps the server-rendered fallback.
- `token_endpoint` = `https://mcp.morselfood.app/mcp/token`,
  `registration_endpoint` = `https://mcp.morselfood.app/mcp/register`.
- protected-resource `resource`/`authorization_servers` =
  `https://mcp.morselfood.app/mcp`.
- The legacy `https://morsel-mcp.fly.dev/mcp` origin serves this same
  deployment identically (same transport, discovery documents, and 401
  challenges) until it is retired, so it advertises the same canonical values.
- No `/functions/v1`, no `/mcp/mcp`, no doubled prefixes anywhere.

## Required environment (Fly secrets — names only, values never committed)

| Secret | Example value (never embed in source/TOML) |
| --- | --- |
| `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | the project anon key |
| `MORSEL_OAUTH_SIGNING_KEY` | long random value (same one the legacy Edge Function uses while it is retained) |
| `MORSEL_PUBLIC_BASE_URL` | `https://mcp.morselfood.app/mcp` (deployed value since 2026-09-07; the legacy `https://morsel-mcp.fly.dev/mcp` remains a valid value and serves identically until retired. Validated fail-closed: absolute HTTPS, exactly `/mcp` path, no userinfo/query/fragment/whitespace/trailing slash) |
| `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` (optional) | `https://morsel-authorize-ui.vercel.app/authorize` |

The entry point refuses to start when any required value is missing or
malformed (fail closed at boot).

## Deploy runbook (Guy)

The steps below are the runbook used for the initial Fly deployment (now
live and serving the canonical endpoint) and remain the reference for
redeploys and rollbacks.
All commands are placeholders; replace `<…>` values from the local secret
store. None of these commands print secret values when run as written.

1. Install/authenticate Fly (human environment, not this repo):
   `fly auth login` (and confirm the org with `fly orgs list`).
2. Create the app once (name must match `fly.toml` `app`):
   `fly apps create morsel-mcp --org <fly-org>`
   New-stack creation (fresh-project recreation, issue #78) uses the guarded
   `infra/fly/app-create.sh <new-app-name> --org <fly-org> [--apply]` —
   dry-run by default and refuses the live app name `morsel-mcp`.
3. Set secrets WITHOUT printing them — prepare a local file (outside the
   repo, from the existing secret store) named e.g. `fly-morsel.env` with
   `KEY=VALUE` lines for the five names above, then import:
   `fly secrets import -a morsel-mcp < fly-morsel.env`
   (Per-key alternative that also avoids printing:
   `fly secrets set -a morsel-mcp SUPABASE_URL="$SUPABASE_URL"` with the
   shell variables already loaded from the local store.)
4. Deploy the committed Dockerfile/fly.toml:
   `fly deploy -a morsel-mcp`
5. Machine count is operational state — pin it to exactly one:
   `fly scale count 1 -a morsel-mcp`
   Then prove it with the read-only check:
   `infra/fly/check-machine-count.sh` → `OK: exactly one started machine`.
6. Verify (read-back, not static claims). Probe the canonical origin: the
   legacy `morsel-mcp.fly.dev` origin serves the same deployment and answers
   identically until retired, so these checks also pass there.
   - `curl https://mcp.morselfood.app/health` → `200 {"ok":true}`
   - `curl https://mcp.morselfood.app/version` → `200` whose `revision` equals
     the SHA being deployed (issue #261). A `null` revision means the image
     predates the revision bake: the revision watchdog then reports `UNKNOWN`
     and fails closed until a deploy carries the bake (see §"Deployed revision").
   - `curl https://mcp.morselfood.app/mcp/.well-known/oauth-authorization-server`
     → `200`; `issuer` = `https://mcp.morselfood.app/mcp`, `token_endpoint`
     and `registration_endpoint` rooted at that issuer,
     `authorization_endpoint` = the Vercel consent page.
   - Unauthenticated `POST https://mcp.morselfood.app/mcp` (initialize) →
     `401` with a `WWW-Authenticate` `resource_metadata` URL on the canonical
     base:
     `https://mcp.morselfood.app/mcp/.well-known/oauth-protected-resource/mcp`.
   - Session regression against the live origin (three requests, one
     process): initialize → `200` + `mcp-session-id`;
     `notifications/initialized` with that id → `202`; `tools/list` with
     that id → `200` with the full `EXPECTED_TOOLS` set from
     `server/fly-entrypoint.bun-test.ts`. The same flow runs locally against
     the committed code with `npm run test:fly` (Bun required).
   - Live Claude acceptance (final human gate): re-add the Morsel connector
     with `https://mcp.morselfood.app/mcp`; confirm the tool count appears
     and `get_profile` returns the profile.
7. Rollback (Fly has no special rollback command — redeploy the previous
   image; it does not undo config/secrets):
   `fly releases -a morsel-mcp --image`
   `fly deploy -a morsel-mcp --image registry.fly.io/morsel-mcp:deployment-<sha>`
   then re-verify step 6. (Fly may prune old images; for long-term rollback
   insurance push builds to an owned registry.)

## Reproducibility tooling (issue #78)

This runbook is part of the committed infra-as-code set (`infra/` + `docs/`):

- `infra/fly/app-create.sh` — guarded app creation for a NEW stack (dry-run
  by default; refuses the live app name `morsel-mcp`); the scripted
  equivalent of step 2.
- `infra/fly/check-machine-count.sh` — READ-ONLY machine-count drift check
  (exit 0 = exactly one started machine); run after every deploy to prove
  the step-5 guard held. Full drift policy: `docs/DRIFT.md`.
- `docs/INFRA_DECISIONS.md` — decision log (D6: machine count is operational
  state, not toml state). Companion runbooks:
  `docs/SUPABASE_OPERATIONS.md`, `docs/VERCEL_OPERATIONS.md`; from-scratch
  recreation dry run: `docs/FRESH_PROJECT_DRY_RUN.md`.
- Verification checklists matching the live probes: step 6 below (Fly
  origin: health, metadata, 401 challenge, session regression), the consent
  POST-target probe in `docs/VERCEL_OPERATIONS.md`, the Supabase config
  read-back asserts in `docs/SUPABASE_OPERATIONS.md`, and the full
  acceptance list in `docs/FRESH_PROJECT_DRY_RUN.md` §S5.
- Merging these files cannot mutate Fly: no workflow invokes them, and the
  only mutating commands (`fly apps create`, `fly secrets import`, `fly
  deploy`, `fly scale count 1`) are runbook steps executed by a human.

## Cutover and legacy URL

- The canonical, deployed MCP endpoint is the custom domain over the Fly
  origin: app builds (Fastfile `CANONICAL_MCP_URL`, issues #75/#130),
  onboarding copy, and OAuth discovery all publish
  `https://mcp.morselfood.app/mcp`. The legacy
  `https://morsel-mcp.fly.dev/mcp` origin serves the same deployment and
  answers identically until retired. Client delivery of that copy and of
  `MORSEL_MCP_URL` in the built app lands with the next TestFlight build,
  which is human-gated.
- The Supabase Edge Function transport is legacy/retained backend
  compatibility only and is no longer the client-facing URL. It stays
  available until it is separately retired (a human decision); the
  pre-#57 `/mcp/mcp` alias is not published to clients.
- The Vercel consent cutover is complete: `authorize-ui/params.js` posts the
  consent forms to `https://mcp.morselfood.app/mcp/authorize` (issue #74,
  PR #77), its test pins that canonical action, and the production Vercel
  page carries the Fly action.
- Live acceptance of the canonical endpoint — OAuth sign-in and
  `get_profile` through a real MCP client (for example re-adding the Morsel
  connector in Claude) — remains a human-gated check and is not claimed by
  any code change in this repository.

## Local/CI verification without Fly

- `npm run test:fly` — runs the committed real-HTTP session regression under
  Bun (`server/fly-entrypoint.bun-test.ts`; use `bun test ./server/...` — the
  `./` path form is required or bun treats the name as a filter and runs
  nothing); CI runs it in the
  `bun-fly-entrypoint` job with `oven-sh/setup-bun` plus a boot probe of
  `/health`, metadata, and the 401 challenge.
- `server/fly-entrypoint.test.ts` (plain `npm test`) covers the route/
  metadata contract, fail-closed env validation, the `/version` build-identity
  route, and the committed
  deployment-input static contract with synthetic values only.
- Deployed-revision watchdog (issue #261):
  `npx vitest run scripts/fly-revision-watchdog.test.mjs scripts/fly-revision-watchdog.e2e.test.mjs`
  — unit + static-contract tests plus a real-HTTP end-to-end run: the committed
  Fly entry point served on a loopback listener, the committed CLI spawned as a
  subprocess (`node scripts/fly-revision-watchdog.mjs`), with the GitHub read API
  stubbed locally so nothing reaches the network.
- Docker build/run gate (local, no Fly):
  `docker build -t morsel-mcp:local .`
  `docker run --rm -p 8080:8080 -e SUPABASE_URL=… -e SUPABASE_ANON_KEY=… -e MORSEL_OAUTH_SIGNING_KEY=… -e MORSEL_PUBLIC_BASE_URL=http://127.0.0.1:8080/mcp morsel-mcp:local`
  then probe `/health` and `/mcp/.well-known/oauth-authorization-server`, and
  run `docker run --rm morsel-mcp:local bun test server/fly-entrypoint.bun-test.ts`.

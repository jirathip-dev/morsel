# Morsel MCP on Fly.io — single-process hosting (issue #72)

Status: **deploy materials only.** The Bun entry point, `Dockerfile`,
`fly.toml`, tests, and this runbook are committed and reviewed, but NOTHING is
deployed. There is no Fly account/app, no `flyctl` install, no secret
mutation, and no URL cutover yet — every step below is a **human-only,
explicitly approved action** (Guy's Fly account/auth + deploy approval).

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
| `/mcp` | **canonical MCP transport** (streamable HTTP; POST/GET/DELETE/OPTIONS) |
| `/mcp/.well-known/oauth-authorization-server` | authorization-server metadata (RFC 8414 path for the `/mcp` path issuer) |
| `/mcp/.well-known/openid-configuration` | same document at the OIDC-appended path (issue #59) |
| `/mcp/.well-known/oauth-protected-resource` (+ `/mcp`) | protected-resource metadata |
| `/mcp/register`, `/mcp/authorize`, `/mcp/token` | dynamic client registration, consent backend, token exchange |

Deliberately absent: `/mcp/mcp` (the pre-#57 Edge compatibility alias has no
clients on a fresh origin), `/mcp/health` (health lives at the origin root
only), and origin-root discovery (no metadata duplication). The canonical
client transport is `https://morsel-mcp.fly.dev/mcp`.

## Metadata contract (served values)

- `issuer` = `https://morsel-mcp.fly.dev/mcp` — never derived from the
  incoming Host header in production; it comes from the
  `MORSEL_PUBLIC_BASE_URL` secret.
- `authorization_endpoint` = `https://morsel-authorize-ui.vercel.app/authorize`
  (the Vercel consent page) when `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` is set;
  unset keeps the server-rendered fallback.
- `token_endpoint` = `https://morsel-mcp.fly.dev/mcp/token`,
  `registration_endpoint` = `https://morsel-mcp.fly.dev/mcp/register`.
- protected-resource `resource`/`authorization_servers` =
  `https://morsel-mcp.fly.dev/mcp`.
- No `/functions/v1`, no `/mcp/mcp`, no doubled prefixes anywhere.

## Required environment (Fly secrets — names only, values never committed)

| Secret | Example value (never embed in source/TOML) |
| --- | --- |
| `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | the project anon key |
| `MORSEL_OAUTH_SIGNING_KEY` | long random value (same one the Edge Function uses today) |
| `MORSEL_PUBLIC_BASE_URL` | `https://morsel-mcp.fly.dev/mcp` (validated fail-closed: absolute HTTPS, exactly `/mcp` path, no userinfo/query/fragment/whitespace/trailing slash) |
| `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` (optional) | `https://morsel-authorize-ui.vercel.app/authorize` |

The entry point refuses to start when any required value is missing or
malformed (fail closed at boot).

## Human-only deploy steps (Guy)

All commands are placeholders; replace `<…>` values from the local secret
store. None of these commands print secret values when run as written.

1. Install/authenticate Fly (human environment, not this repo):
   `fly auth login` (and confirm the org with `fly orgs list`).
2. Create the app once (name must match `fly.toml` `app`):
   `fly apps create morsel-mcp --org <fly-org>`
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
6. Verify (read-back, not static claims):
   - `curl https://morsel-mcp.fly.dev/health` → `200 {"ok":true}`
   - `curl https://morsel-mcp.fly.dev/mcp/.well-known/oauth-authorization-server`
     → `200`; `issuer`/`token_endpoint`/`registration_endpoint` on
     `https://morsel-mcp.fly.dev/mcp`, `authorization_endpoint` on Vercel.
   - Unauthenticated `POST https://morsel-mcp.fly.dev/mcp` (initialize) →
     `401` with a `WWW-Authenticate` `resource_metadata` URL on the Fly base.
   - Session regression against the live origin (three requests, one
     process): initialize → `200` + `mcp-session-id`;
     `notifications/initialized` with that id → `202`; `tools/list` with
     that id → `200` with all 13 tools. The same flow runs locally against
     the committed code with `npm run test:fly` (Bun required).
   - Live Claude acceptance (final human gate): re-add the Morsel connector
     with `https://morsel-mcp.fly.dev/mcp`; confirm the tool count appears
     and `get_profile` returns the profile.
7. Rollback (Fly has no special rollback command — redeploy the previous
   image; it does not undo config/secrets):
   `fly releases -a morsel-mcp --image`
   `fly deploy -a morsel-mcp --image registry.fly.io/morsel-mcp:deployment-<sha>`
   then re-verify step 6. (Fly may prune old images; for long-term rollback
   insurance push builds to an owned registry.)

## Cutover and legacy URL

- The Fly origin is the canonical, deployed MCP endpoint: app builds
  (Fastfile `CANONICAL_MCP_URL`, issue #75), onboarding copy, and OAuth
  discovery all publish `https://morsel-mcp.fly.dev/mcp`. Client delivery of
  that copy and of `MORSEL_MCP_URL` in the built app lands with the next
  TestFlight build, which is human-gated.
- The Supabase Edge Function transport is legacy/retained backend
  compatibility only and is no longer the client-facing URL. It stays
  available until it is separately retired (a human decision); the
  pre-#57 `/mcp/mcp` alias is not published to clients.
- The Vercel consent cutover is complete: `authorize-ui/params.js` posts the
  consent forms to `https://morsel-mcp.fly.dev/mcp/authorize` (issue #74,
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
  metadata contract, fail-closed env validation, and the deploy-materials
  static contract with synthetic values only.
- Docker build/run gate (local, no Fly):
  `docker build -t morsel-mcp:local .`
  `docker run --rm -p 8080:8080 -e SUPABASE_URL=… -e SUPABASE_ANON_KEY=… -e MORSEL_OAUTH_SIGNING_KEY=… -e MORSEL_PUBLIC_BASE_URL=http://127.0.0.1:8080/mcp morsel-mcp:local`
  then probe `/health` and `/mcp/.well-known/oauth-authorization-server`, and
  run `docker run --rm morsel-mcp:local bun test server/fly-entrypoint.bun-test.ts`.

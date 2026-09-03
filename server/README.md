# Morsel MCP server

This directory contains the shared Hono server logic for Morsel's remote MCP
endpoint. The local entrypoint is Bun; production currently runs the same app
from `supabase/functions/mcp/index.ts` as a Supabase Edge Function on Deno.
Issue #72 adds a second production entry point — `server/fly-entrypoint.ts`,
a single-process Bun server for Fly.io — which becomes the canonical
client-facing endpoint AFTER a human deploy (see `docs/FLY_DEPLOY.md`; this
merge does not deploy or cut over). It uses
the official `@modelcontextprotocol/sdk` streamable HTTP transport and creates
one authenticated service/repository boundary per MCP session.

## Run locally

The server validates the caller's Supabase bearer token with `auth.getUser()`
and binds that token to the current request's PostgREST context. This is what
makes Supabase RLS see the caller rather than a service role, including when
requests overlap within one MCP session.

```sh
SUPABASE_URL=https://your-project.supabase.co \
SUPABASE_ANON_KEY=your-anon-key \
npm run server
```

The MCP endpoint is `POST /mcp`; `GET /health` is an unauthenticated health
check. `npm run dev` starts Bun's file-watching development server.

## Supabase Edge Function (live until the Fly cutover)

The deployed function keeps `GET /health` public and handles per-request bearer
authentication for the streamable MCP transport endpoint. Supabase's gateway
JWT verification is disabled for this function so the app can validate each MCP
request itself. `SUPABASE_URL` and `SUPABASE_ANON_KEY` are read from the Edge
Function environment when requests create the authenticated boundaries.

**Canonical transport URL (issue #57):** `https://<public-host>/functions/v1/mcp`
— the Edge Function root. The hosted gateway strips `/functions/v1`, so inside
the runtime the canonical route is the function's own `/mcp` prefix. The
pre-#57 nested path `…/functions/v1/mcp/mcp` remains as a tested compatibility
alias for clients provisioned before the route change; it serves the same
transport and never advertises its own metadata, and nothing user-facing links
to it. OAuth discovery and provider routes (`/.well-known/oauth-authorization-server`,
`/.well-known/openid-configuration` (issue #59), `/.well-known/oauth-protected-resource/mcp`,
`/authorize`, `/token`,
`/register`) remain on the same canonical Supabase base, and the advertised OAuth
`resource` is the canonical transport URL itself. The BROWSER consent surface is
the static Vercel page again (issue #69): the optional
`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` Edge Function environment value names
`https://morsel-authorize-ui.vercel.app/authorize`, authorization-server
metadata advertises that page as `authorization_endpoint`, and every
`/authorize` form response is a bodyless 302 back to it carrying the OAuth
parameters (plus the sealed transaction envelope and `#code-entry` on stage
2). Supabase's free shared domain rewrites function `text/html` to
`text/plain`, so the function origin cannot render consent HTML in production:
the Vercel page's `params.js` bridges the allowlisted query fields into hidden
inputs and the browser form-POSTs directly (cross-origin — no CORS, no proxy,
no fetch) to this `/authorize` route. Restoring the production endpoint secret
is a human-gated config step. When the endpoint is unset the function keeps
its server-rendered no-JS email-code stages with self-POST forms (issue #66
fallback, pinned by `oauth.test.ts` as defense in depth). The local Bun
entrypoint (`server/index.ts`) has no prefix: its canonical transport is the
server root `/` with `/mcp` as the alias.

## Fly single-process entry point (issue #72; post-human-deploy canonical)

`server/fly-entrypoint.ts` runs the SAME `createMorselApp` as ONE Bun process
so the in-memory MCP session map survives across requests (Supabase Edge
Function isolates cannot hold sessions — issue #71). It requires nonblank
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `MORSEL_OAUTH_SIGNING_KEY`, and
`MORSEL_PUBLIC_BASE_URL` (validated fail-closed: absolute HTTPS — loopback
http allowed for local probes — exactly `/mcp` path, no
userinfo/query/fragment/whitespace/trailing slash), accepts the optional
`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT`, and wires the Supabase authenticator,
repository, and OAuth options exactly like the Edge entry point. Because Fly
has no `/functions/v1` gateway, the app is mounted with `basePath: '/mcp'`:
the canonical transport is `/mcp`; `/health` is served at the raw origin root
(the new `originHealth` app option — no `/mcp/health`); the pre-#57 nested
alias is disabled (the new `legacyTransportAlias: false` app option — no
`/mcp/mcp` on a fresh origin); discovery, `/register`, `/authorize`, and
`/token` hang off the same `/mcp` base, matching the metadata issuer
(`https://morsel-mcp.fly.dev/mcp` once configured). `server/fly-entrypoint.ts`
is importable without starting a server (`import.meta.main` guards `Bun.serve`
on `0.0.0.0:PORT`, default 8080, with SIGTERM/SIGINT graceful shutdown), which
lets the real-HTTP session regression (`server/fly-entrypoint.bun-test.ts`,
`npm run test:fly`) start it over a real localhost listener. Deploy materials,
human-only steps, verification, and rollback live in `docs/FLY_DEPLOY.md`.
Run `npm run server:fly` for a local Fly-shaped server.

## Design notes

- `packages/schema/food-types.ts` owns the Zod runtime schemas and inferred
  TypeScript contract types.
- `MorselService` contains validation, target calculation, totals, and
  user-scoped orchestration.
- `compute_targets` delegates to the existing `public.compute_targets()` SQL
  function through Supabase RPC in production. The in-memory adapter uses the
  same Mifflin-St Jeor calculation for credential-free tests.
- `log_meal` delegates to `public.log_meal_with_items()`, a security-invoker
  Postgres function that inserts the log and all items in one transaction. The
  RPC is evaluated with the caller's bearer token, so meal RLS policies apply
  to both inserts.
- `MorselRepository` is the storage seam. `InMemoryRepository` is used by unit
  tests; `SupabaseRepository` uses the caller token and explicit user filters
  wherever the table has a `user_id` column. `meal_items` relies on its parent
  meal log's RLS policy and performs an ownership check before updates.
- The server upserts the authenticated account into `public.users` before
  opening an MCP session because the existing schema has app-table foreign keys
  but no auth-user trigger. The account id is taken from the validated bearer
  token and the email is taken from Supabase Auth.
- `log_meal` is one repository operation. The in-memory implementation commits
  both sides together, and the Supabase adapter calls the atomic meal RPC.
- `image_url` is stored verbatim in `meal_logs.image_path`. This v0.1 server
  does not download, verify, or upload media to Supabase Storage; the value is
  only a reference until the storage upload flow is implemented. The URL must
  use HTTPS.
- OAuth uses stateless dynamic client registration. Client IDs carry their
  redirect URI allowlist in an HMAC-signed value. `/authorize` runs a
  two-step email one-time-code flow for **existing** Supabase Auth accounts
  only (`signInWithOtp` with `create_user: false`): step 1 accepts the email,
  requests a code, rate-limits per email, and answers uniformly for known and
  unknown accounts; step 2 verifies the six-digit code and only then stores a
  short-lived grant in the RLS-protected `oauth_authorization_grants` table.
  The email and OAuth request travel between the steps inside a confidential,
  integrity-protected, expiring transaction envelope sealed with
  `MORSEL_OAUTH_SIGNING_KEY`; the client-facing authorization code is
  encrypted/signed but contains no Supabase token. `/token` atomically claims
  the grant through `claim_oauth_authorization_grant` before refreshing and
  returning a real Supabase access token; a replay therefore fails across
  concurrent Edge Function isolates. Refresh-token wrappers remain
  encrypted/signed. `MORSEL_OAUTH_SIGNING_KEY` is required for registration
  and token exchange; set it as an Edge Function secret and never commit it.
- The optional `authorizationEndpoint` option on the shared server is wired
  in the Edge entrypoint to `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` (issue #69):
  when set, every `/authorize` form response becomes a bodyless 302 to that
  external page while the issuer, token, register, resource, challenge, and
  MCP URLs never move. Unset keeps the server-rendered consent fallback
  (issue #66 hardening). CI exercises the configured mode with a synthetic
  endpoint; the deploy workflow only VERIFIES the expected endpoint — the
  production secret restore stays human-gated.
- Deployments must apply the ordered SQL in `db/migrations/` and then
  `db/seed.sql`; migration `0004_store_assets.sql` provisions the private
  `food-images` bucket and its owner-scoped Storage policies, and migration
  `0005_oauth_authorization_grants.sql` provisions the OAuth grant table and
  atomic claim RPC.
- The v0.1 day boundary is UTC because the MCP contract supplies a date but not
  a timezone. The user's stored timezone can be incorporated with a later
  contract/store change.

Run the full verification gate from the repository root:

```sh
npm run typecheck && npm run lint && npm test && npm run build
```

`npm test` includes the local PostgreSQL migration integration test when
`initdb`, `pg_ctl`, and `psql` are installed; `npm run test:postgres` runs only
that test. It creates an ephemeral cluster and does not use Supabase credentials.

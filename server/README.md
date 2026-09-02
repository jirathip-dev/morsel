# Morsel MCP server

This directory contains the shared Hono server logic for Morsel's remote MCP
endpoint. The local entrypoint is Bun; production runs the same app from
`supabase/functions/mcp/index.ts` as a Supabase Edge Function on Deno. It uses
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

## Supabase Edge Function

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
`resource` is the canonical transport URL itself. Consent is served from that
same function origin (issue #66): authorization-server metadata advertises the
Supabase `/authorize` URL as `authorization_endpoint`, and the route renders
both no-JS email-code stages server-side with self-POST forms. The Edge
Function never configures an external authorization page — the legacy static
host could not forward form posts, so the repository no longer sets
`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` anywhere; the shared server keeps an
optional `authorizationEndpoint` seam only for embedders that deliberately
point the browser at their own page. The local Bun entrypoint
(`server/index.ts`) has no prefix: its canonical transport is the
server root `/` with `/mcp` as the alias.

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
- The optional `authorizationEndpoint` option on the shared server exists
  only for embedders that deliberately host their own browser page; the
  deployed Edge Function, CI, and deploy workflow never configure it (issue
  #66 — consent is served from the Supabase function origin). It never moves
  the issuer, token, register, resource, challenge, or MCP URLs.
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

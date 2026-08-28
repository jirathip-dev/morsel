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
authentication for the streamable `POST /mcp` endpoint. Supabase's gateway JWT
verification is disabled for this function so the app can validate each MCP
request itself. `SUPABASE_URL` and `SUPABASE_ANON_KEY` are read from the Edge
Function environment when requests create the authenticated boundaries.
Supabase prefixes requests with the function name, so the hosted URLs are
`/functions/v1/mcp/health` and `/functions/v1/mcp/mcp`; the local Bun entrypoint
continues to use `/health` and `/mcp`. OAuth discovery and provider routes are
available at the same local root (`/.well-known/oauth-authorization-server`,
`/authorize`, `/token`, `/register`) and below the hosted function prefix.

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
  redirect URI allowlist in an HMAC-signed value; authorization codes and
  refresh-token wrappers are encrypted/signed and expire without server-side
  sessions. `/authorize` signs the user in with Supabase Auth email/password,
  validates the returned access token with `auth.getUser()`, and `/token` returns
  that real Supabase token. `MORSEL_OAUTH_SIGNING_KEY` is required for registration
  and token exchange; set it as an Edge Function secret and never commit it.
- Deployments must apply the ordered SQL in `db/migrations/` and then
  `db/seed.sql`; migration `0004_store_assets.sql` provisions the private
  `food-images` bucket and its owner-scoped Storage policies.
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

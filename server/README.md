# Morsel MCP server

This directory contains the Bun-compatible Hono server for Morsel's remote MCP
endpoint. It uses the official `@modelcontextprotocol/sdk` streamable HTTP
transport and creates one authenticated service/repository boundary per MCP
session.

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
- OAuth discovery remains outside issue #3. Migration `0003` adds the
  owner-only `public.users` policies and the atomic meal RPC; it still must be
  applied in each deployment before the server is used.
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

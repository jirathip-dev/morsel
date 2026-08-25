# Morsel MCP server

This directory contains the Bun-compatible Hono server for Morsel's remote MCP
endpoint. It uses the official `@modelcontextprotocol/sdk` streamable HTTP
transport and creates one authenticated service/repository boundary per MCP
session.

## Run locally

The server validates the caller's Supabase bearer token with `auth.getUser()`
and sends that same token on every PostgREST request. This is what makes
Supabase RLS see the caller rather than a service role.

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
- `MorselRepository` is the storage seam. `InMemoryRepository` is used by unit
  tests; `SupabaseRepository` uses the caller token and explicit user filters
  wherever the table has a `user_id` column. `meal_items` relies on its parent
  meal log's RLS policy and performs an ownership check before updates.
- `log_meal` is one repository operation. The in-memory implementation commits
  both sides together. The current migrations do not provide an RPC, so the
  Supabase adapter uses a compensating delete if the item insert fails and
  reports a transaction error if rollback cannot be confirmed. A future
  migration can replace this with a database RPC without changing the MCP
  contract.
- `image_url` is stored verbatim in `meal_logs.image_path`. This v0.1 server
  does not download, verify, or upload media to Supabase Storage; the value is
  only a reference until the storage upload flow is implemented.
- The v0.1 day boundary is UTC because the MCP contract supplies a date but not
  a timezone. The user's stored timezone can be incorporated with a later
  contract/store change.

Run the full verification gate from the repository root:

```sh
npm run typecheck && npm run lint && npm test && npm run build
```

# Architecture

## Decision
**Supabase Edge Function + Supabase store.** We host the MCP endpoint as a
Deno Edge Function and host the store on Supabase; we do not build a chat app,
a feed, or an AI.

## Why hosted (not self-hosted)
The user's agent runs in Claude/ChatGPT's cloud, so the MCP server must be an
internet-reachable endpoint. The data must be shared by both the agent (writer)
and the dashboard (reader), so it cannot live only on-device. → **Always-hosted.**

## Components
```
┌──────────────┐   upload photo + vision   ┌──────────────────────────────┐
│  Claude.ai / │ ────────────────────────▶ │  MORSEL MCP server (Edge/Deno) │
│  ChatGPT /    │   agent calls log_meal   │  · exposes tools (log_meal…)   │
│  any MCP host │                          │  · authenticates user token    │
└──────────────┘                          └──────────────┬───────────────┘
                                                        │ SQL / RLS
                                     ┌──────────────────▼───────────────┐
                                     │  Supabase                         │
                                     │  · Postgres (meals, items, goals) │
                                     │  · Auth (OAuth + app sign-in)    │
                                     │  · Storage (private food-images) │
                                     │  · RLS (user-scoped rows)        │
                                     └──────────────────▲───────────────┘
                                                        │ reads same store
                                     ┌──────────────────┴───────────────┐
                                     │  iOS app (SwiftUI dashboard)     │
                                     │  · no chat, no AI — data + UI    │
                                     └────────────────────────────────┘
```
**One store, two clients** (the agent via MCP, the app via SDK). No separate
REST API for the app — it reads Supabase directly (RLS-scoped).

## Data flow: photo → log
1. User uploads a food photo to Claude/ChatGPT.
2. The agent's vision model identifies components + estimates portion/macros.
3. Agent calls `log_meal` with the structured `items[]` (see `docs/MCP_TOOLS.md`),
   tagging `source=photo_vision` and a per-item `confidence`.
4. Server validates the payload (MCP input schema), stamps `user_id`, and
   inserts into `meal_logs` + `meal_items`. The future upload flow writes the
   image to the private `food-images` bucket; the v0.1 adapter stores the HTTPS
   URL reference only.
5. Dashboard renders it live.

## Deployment
The production entrypoint is `supabase/functions/mcp/index.ts`, a Supabase Edge
Function running Hono and the MCP SDK on Deno. `GET /health` is public; the
function disables the platform JWT check so the app can validate the per-request
bearer token required by `/mcp`. `SUPABASE_URL` and `SUPABASE_ANON_KEY` are read
from the function environment at request time. Supabase exposes these routes as
`/functions/v1/mcp/health` and `/functions/v1/mcp/mcp` because `mcp` is the
function name. OAuth discovery and provider routes use the same function prefix:
`/.well-known/oauth-authorization-server`, `/authorize`, `/token`, and `/register`
are available below `/functions/v1/mcp/`.

## Auth
- **Agent side:** remote MCP connectors (Claude.ai custom connector, ChatGPT) use
  OAuth 2.0. The MCP server runs the OAuth provider; the user signs in once with
  Supabase Auth email/password and the connector gets a per-user Supabase access
  token. The server validates that token with `auth.getUser()` before returning it,
  so it becomes `auth.uid()` for every existing RLS policy. (Same pattern as
  `nutrition-mcp`'s Claude.ai connector.)
- **OAuth storage:** dynamic RFC 7591 registration is stateless. The returned
  public client ID contains its registered redirect URIs and an HMAC signature.
  `/authorize` stores a short-lived, user-owned grant in
  `oauth_authorization_grants`; only a SHA-256 code hash, client, redirect URI,
  PKCE challenge, scopes, expiry, user, and server-side refresh credential are
  persisted. The client-facing authorization code is an encrypted/signed
  envelope containing no Supabase token. `/token` atomically deletes and
  returns the grant through the `claim_oauth_authorization_grant` RPC before
  refreshing and returning a Supabase access token, so replay fails across
  concurrent Edge Function isolates. The refresh-token wrapper remains
  encrypted and signed with `MORSEL_OAUTH_SIGNING_KEY`.
- **OAuth discovery:** protected-resource metadata is served at both
  `/.well-known/oauth-protected-resource` and
  `/.well-known/oauth-protected-resource/mcp` (and the corresponding function
  prefixed paths). The MCP 401 response points clients at the path-specific URL.
- **App side:** Supabase Auth (Apple / Google / email OTP). Same `user_id` as the
  agent, so both clients share one store.

## Backend scope (what we are / aren't)
- **We host:** a remote MCP endpoint, a few tables, auth, image storage, a dashboard.
- **We do NOT host:** chat, feeds, social, content moderation, recommendation engines.

## Hosting alternatives considered
1. **Supabase + thin hand-written MCP server** (chosen) — most control; the path
   `nutrition-mcp` proved.
2. **Supabase + auto-generated MCP tools from schema** — least code, less control
   over tool naming/semantics. Look at `supabase-mcp-server` if we go this way.
3. **Fly.io + managed Postgres** — more control over the long-running server,
   with more deployment and operations work.
4. **Cloudflare Workers + D1** — cheapest ops / serverless. Revisit if hosting
   cost or always-uptime becomes a concern.

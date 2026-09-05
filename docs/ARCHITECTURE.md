# Architecture

## Decision
**Supabase store + MCP server hosted as a single process on Fly.io (issue
#72): deployed and canonical.** The store stays on Supabase (Postgres +
RLS); the MCP endpoint runs as one long-lived Bun process on Fly at
`https://morsel-mcp.fly.dev/mcp` so the in-memory MCP session map survives
across requests — Supabase Edge Function isolates cannot hold sessions
(issue #71; the live initialize → notifications/initialized → tools/list
breakage). The Fly process replaced the Deno Edge Function (whose transport
was the function root, `https://<public-host>/functions/v1/mcp`, issue #57)
as the client-facing base; the Supabase Edge deployment is retained as
legacy compatibility (see `docs/FLY_DEPLOY.md`).

## Why hosted (not self-hosted)
The user's agent runs in Claude/ChatGPT's cloud, so the MCP server must be an
internet-reachable endpoint. The data must be shared by both the agent (writer)
and the dashboard (reader), so it cannot live only on-device. → **Always-hosted.**

## Components
```
┌──────────────┐   upload photo + vision   ┌──────────────────────────────┐
│  Claude.ai / │ ────────────────────────▶ │  MORSEL MCP server (Fly/Bun)   │
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

**Current production (deployed, canonical):** `server/fly-entrypoint.ts`
serves the shared `createMorselApp` from one Bun process on Fly (issue #72;
`Dockerfile` + `fly.toml`, one machine, region `nrt`, `/health` check) at
`https://morsel-mcp.fly.dev/mcp`. `GET /health` is public; each MCP request
carries a per-request Supabase bearer token that the process validates with
`auth.getUser()` before serving the streamable MCP transport. On Fly there is
no `/functions/v1` gateway prefix, so the app mounts with `basePath: '/mcp'`
— canonical transport `/mcp`, discovery/OAuth routes below `/mcp/`, `/health`
at the raw origin root, and no `/mcp/mcp` alias and no `/functions/v1`
artifacts. `issuer`/`resource`/endpoints derive from the configured
`MORSEL_PUBLIC_BASE_URL` (`https://morsel-mcp.fly.dev/mcp`), never from the
request Host header; `authorization_endpoint` is the Vercel consent page. The
BROWSER consent surface is the static Vercel page under `authorize-ui/`
(issue #69): the page's same-origin `params.js` bridges the allowlisted query
fields into hidden inputs and each stage form POSTs directly (cross-origin —
no CORS, no fetch, no proxy) to the Fly origin's `/mcp/authorize` (issue
#74); every `/authorize` form response is a bodyless 302 back to the page
(carrying the OAuth parameters, the sealed transaction envelope, and
`#code-entry` on stage 2). `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` is set on
the deployed Fly app (live authorization-server metadata advertises the
Vercel page); changing it is a human-gated config step. Unset, the route
serves the two email-code stages itself as the pinned server-rendered
fallback (issue #66 hardening), and `/authorize` remains the OAuth backend
and issuer either way.

**Supabase Edge Function (retained legacy compatibility):** the pre-Fly
production entrypoint `supabase/functions/mcp/index.ts` ran Hono and the MCP
SDK on Deno and exposed the transport at the function root. It disabled the
platform JWT check so the app could validate each request's bearer token
itself; `SUPABASE_URL` and `SUPABASE_ANON_KEY` are read from its environment
at request time. The gateway strips `/functions/v1`, so inside the Edge
runtime routes register under the function name `mcp` while publicly exposing
`/functions/v1/mcp` (issue #57); the pre-#57 nested
`/functions/v1/mcp/mcp` path remains as a compatibility alias and must not be
published to clients. OAuth discovery and provider routes
(`/.well-known/oauth-authorization-server`,
`/.well-known/openid-configuration` (issue #59),
`/.well-known/oauth-protected-resource/mcp`, `/authorize`, `/token`,
`/register`) used the same prefix below `/functions/v1/mcp/`. That deployment
is retained as legacy/local-gateway compatibility and is no longer the
client-facing canonical base.

## Auth
- **Agent side:** remote MCP connectors (Claude.ai custom connector, ChatGPT) use
  OAuth 2.0. The MCP server runs the OAuth provider; the user signs in once with
  the email on their Morsel account and a one-time code is emailed to them.
  The connector gets a per-user Supabase access token after the code verifies.
  The server validates that token with `auth.getUser()` before returning it,
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
  refreshing and returning a Supabase access token, so replay fails even when
  claims race across concurrent isolates or processes. The refresh-token
  wrapper remains encrypted and signed with `MORSEL_OAUTH_SIGNING_KEY`.
- **OAuth token lifetimes and refresh (issue #120):** access tokens are the
  Supabase session access tokens (~1 h, `expires_in`); the client-facing
  refresh wrapper is sealed for 30 days. Every refresh rotates the Supabase
  session and re-seals a new wrapper around the rotated refresh token, so a
  wrapper is single-use upstream: a retry or second consumer of the same
  wrapper would present an already-rotated token. The server therefore keeps
  an in-memory single-flight guard per token (one Fly VM is deployed): within
  the reuse window (10 s by default, `refreshTokenReuseSeconds`) a duplicate
  refresh is answered with the current session instead of 400, and concurrent
  duplicates share one upstream call. After the window a truly dead token
  returns `invalid_grant` with a precise description carrying the upstream
  Supabase Auth message. The Supabase Auth project "refresh token reuse
  interval" should be ≥ the server window so a stale duplicate that outlives
  the in-memory window still maps to the current session upstream (dashboard
  setting, applied by a human).
- **One session per client (issue #120):** a sealed refresh wrapper is bound
  to the client registration that minted it. Re-registering with identical
  `redirect_uris`/`client_name` (the RFC 7591 client lifecycle) re-binds the
  wrapper to the new client id — the refresh is accepted and logged with both
  client fingerprints — while a registration change (different redirect URIs
  or name) keeps older wrappers strictly invalid so a stolen registration can
  never ride an old session. Per RFC 8707 the `resource` parameter may be
  omitted on refresh even when the authorization carried one; two explicit
  URLs must still match.
- **OAuth observability (issue #120):** every `/token` failure logs one
  structured JSON line — `grant_type`, OAuth `error`/`error_description`,
  client fingerprint (first 8 chars of a SHA-256, never the raw client id),
  and `resource` presence — and successes log the same fingerprint at debug
  level. Token values never appear in log payloads, so a rotation chain can be
  followed from Fly logs without exposing credentials.
- **OAuth discovery:** protected-resource metadata is served at both
  `/.well-known/oauth-protected-resource` and
  `/.well-known/oauth-protected-resource/mcp` (and the corresponding
  function-prefixed paths on the legacy Edge base). Authorization-server
  metadata is served at `/.well-known/oauth-authorization-server` and, for
  OpenID Connect discovery, at `/.well-known/openid-configuration` (issue
  #59) — the same document with the same issuer/endpoints. With the path
  issuer `/mcp` on the canonical Fly origin, spec clients append the OIDC
  path to the issuer, so the canonical discovery URL is
  `https://morsel-mcp.fly.dev/mcp/.well-known/openid-configuration`; on the
  legacy Edge base (issuer `/functions/v1/mcp`) the host-root
  `/.well-known/…/functions/v1/mcp` prefixes never reached the function
  (Supabase gateway). The MCP 401 response points clients at the
  path-specific URL.
- **App side:** Supabase Auth (Apple / Google / email OTP). Same `user_id` as the
  agent, so both clients share one store.

## Backend scope (what we are / aren't)
- **We host:** a remote MCP endpoint, a few tables, auth, image storage, a dashboard.
- **We do NOT host:** chat, feeds, social, content moderation, recommendation engines.

## Hosting alternatives considered
1. **Supabase + thin hand-written MCP server** — the Edge Function deployment,
   retained as legacy compatibility while the Fly origin is canonical; the
   store always stays on Supabase. Edge Function
   isolates cannot hold in-memory MCP sessions (issue #71), so the MCP server
   PROCESS moved to Fly.io (issue #72) — see option 3 and `docs/FLY_DEPLOY.md`.
2. **Supabase + auto-generated MCP tools from schema** — least code, less control
   over tool naming/semantics. Look at `supabase-mcp-server` if we go this way.
3. **Fly.io + managed Postgres** — more control over the long-running server,
   with more deployment and operations work. Chosen (and deployed) for the
   MCP server process only: ONE Bun VM keeps the session map alive (issue
   #72); Postgres/Auth/RLS remain on Supabase.
4. **Cloudflare Workers + D1** — cheapest ops / serverless. Revisit if hosting
   cost or always-uptime becomes a concern.

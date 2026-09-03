# Architecture

## Decision
**Supabase store + MCP server hosted as a single process on Fly.io (issue #72;
canonical target after a human deploy) — currently live as a Supabase Edge
Function.** The store stays on Supabase (Postgres + RLS); the MCP endpoint
moves from a Deno Edge Function (canonical transport at the function root,
`https://<public-host>/functions/v1/mcp`, issue #57) to one long-lived Bun
process on Fly so the in-memory MCP session map survives across requests —
Supabase Edge Function isolates cannot hold sessions (issue #71; the live
initialize → notifications/initialized → tools/list breakage). The future
canonical transport is `https://morsel-mcp.fly.dev/mcp` (see
`docs/FLY_DEPLOY.md`); nothing is deployed or cut over by the code change.

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
The production entrypoint is currently `supabase/functions/mcp/index.ts`, a
Supabase Edge Function running Hono and the MCP SDK on Deno. `GET /health` is
public; the function disables the platform JWT check so the app can validate
the per-request bearer token required by the MCP transport. `SUPABASE_URL` and `SUPABASE_ANON_KEY` are read
from the function environment at request time. The gateway strips `/functions/v1`,
so inside the Edge runtime routes register under the function name `mcp` while
publicly exposing the **canonical MCP transport at the function root**,
`/functions/v1/mcp` (issue #57); the pre-#57 nested `/functions/v1/mcp/mcp`
path remains as a compatibility alias and must not be published to clients.
OAuth discovery and provider backend routes use the same canonical prefix:
`/.well-known/oauth-authorization-server`, `/.well-known/openid-configuration`
(issue #59; same authorization-server document for OpenID Connect discovery),
`/authorize`, `/token`, and `/register`
are available below `/functions/v1/mcp/`, and the advertised OAuth `resource`
is the canonical transport URL itself. The BROWSER consent surface is the
static Vercel page under `authorize-ui/` (issue #69): Supabase's free shared
domain rewrites Edge Function `text/html` to `text/plain`, so the function
origin cannot render consent HTML in production. With the optional
`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` set, authorization-server metadata
advertises the Vercel page as `authorization_endpoint`, every `/authorize`
form response is a bodyless 302 back to it (carrying the OAuth parameters,
the sealed transaction envelope, and `#code-entry` on stage 2), and the
page's same-origin `params.js` bridges the allowlisted query fields into
hidden inputs for a direct cross-origin form POST to `/authorize` — no CORS,
no fetch, no proxy. Restoring the production endpoint secret is human-gated
(the deploy workflow only verifies it); while it is unset the function serves
the two email-code stages itself as the pinned fallback (issue #66
hardening), and `/authorize` remains the OAuth backend and issuer either way.

**Fly single-process deployment (issue #72, deploy materials committed,
NOT deployed):** `server/fly-entrypoint.ts` serves the same `createMorselApp`
from one Bun process on Fly (`Dockerfile` + `fly.toml`, one machine, region
`nrt`, `/health` check) so the in-memory session map survives across requests.
On Fly there is no `/functions/v1` gateway prefix, so the app mounts with
`basePath: '/mcp'` — canonical transport `/mcp`, discovery/OAuth routes below
`/mcp/`, `/health` at the raw origin root, and no `/mcp/mcp` alias and no
`/functions/v1` artifacts. `issuer`/`resource`/endpoints derive from the
configured `MORSEL_PUBLIC_BASE_URL` (e.g. `https://morsel-mcp.fly.dev/mcp`),
never from the request Host header; `authorization_endpoint` stays the Vercel
page. After the human deploy steps in `docs/FLY_DEPLOY.md` pass acceptance,
the Fly URL becomes the canonical client-facing endpoint and the Supabase
function URL becomes legacy/internal-only; until then the Edge Function above
remains live and unchanged.

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
  refreshing and returning a Supabase access token, so replay fails across
  concurrent Edge Function isolates. The refresh-token wrapper remains
  encrypted and signed with `MORSEL_OAUTH_SIGNING_KEY`.
- **OAuth discovery:** protected-resource metadata is served at both
  `/.well-known/oauth-protected-resource` and
  `/.well-known/oauth-protected-resource/mcp` (and the corresponding function
  prefixed paths). Authorization-server metadata is served at
  `/.well-known/oauth-authorization-server` and, for OpenID Connect
  discovery, at `/.well-known/openid-configuration` (issue #59) — the same
  document with the same issuer/endpoints. With the path issuer
  `/functions/v1/mcp`, spec clients append the OIDC path to the issuer, so the
  canonical discovery URL is
  `<issuer>/.well-known/openid-configuration`; host-root
  `/.well-known/…/functions/v1/mcp` prefixes never reach the function (Supabase
  gateway). The MCP 401 response points clients at the path-specific URL.
- **App side:** Supabase Auth (Apple / Google / email OTP). Same `user_id` as the
  agent, so both clients share one store.

## Backend scope (what we are / aren't)
- **We host:** a remote MCP endpoint, a few tables, auth, image storage, a dashboard.
- **We do NOT host:** chat, feeds, social, content moderation, recommendation engines.

## Hosting alternatives considered
1. **Supabase + thin hand-written MCP server** — the Edge Function deployment
   that is LIVE today; the store always stays on Supabase. Edge Function
   isolates cannot hold in-memory MCP sessions (issue #71), so the MCP server
   PROCESS moves to Fly.io (issue #72) — see option 3 and `docs/FLY_DEPLOY.md`.
2. **Supabase + auto-generated MCP tools from schema** — least code, less control
   over tool naming/semantics. Look at `supabase-mcp-server` if we go this way.
3. **Fly.io + managed Postgres** — more control over the long-running server,
   with more deployment and operations work. Now chosen for the MCP server
   process only: ONE Bun VM keeps the session map alive (issue #72);
   Postgres/Auth/RLS remain on Supabase.
4. **Cloudflare Workers + D1** — cheapest ops / serverless. Revisit if hosting
   cost or always-uptime becomes a concern.

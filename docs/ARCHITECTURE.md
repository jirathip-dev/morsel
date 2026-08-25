# Architecture

## Decision
**Supabase + a thin remote MCP server.** We host the MCP endpoint and the store;
we do not build a chat app, a feed, or an AI.

## Why hosted (not self-hosted)
The user's agent runs in Claude/ChatGPT's cloud, so the MCP server must be an
internet-reachable endpoint. The data must be shared by both the agent (writer)
and the dashboard (reader), so it cannot live only on-device. → **Always-hosted.**

## Components
```
┌──────────────┐   upload photo + vision   ┌──────────────────────────────┐
│  Claude.ai / │ ────────────────────────▶ │  MORSEL MCP server (Bun/Hono) │
│  ChatGPT /    │   agent calls log_meal   │  · exposes tools (log_meal…)   │
│  any MCP host │                          │  · authenticates user token    │
└──────────────┘                          └──────────────┬───────────────┘
                                                        │ SQL / RLS
                                     ┌──────────────────▼───────────────┐
                                     │  Supabase                         │
                                     │  · Postgres (meals, items, goals) │
                                     │  · Auth (OAuth + app sign-in)    │
                                     │  · Storage (private bucket)       │
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

## Auth
- **Agent side:** remote MCP connectors (Claude.ai custom connector, ChatGPT) use
  OAuth 2.0. The MCP server runs the OAuth provider; the user signs in once and
  the connector gets a per-user access token. The server uses it as `auth.uid()`
  → RLS applies. (Same pattern as `nutrition-mcp`'s Claude.ai connector.)
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
3. **Cloudflare Workers + D1** — cheapest ops / serverless. Revisit if hosting
   cost or always-uptime becomes a concern.

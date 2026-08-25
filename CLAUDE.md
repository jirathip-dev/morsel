# AGENTS.md — context for agents working in this repo

## What this project is
Morsel is an **MCP-first, camera-first** food tracker. The product is a data
store + dashboard + agent skill; there is **no in-app chat and no in-app AI**.
The user logs by chatting with Claude/ChatGPT and uploading a food photo; the
assistant's agent calls Morsel's MCP tools to write structured nutrition data.

## Where the source of truth lives
- **The tool contract** = `docs/MCP_TOOLS.md` and `packages/schema/food-types.ts`.
  When the contract changes, edit the schema FIRST; the server and the agent
  skill derive from it. Do not hand-edit tool implementations until they drift.
- **The data model** = `db/migrations/*.sql` (canonical) + `docs/DATA_MODEL.md`.
- **Architecture** = `docs/ARCHITECTURE.md`.

## Conventions
- **Server** = Bun + Hono + MCP SDK over streamable HTTP. **App** = SwiftUI.
  **Store** = Supabase: Postgres + Auth + RLS + Storage (food images).
- Every table is user-scoped and guarded by RLS (`auth.uid() = user_id`). The
  MCP server authenticates with the user's access token so policies apply.
- Keep the tool set small and talkative: agents work better with clear, few
  tools than many overlapping ones.
- A feature is not done until **all three** describe it: the MCP tool schema,
  the agent skill, and the dashboard rendering what it produced.

## Rules
- Never publish, push, or open issues/PRs without explicit human approval.
- Read `docs/DATA_MODEL.md` and `docs/MCP_TOOLS.md` before writing any code.

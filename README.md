# Morsel

> The storehouse your AI fills. Morsel is a **MCP-first, camera-first** food
> tracker. There is **no chat inside the app** — you log by chatting with your
> existing assistant (Claude, ChatGPT) and uploading a photo; the assistant's
> agent reads the photo, calls Morsel's MCP tools, and writes structured food
> data to your store. Morsel is the **data store + dashboard + agent skill**;
> the intelligence lives in the agent you already use.

## Why this exists
People chat with Claude/ChatGPT every day but can't keep context or structured
data. Generic calorie apps re-implement their own AI, locked inside a silo.

Morsel flips it:
- **No in-app chat.** The app has no AI brain and no chat UI.
- **MCP-first.** The app is a Model Context Protocol server + a data store. Your
  agent connects over MCP and knows the exact data structure to write.
- **Camera-first.** You upload a food photo in your chat app; the agent's vision
  estimates macros and calls `log_meal`.
- **Dashboard.** A native iOS app (or PWA) renders your history, totals, and
  goals — reading the same store the agent writes.

## Architecture (one line)
Supabase (Postgres + auth + RLS + storage) ↔ thin remote MCP server ↔ your agent
(Claude/ChatGPT) **and** ↔ native iOS dashboard. **One store, two clients.**

## Repo layout
```
morsel/
├── docs/            # design docs (start here)
├── server/          # remote MCP server (Bun + Hono + MCP SDK)
├── app/             # native iOS dashboard (SwiftUI) — reads Supabase
├── db/              # Postgres migrations + seed
├── packages/schema/ # canonical types + JSON schemas for the tool contract
├── skills/          # agent skill(s) you attach to Claude / ChatGPT
└── supabase/        # project config
```

## Docs
- [ARCHITECTURE](docs/ARCHITECTURE.md) — components, data flow, auth, backend decision
- [DATA_MODEL](docs/DATA_MODEL.md) — tables, enums, RLS
- [MCP_TOOLS](docs/MCP_TOOLS.md) — the tool contract (input/output schemas) — *what the agent writes*
- [TARGETS](docs/TARGETS.md) — computed calorie/macro goal from body metrics
- [IN_CHAT_RENDER](docs/IN_CHAT_RENDER.md) — Tier-1 snapshot rendering inside Claude/GPT
- [ROADMAP](docs/ROADMAP.md) — milestones
- [CLAUDE.md](CLAUDE.md) — context for any agent working in this repo (`AGENTS.md` is a symlink to it)

## Status
Design scaffold with quality guardrails in place (strict TypeScript, anti-slop
ESLint + SwiftLint, CI on every PR). Working name `morsel` (rename freely —
it's a folder + a README).

## License
MIT — see [LICENSE](LICENSE).

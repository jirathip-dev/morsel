# In-chat rendering (Tier 1 — snapshot)

Morsel is **readable inside Claude/GPT**: the agent calls a read tool and the
result is rendered inline in the chat window. This doc only covers **Tier 1 —
snapshot**. Tier 2 (live MCP "Apps" widgets) is deferred; see below.

## Tl;DR
- Tier 1 = the agent returns a **rendered image + markdown table** from a read
  tool. Cheap, works in Claude.ai, Claude Desktop, **and** ChatGPT.
- Tier 2 = live interactive widgets embedded via the MCP `ui/*` Apps protocol
  (what `nutrition-mcp` ships). Claude.ai/Desktop-first; a whole extra frontend.
  **We do NOT build Tier 2 now.**

## What Tier 1 actually is
The agent calls `get_dashboard_summary` (or `get_day`), and the MCP server
returns content the host can render inline:

| Emitted content | Renders where | Notes |
|---|---|---|
| `image` content block (`{ type:"image", data:<base64 SVG>, mimeType:"image/svg+xml" }`) | Claude.ai, Claude Desktop, many clients | a server-generated chart: calorie ring, macro split, 7-day trend |
| `text` markdown (`type:"text"`) | **everywhere** | the monthly view / day totals / macro table — the fallback |
| `resource` link (`morsel://daily-summary`) | Claude Desktop best | an MCP Resource the client can open for a fuller view |

**Golden rule: Tier 1 is read-only.** No interactive editing in the chat view.
Edits happen through tools (`log_meal` / `update_meal_item` / `delete_meal_log`)
or the native app.

## The snapshot renderer
The server computes the view and returns **two blocks** per call so it renders
in every client:

```
get_dashboard_summary({ days: 7 })
=> tool result content:
   [
     { type:"text",  text:"# This week\nCalories avg 1872 / target 2000\n…" },
     { type:"image", data:"<base64 SVG>", mimeType:"image/svg+xml" }
   ]
```
- `search_food` / `log_meal` / totals all flow through the same Supabase store.
- The image is generated server-side as SVG (without native rasterization) from
  the same summary the iOS dashboard renders — one dataset, many views.

## MCP Resource
Register a read-only resource for proactive pulls and "open the full picture":

| URI | Description |
|---|---|
| `morsel://daily-summary` | Today's totals vs goal, macro split, live — for proactive pulls |
| `morsel://overview` | 7-day digest (averages, trend, streak) |

(analogous to `nutrition-mcp`'s `nutrition://weekly-summary`)

## Client support (be honest)
- **Claude.ai / Claude Desktop** — render image + markdown + resource links.
  Best support for Tier 1; also the only clients where Tier 2 is possible.
- **ChatGPT** — renders text/markdown, and images where supported; resource-follow
  is weaker. Tier 1 markdown is the safe floor here.
- **Unknown MCP clients** — markdown is always safe; always include a `text` block.

## Decision & scope
- **Ship Tier 1 in v0.2.** Adds a server-side renderer + two MCP Resources.
  No new client requirements.
- **Tier 2 (MCP Apps `ui/*` widget) = separate spike, later.** Claude.ai-only,
  requires a third frontend (the widget HTML) in addition to the native app, and
  duplicates rendering work. Park it unless the "rings in chat" wow is worth it.

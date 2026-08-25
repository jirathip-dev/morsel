# Roadmap

Working name: **Morsel**. The canonical running log for each item is a GitHub
issue under the repo (spec + acceptance criteria) — per the new-idea convention,
a plan doc only exists here for the multi-step design. This file is the design
roadmap; issues track live work.

## v0.1 — Prove the contract (MCP server + store)
- [ ] Supabase project + `db/migrations/0001_init.sql` applied.
- [ ] Thin Bun/Hono MCP server exposing `log_meal`, `search_food`, `get_day`.
- [ ] OAuth for Claude.ai custom connector / ChatGPT connector.
- [ ] Agent skill attached; a human can log a meal from a photo end-to-end.
- **Acceptance:** upload a photo in Claude.ai → `log_meal` → row visible in a Supabase table.

## v0.2 — Photo + dashboard
- [ ] Camera/photo upload path; image lands in `food-images` storage bucket.
- [ ] iOS (SwiftUI) dashboard: today's meals, totals, remaining vs goal, low-confidence review.
- [ ] `get_dashboard_summary` + streak/macro-split API for the UI.
- [ ] **Tier-1 in-chat render:** `get_dashboard_summary` returns an image + markdown table so
  the result renders inside Claude.ai / ChatGPT (see [IN_CHAT_RENDER](IN_CHAT_RENDER.md)).
- **Acceptance:** a logged meal appears on the phone dashboard without touching the DB;
  `get_dashboard_summary` renders a snapshot inside the chat.

## v0.3 — Correctness & trust
- [ ] `update_meal_item` / `delete_meal_log` wired into the dashboard (edit + delete).
- [ ] `search_food` against an external nutrition DB (OpenNutrition/Calories) for exact macros.
- [ ] Confidence-driven UX: low-confidence items surfaced for one-tap correction.
- **Acceptance:** every agent estimate is correctable from the app.

## v0.4 — Polish & publish
- [ ] PWA fallback + App Store build.
- [ ] `set_goals` (calorie/macro targets) setting screen.
- [ ] v1.1 extras: `log_water`, `log_weight`, weight trend.
- **Acceptance:** a new user can sign in, connect an AI app, and log + review a day.

## Out of scope (deliberately)
No in-app chat, no in-app AI, no meal recommendation engine, no social/feed.
The assistant you already use is the brain; Morsel is the store + dashboard.

## Open questions
- Photo macro accuracy: do we favor the agent's vision estimate or a curated
  database, and how do we blend confidence? (v0.3 focus.)
- Should the iOS app also be able to add/edit without the agent, as a fallback UX?
- D1/Cloudflare-only migration if hosting cost becomes material (architecture doc).

# Data model

Canonical SQL lives in [`db/migrations/0001_init.sql`](../db/migrations/0001_init.sql).
This doc is the narrative version.

## Entities

| Table | Purpose | Key link |
|---|---|---|
| `users` | one row per account | — |
| `profiles` | body metrics driving a **computed** target (age, sex, height, weight, activity, diet goal) | `user_id` |
| `goals` | **effective** calorie/macro targets; computed from profile unless overridden (`source`) | `user_id` |
| `meal_logs` | a meal session; **one photo = one log** | `user_id` |
| `meal_items` | individual foods inside a meal (a meal → many items) | `meal_log_id` |
| `water_logs` | optional, v1.1 | `user_id` |
| `weight_logs` | optional, v1.1 | `user_id` |
| `food_catalog` | optional curated food reference for search | `barcode` |

## The core shape: a meal is a log, a log has many items

```
users 1 ──▶ N meal_logs 1 ──▶ N meal_items
```

This matches the agent's mental model: an uploaded photo of a bowl of rice,
chicken, and vegetables is ONE `meal_log` with THREE `meal_items`. The `log_meal`
tool takes an `items[]` array for exactly this reason.

## Targets are computed

The calorie/macro goal is **derived from the profile**, not a blank manual number.
`profiles` holds body metrics; `goals` holds the *effective* target plus a
`source` (`computed` | `manual`). See [`TARGETS.md`](TARGETS.md) for the formula
(Mifflin-St Jeor → activity factor → diet goal) and the review-and-adjust flow.

## Enums (CHECK constraints)

- `meal_type`: `breakfast` | `lunch` | `dinner` | `snack`
- `source`: `manual` | `photo_vision` | `barcode` | `import` | `voice`
- `unit`: `g` | `ml` | `serving` | `piece` | `cup`

## Key columns

- `meal_logs.eaten_at` — when the meal happened (agent passes it, not timestamp of upload).
- `meal_logs.image_path` — normally `food-images/{user_id}/{meal_log_id}.jpg` in
  Supabase Storage. Until the v0.1 upload flow exists, the MCP adapter stores a
  caller-provided HTTPS `image_url` verbatim in this text column as an external
  reference; consumers must render HTTPS values directly and only send
  storage-shaped values through the Storage client.
- `meal_items.confidence` — 0..1, how sure the detecting agent is. Low confidence
  should surface in the dashboard as "review me" items.
- `meal_items.source_notes` — the agent's own reasoning ("approx, shared plate").
  Note that wrong-ish estimates, if honest, should be kept (human can correct later).

## Row-level security

Every user-scoped table is guarded by `auth.uid() = user_id`. `meal_items` is
an exception: it has no `user_id`, so policies join through the parent
`meal_logs`. That subquery works but is heavier per-row; if it ever becomes a
hot path, add a denormalized `user_id` to `meal_items` and key on it directly.

## Why one store for two clients

The agent (via MCP) and the dashboard (via Supabase SDK) both read/write `user_id`
rows. Because both authenticate to the same store and RLS scopes by the same
`auth.uid()`, they can never see each other's data. No separate REST API needed.

## Images

The intended storage location is the Supabase Storage bucket `food-images`, path
`{user_id}/{meal_log_id}.jpg`. Until the upload flow exists, the MCP server
stores a caller-provided HTTPS URL reference in `meal_logs.image_path` and does
not upload bytes. When upload is implemented, the bucket policy must allow
authenticated users to read/write only their own prefix.

# Data model

Canonical schema SQL lives in the numbered files under [`db/migrations/`](../db/migrations/),
starting with [`0001_init.sql`](../db/migrations/0001_init.sql); deployment seed
data lives in [`db/seed.sql`](../db/seed.sql). This doc is the narrative version.

Applied migrations are recorded in `public.migration_ledger` (`name` primary
key, `applied_at`), created by the recovery runner (never bootstrapped by
`apply-migrations.mjs`, which appends future migrations and their ledger rows
in one atomic transaction and fails with zero writes when the ledger is
missing/empty). Production was provisioned before the ledger existed; the
human-gated reconciliation flow in
[`docs/MIGRATION_RECOVERY.md`](../docs/MIGRATION_RECOVERY.md) (issue #76)
classifies the canonical migration set (currently 0001–0011) against their
end-state contracts and converges missing/partial states idempotently before
recording them; later migrations (such as `0011_profiles_timezone.sql`) are
appended through `apply-migrations.mjs` in the same atomic ledger transaction.

## Entities

| Table | Purpose | Key link |
|---|---|---|
| `users` | one row per account | — |
| `profiles` | body metrics driving a **computed** target (age, sex, height, weight, activity, diet goal) plus the stored IANA `timezone` used for local-day bucketing | `user_id` |
| `goals` | **effective** calorie/macro targets; computed from profile unless overridden (`source`) | `user_id` |
| `meal_logs` | a meal session; **one photo = one log** | `user_id` |
| `meal_items` | individual foods inside a meal (a meal → many items) | `meal_log_id` |
| `water_logs` | optional, v1.1 | `user_id` |
| `energy_burned_logs` | daily active-energy imports, v1.1 | `user_id` |
| `weight_logs` | Apple Health body-mass measurements | `user_id` |
| `food_catalog` | curated and USDA FoodData Central-backed reference data for search; external results are cached with `source='usda'` | `barcode` |

## The core shape: a meal is a log, a log has many items

```
users 1 ──▶ N meal_logs 1 ──▶ N meal_items
```

This matches the agent's mental model: an uploaded photo of a bowl of rice,
chicken, and vegetables is ONE `meal_log` with THREE `meal_items`. The `log_meal`
tool takes an `items[]` array for exactly this reason.

## Local days and timezones (issue #121)

Day-scoped reads (`get_day`, `get_dashboard_summary`, `get_weight_trend`,
`get_energy_burned`) and the `log_meal` local-date report bucket days as
**calendar days in a timezone**, never in a fixed UTC grid. The zone is resolved
per call as: explicit tool `timezone` input → `profiles.timezone` → UTC.
`profiles.timezone` is a nullable `text` column added by migration
`0011_profiles_timezone.sql`; the column CHECK only admits the fixed `'UTC'`
alias or IANA `Area/Location` names (server-side `Intl` validation is the
authoritative gate before any write). NULL (the default for every existing
profile) means "UTC as today" — the v0.1 behavior — so existing rows and
clients without a zone are untouched. Instants (`meal_logs.eaten_at`,
`weight_logs.measured_at`, `energy_burned_logs.burned_at`) are never changed;
only the derived day buckets, streak windows, and "today" anchors move.

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
- `meal_logs.image_path` — normally the `food-images` bucket with object path
  `{user_id}/{meal_log_id}.jpg` in Supabase Storage. Until the v0.1 upload flow
  exists, the MCP adapter stores a caller-provided HTTPS `image_url` verbatim in
  this text column as an external reference; consumers must render HTTPS values
  directly and only send storage-shaped values through the Storage client.
- `meal_items.confidence` — 0..1, how sure the detecting agent is. Low confidence
  should surface in the dashboard as "review me" items.
- `meal_items.food_ref_id` — an optional UUID linking to `food_catalog`; the MCP
  schema rejects non-UUID values before the database transaction begins.
- `meal_items.source_notes` — the agent's own reasoning ("approx, shared plate").
  Note that wrong-ish estimates, if honest, should be kept (human can correct later).
 - `weight_logs.measured_at` — the original HealthKit measurement timestamp;
  `(user_id, measured_at)` is unique so background sync is idempotent. Its
  `source` is `manual` or `apple_health`.

## Idempotent meal writes (native offline outbox, issue #106)

`public.log_meal_with_items_client` (migration `0010_meal_outbox_client_ids.sql`)
is the native app's idempotent meal write. The app generates the meal row
identity client-side and passes it as `p_client_meal_id`; a retried delivery
after a server-side commit conflicts on `meal_logs.id` (`on conflict (id) do
nothing`) and returns the already-committed row instead of inserting a
duplicate — duplicates are never deduped only in the client. The item insert
runs only when the client id was NOT already committed, and an id that exists
under a different `user_id` raises `42501`, so a foreign client id can never
write through the authenticated path. The original `log_meal_with_items`
(server/MCP path) keeps its server-generated identity and is untouched.
The native app's local cache/outbox lives in a per-account SQLite store
(`Application Support/Morsel/<user_id>/`) and is NOT part of the server data
model; see `docs/APP_DATA_RELIABILITY.md`.

## Row-level security

Every user-scoped table is guarded by `auth.uid() = user_id`. `meal_items` is
an exception: it has no `user_id`, so policies join through the parent
`meal_logs`. That subquery works but is heavier per-row; if it ever becomes a
hot path, add a denormalized `user_id` to `meal_items` and key on it directly.
The `users` table is guarded by owner policies using `auth.uid() = id` for
select, insert, and update.
`food_catalog` is shared reference data: authenticated clients can select it,
while its seed-owned rows have no client write policies.
`oauth_authorization_grants` is a short-lived user-scoped table provisioned by
`0005_oauth_authorization_grants.sql`. Authenticated users may insert only rows
where `auth.uid() = user_id`; the public `claim_oauth_authorization_grant` RPC
deletes and returns a matching unexpired row atomically, making an OAuth code
single-use across Edge Function isolates. Its server-side refresh credential is
never embedded in the client-facing authorization code.

## Why one store for two clients

The agent (via MCP) and the dashboard (via Supabase SDK) both read/write `user_id`
rows. Because both authenticate to the same store and RLS scopes by the same
`auth.uid()`, they can never see each other's data. No separate REST API needed.

## Images

The intended storage location is the private Supabase Storage bucket
`food-images`, object path `{user_id}/{meal_log_id}.jpg`. Migration
`0004_store_assets.sql` provisions the bucket and allows authenticated users to
insert, read, update, and delete objects only when the first path segment is
their own user ID. Until the upload flow exists, the MCP server stores a
caller-provided HTTPS URL reference in `meal_logs.image_path` and does not
upload bytes.

The catalog starts with a small deterministic seed in `db/seed.sql` and is extended by the USDA FoodData Central lookup path. Successful external results are cached with `source='usda'`; the server-only cache write path keeps shared catalog data out of caller-controlled writes.

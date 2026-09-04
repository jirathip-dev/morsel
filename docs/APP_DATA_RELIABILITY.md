# App data reliability (issue #106)

Local-first persistence + synchronization behind the #105 journal surfaces:
account-scoped SQLite local store, a durable meal/photo outbox with
duplicate-safe authenticated writes, truthful pending / needs-attention state,
fast cached first paint, restart/session isolation, and independent
bodyMass + activeEnergyBurned Apple Health import/retry/status.

Reference architecture concepts come from the proven Sendmeter pattern —
concepts only; no UI/domain copy.

## Scope

- HealthKit types: **bodyMass** and **activeEnergyBurned ONLY** (never
  expanded here to sleep/HRV/water/other types).
- Signed-artifact background-delivery entitlement is declared; on-device and
  TestFlight acceptance of background delivery is HUMAN-GATED and never
  claimed from simulator evidence.

## Local store (per account, SQLite)

- Location: `Application Support/Morsel/<account-id>/data.sqlite` (one file
  per authenticated account — isolation by construction; logout removes the
  directory; an old account's worker is cancelled before a new account is
  assembled).
- Tables: `meal_outbox` (durable queued meal: items JSON + photo BLOB in ONE
  row = one transaction), `dashboard_cache` / `history_cache` / `goals_cache`
  (authoritative snapshot JSON written through on successful remote reads),
  `weight_samples` / `energy_days` (local-first Apple Health rows),
  `meta` (sync watermarks + last-successful-upload timestamps only).
- **No tokens/secrets are ever persisted** — the store holds data rows only;
  authentication stays in the Supabase SDK session (Keychain-backed).

## Meal save path (the reported “Add meal does not save”)

1. Validate the draft (name/quantity/macros) and the photo BEFORE enqueueing.
2. Durable local commit: meal + items + photo in one SQLite transaction with
   a client-generated meal UUID (the idempotency key). The UI can leave Add
   Meal immediately and shows the row with an honest `pending sync` marker —
   it never waits for a second full `loadToday` to decide local success.
3. The single-flight per-account worker reconciles rows with the
   authenticated security-invoker RPC `log_meal_with_items_client`, passing
   the client id as `p_client_meal_id` (server primary key). A timeout after
   a server commit retries the SAME id; migration 0010's
   `on conflict (id) do nothing` + items-insert-only-when-inserted guard
   means the retry reads back the authoritative committed row — never a
   duplicate meal, never a duplicated item batch. The original
   `log_meal_with_items` (server/MCP path) is untouched.
4. Photo objects are deterministic per meal (`food-images/<user>/<meal-id>.jpg`,
   idempotent upsert): a recoverable upload failure retries the same object;
   a permanent refusal deletes the just-uploaded object (no orphaned photo on
   a rejected meal) while the local payload stays recoverable.
5. Outcome mapping (raw Supabase/Postgres text is never persisted or shown):
   - transient (network/5xx/timeout) → stays `pending`, bounded backoff;
   - permanent auth (`42501`, session refusal) → durable `needs attention`
     state with friendly copy; rows retry after a fresh foreground/session;
   - permanent validation (`22xxx`/`22023`) → durable `needs attention`.
   Remote success is only claimed after the authoritative RPC result is read
   back and matches the queued client id.
6. Deleting a never-synced queued meal cancels the outbox row locally (the
   server never saw it); editing a queued item mutates the durable draft.

## HealthKit (body mass + active energy)

- Samples land in the local store FIRST (validation: finite, > 0; weight
  dedupe per measurement time — later value replaces, identical re-import
  stays clean; energy aggregated per UTC day with sample-level dedupe).
- Each type imports INDEPENDENTLY: one type's denial/query failure never
  suppresses the other's import or status.
- Last-successful watermark per type avoids full-history rescans on every
  event; observer queries + background delivery register immediately,
  independently of any remote Supabase result; each kind's handler imports
  only its own type; overlapping callbacks coalesce (single-flight per type);
  the HealthKit completion handler is called exactly once per callback and
  observing continues after a failed attempt.
- Local rows upload through the authenticated idempotent upserts
  (`weight_logs` conflict `user_id, measured_at`; `energy_burned_logs`
  conflict `user_id, burned_at`) in the same durable worker; failures leave
  rows dirty for the next pass.
- Calm status surface (Settings): last successful sync / pending /
  permission-required / unavailable — raw entitlement/HK domain strings never
  reach the UI, and a user-invokable retry/reconnect path exists.

## Read path

- Warm launch: the last cached snapshot paints immediately; the remote
  snapshot then converges in the background. A remote failure never erases a
  valid cached snapshot; queued rows are merged into the served journal so a
  local save is visible even fully offline.
- One slow HealthKit or remote request never blocks the first useful journal
  paint.

## Test map (native XCTest)

- `AddMealReliabilityRegressionTests` — production-shaped regression for the
  reported not-saving path: RED against the network-first base, GREEN at this
  head (write committed + follow-up reload fails → save still succeeds).
- `LocalStoreTests` — SQLite semantics: single-row durability, relaunch
  recovery, per-account isolation, clear, attempt/needs-attention bookkeeping,
  cache round-trip, weight/energy dedupe + dirty rules, watermarks.
- `MealReliabilityTests` — offline save + pending paint, relaunch recovery,
  cache-first reads, cache preservation on failure, timeout-after-commit retry
  (single insert), repeated transient then success, double `syncNow` never
  duplicates, photo retry (deterministic object), permanent refusal cleanup,
  pending delete cancels outbox, queued edits, merge without duplication.
- `HealthReliabilityTests` — per-type independence, watermark-bounded
  re-import, duplicate re-import stays clean, per-kind observer handlers,
  single-flight coalescing (no concurrent import; exactly one follow-up),
  calm status copy (permission-required etc., never raw system text), durable
  upload drain and failure retention.

## Boundaries

- The local store is a cache/outbox, never a bypass: RLS, the security-invoker
  meal transaction, authenticated-user scoping and friendly error boundaries
  stay authoritative on the server. No service-role client exists in the app.
- Simulator evidence ≠ device acceptance for HealthKit background delivery.
- HealthKit scope remains bodyMass + activeEnergyBurned only.

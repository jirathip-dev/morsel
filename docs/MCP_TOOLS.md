# MCP tool contract

This is the **single source of truth** for the tools an agent can call against
Morsel. The server implements these; the agent skill (`skills/food-logging/SKILL.md`)
dog-ears them. When you change a tool here, change the schema, the server, and the
skill together.

Canonical types: [`packages/schema/food-types.ts`](../packages/schema/food-types.ts).

## Tool list

Every registered tool carries a client-visible `title`, the existing
description, explicit input and output schemas, and an explicit SDK
`annotations` object. "Annotations" below lists only the true claims; see
[Safety annotations](#safety-annotations) for the full wire contract.

| Tool | Title | Direction | Purpose | Annotations |
|---|---|---|---|---|
| `log_meal` | Log a meal | write | **The main one.** Record a meal (and its items). Photo path uses this. | — |
| `search_food` | Search the food catalog | read | Find a food in the catalog by name/barcode (so the agent can use real macros instead of guessing). | `openWorldHint` (see [search_food cache write](#search_food-cache-write)) |
| `update_meal_item` | Update one meal item | write | Correct one item (wrong macro, wrong portion). | — |
| `delete_meal_log` | Delete a meal log | write | Remove a whole meal. | `destructiveHint` |
| `get_day` | Get a day of meals | read | One day's meals + totals + remaining vs goal. | `readOnlyHint` |
| `get_dashboard_summary` | Get the dashboard summary | read | Range totals, streak, macro split, weight trend. | `readOnlyHint` |
| `get_profile` | Get the body profile | read | Body metrics (sex, age, height, weight, activity, diet goal). | `readOnlyHint` |
| `set_profile` | Set the body profile | write | Upsert body metrics. | — |
| `compute_targets` | Compute nutrition targets | read | BMR/TDEE + kcal + macro split derived from profile. | `readOnlyHint` |
| `get_goals` | Get the effective goal | read | **Effective** targets — "latest update wins" (computed default; manual override only while at least as new as the profile, else `superseded_manual`) + `source`. | `readOnlyHint` |
| `set_goals` | Set manual goals | write | Manual override (marks `source='manual'`). | — |
| `reset_goals` | Reset manual goals | write | Discard the stored manual override; effective target returns to computed. | — |
| `get_weight_trend` | Get the weight trend | read | Apple Health body-mass series and latest measurement. | `readOnlyHint` |
| `get_energy_burned` | Get energy burned | read | Apple Health daily active-energy burn series. | `readOnlyHint` |

## Safety annotations

The MCP SDK exposes tool metadata through the real registration/inspection
path (`tools/list`). Morsel registers the annotations below as client-visible
hints. They describe what a call may do to **state** so clients can classify a
tool as read-only or as requiring write/delete confirmation.

Every registered tool emits the **full** SDK annotation set as explicit
booleans — `{ readOnlyHint, destructiveHint, idempotentHint, openWorldHint }` —
so no client or reviewer ever has to infer meaning from an absent field. In
the table above, `readOnlyHint` / `destructiveHint` / `openWorldHint` mean
that field is `true` (and all other fields are `false`); "—" means all four
fields are explicit `false`: the tool claims no safety class. The claim rules:

- `readOnlyHint: true` — claimed **only** for tools whose full implementation
  path provably never writes; every reachable call is a read (`SELECT` /
  immutable `compute_targets` RPC):
  - `get_profile` — reads `profiles`.
  - `get_day`, `get_dashboard_summary` — read `meal_logs`, `meal_items`,
    `profiles`, `goals`, `weight_logs`, and the immutable `compute_targets` RPC.
  - `compute_targets`, `get_goals` — read `profiles`, `goals`, `weight_logs`,
    and the immutable `compute_targets` RPC.
  - `get_weight_trend` — reads `weight_logs`.
  - `get_energy_burned` — reads `energy_burned_logs`.
  All other tools assert `readOnlyHint: false` because their implementation
  can write.
- `destructiveHint: true` — claimed only for `delete_meal_log`. Deleting a
  meal log is a hard, owner-scoped `DELETE` of the `meal_logs` row; `meal_items`
  rows cascade-delete with it (foreign key `on delete cascade`, migration
  0001). There is no archive, soft-delete, or restore path, so the effect is
  irreversible. The other write tools (`log_meal`, `set_profile`, `set_goals`,
  `reset_goals`, `update_meal_item`) assert `destructiveHint: false`: they
  create or overwrite owned rows and remove nothing — `reset_goals` rewrites
  the `goals` row to `source='computed'` with its values cleared (no `DELETE`),
  and the manual numbers it replaces are returned in the earlier `get_goals`
  / `set_profile` `superseded_manual` payloads when clients need them.
- `idempotentHint: false` — asserted on **every** tool: the server makes no
  retry-safety promise. `log_meal` inserts a new meal log on every call, so a
  blind retry duplicates data; `delete_meal_log` errors with `not_found` once
  the log is gone; the remaining writes are upserts that converge, but they
  are deliberately not advertised as retry-safe.
- `openWorldHint: true` — claimed **only** for `search_food`. The SDK defines
  the hint as whether the tool may interact with an "open world" of external
  entities — its canonical example is a web search tool, whose world is open —
  and defaults it to `true`. `search_food`'s configured catalog-miss path
  calls the live USDA FoodData Central web-search API
  (`nutrition-provider.ts`), so its domain of interaction is open. Every other
  tool asserts `openWorldHint: false`: their domain of interaction is closed —
  the authenticated account's stored rows plus deterministic server-side
  computation only.

<a id="search_food-cache-write"></a>

`search_food` is **not** annotated `readOnlyHint` even though it never touches
user data, and it is the **only** open-world tool (`openWorldHint: true`). On
a catalog miss the server queries the live USDA FoodData Central web-search
API and, when a cache client is configured, persists the matched
provider-derived rows into the **shared** `food_catalog` table through the
service-role-only `upsert_food_catalog` RPC (deterministic UUIDs derived from
`fdc_id`, `source='usda'`, conflict-no-op). That is a write of shared server
state on a real path, so a strict "does not modify any state" claim would be
inaccurate; and because the miss path reaches an external web service, the
tool's domain of interaction is open. Callers keep read semantics for their
own data; nothing about the user's rows, RLS scoping, or confirmation behavior
changes.

Annotations are **advisory to clients only**: they are server-authored
metadata emitted over `tools/list` and are never consulted by the server at
call time. They cannot grant or deny access, cannot be used to bypass
authorization, and change nothing about Supabase Auth/RLS enforcement
(`auth.uid()`-scoped policies and the repository's ownership checks still gate
every call). A client that ignores or misreads a hint can neither write with a
read-annotated tool nor read or mutate another user's data.

## Tool schemas

### `log_meal`

**Purpose:** record a meal. When the user uploads a food photo, the agent does
vision → fills `items[]` → calls this. `source` is set internally by the server:
`photo_vision` when `image_url` is present, `barcode` when an item has a barcode
but no image, and `manual` otherwise.

The server writes the meal log and every item through one database transaction;
an RPC failure leaves no partial meal rows.

**Input**
```json
{
  "type": "object",
  "properties": {
    "eaten_at":    { "type": "string", "format": "date-time", "description": "When the meal happened (not upload time). Default: now." },
    "meal_type":   { "type": "string", "enum": ["breakfast", "lunch", "dinner", "snack"] },
    "items": {
      "type": "array", "minItems": 1,
      "items": {
        "type": "object",
        "required": ["name"],
        "properties": {
          "name":        { "type": "string" },
          "quantity":    { "type": "number", "default": 1 },
          "unit":        { "type": "string", "enum": ["g", "ml", "serving", "piece", "cup"] },
          "calories_kcal": { "type": "number" },
          "protein_g":   { "type": "number" },
          "carbs_g":     { "type": "number" },
          "fat_g":       { "type": "number" },
          "fiber_g":     { "type": "number" },
          "sugar_g":     { "type": "number" },
          "barcode":     { "type": "string" },
          "food_ref_id": { "type": "string", "format": "uuid", "description": "UUID id returned by search_food for exact macros" },
          "confidence":  { "type": "number", "minimum": 0, "maximum": 1, "description": "0..1 how sure the agent is. Low = user should review." },
          "notes":       { "type": "string", "description": "Agent reasoning, e.g. 'approx, shared plate'" }
        }
      }
    },
    "notes":     { "type": "string" },
    "image_url": { "type": "string", "format": "uri", "description": "Public HTTPS URL of the food photo, if any" }
  },
  "required": ["meal_type", "items"]
}
```

**Output**
```json
{
  "type": "object",
  "properties": {
    "meal_log_id": { "type": "string", "format": "uuid" },
    "recorded":    { "type": "boolean", "default": true }
  },
  "required": ["meal_log_id", "recorded"]
}
```

Macro fields are totals for the whole item as eaten. The server stores them as
provided and never multiplies them by `quantity` or `unit`; scale values from a
`search_food` result's `serving_size` and `serving_unit` before calling
`log_meal`. If either serving field is absent, the serving basis is unknown: do
not treat the returned macros as one serving; seek clarification or use an
explicitly noted lower-confidence estimate.

**Example call (photo → log):**
```
log_meal({
  "meal_type": "lunch",
  "eaten_at": "2026-08-25T12:30:00+07:00",
  "items": [
    { "name": "Jasmine rice",   "quantity": 1, "unit": "serving", "calories_kcal": 220, "carbs_g": 48, "confidence": 0.9 },
    { "name": "Grilled chicken","quantity": 120, "unit": "g", "calories_kcal": 200, "protein_g": 38, "fat_g": 5, "confidence": 0.85 },
    { "name": "Stir-fried veg", "quantity": 1, "unit": "serving", "calories_kcal": 90, "carbs_g": 10, "fiber_g": 4, "confidence": 0.7, "notes": "approx portion" }
  ],
  "image_url": "https://.../meal-photo.jpg"
})
```
→ `{ "meal_log_id": "9fce...", "recorded": true }`

### `search_food`

**Input** `{ "query": "string", "limit": { "type": "integer", "default": 8 } }`
**Output** `{ "results": [ { "id", "name", "brand", "barcode", "serving_size", "serving_unit", "calories_kcal", "protein_g", "carbs_g", "fat_g" } ] }`

The store reads this catalog from `food_catalog`, with a small deterministic
curated set in `db/seed.sql`. When the catalog has no match, the server queries
the USDA FoodData Central `/fdc/v1/foods/search` endpoint using `USDA_API_KEY`,
maps its `foods[].foodNutrients` values into this unchanged contract, and caches
successful results in `food_catalog`. External IDs are deterministically mapped
to UUIDs. Unknown food returns empty results; a missing key uses catalog-only
search, while an unavailable provider returns a typed tool error.

### `update_meal_item`

**Input** `{ "item_id": "uuid", "calories_kcal?": "number", "protein_g?": "number", "carbs_g?": "number", "fat_g?": "number", "quantity?": "number", "name?": "string" }`
**Output** `{ "ok": true, "updated": true }`

At least one optional field must be supplied with `item_id`.

### `delete_meal_log`

**Input** `{ "meal_log_id": "uuid" }`
**Output** `{ "ok": true, "deleted": true }`

### `get_day`

**Input** `{ "date": "YYYY-MM-DD" }`
**Output** `{ "date", "meals": [ { meal_log_id, meal_type, eaten_at, items: [ { item_id, name, quantity, unit, ... } ] } ], "totals": { "calories_kcal", "protein_g", "carbs_g", "fat_g" }, "goal": { "calorie_target_kcal", "protein_g", "carbs_g", "fat_g", "source" }, "remaining_kcal": number, "render": { "markdown", "svg" } }`

`goal` and `remaining_kcal` are omitted only when there is neither a profile nor
a complete manual goal. A complete manual goal can be used without a profile.
The v0.1 server interprets `date` as a UTC calendar day.

### `get_weight_trend`

**Input** `{ "days": { "type": "integer", "default": 30 } }`
**Output** `{ "series": [ { "date", "kg" } ], "latest": { "date", "kg" }? }`

The series is scoped to the authenticated user and sorted by measurement date.
`latest` is the final series point when one exists. Imported measurements are
deduplicated by their HealthKit measurement timestamp.

### `get_energy_burned`

**Input** `{ "days": { "type": "integer", "default": 30 } }` — **Output** `{ "series": [ { "date": "YYYY-MM-DD", "active_kcal": number } ] }`.

Reads daily active-energy calories imported from Apple Health. Values are user-scoped and idempotent by `(user_id, burned_at)`.

### `get_dashboard_summary`

**Input** `{ "days": { "type": "integer", "default": 7 } }`
**Output** `{ "avg_calories_kcal", "streak_days", "macro_split": { "protein_g", "carbs_g", "fat_g" }, "weight_trend": [ { "date", "kg" } ], "render": { "markdown", "svg" } }`

`avg_calories_kcal` is averaged across the requested calendar range;
`macro_split` is the summed gram total for that range, and `streak_days` counts
consecutive UTC days ending today that contain at least one meal within the
requested `days` window, so it is at most `days`. `weight_trend` is a supported
v0.1 output: include it when non-empty and treat an empty array as no weight
entries in the requested range. No registered v0.1 tool writes `weight_logs`,
so it may be empty.

Both read outputs include a `render` payload with markdown and SVG strings. The
MCP server emits it as two content blocks: `{ type: "text", text:
render.markdown }` followed by `{ type: "image", data: base64(render.svg),
mimeType: "image/svg+xml" }`. Existing structured fields remain unchanged; the
markdown is the safe fallback when a client cannot render SVG.

### `get_profile`

**Input** `{}` — **Output** `{ "sex", "age_years", "height_cm", "weight_kg", "activity_level", "diet_goal", "goal_weight_kg?" }`

### `set_profile`

**Input** `{ "sex", "age_years", "height_cm", "weight_kg", "activity_level", "diet_goal", "goal_weight_kg?" }`
**Output** `{ "ok": true, "saved": true, "effective_goal": { "calorie_target_kcal", "protein_g", "carbs_g", "fat_g", "source": "computed", "superseded_manual?" } }`

Saving a profile is the newest user decision, so the output reports the
effective goal with the just-computed targets (`source: "computed"`, using the
latest imported weight when one exists). When a complete manual goal existed
before the save, its old values are returned as
`superseded_manual: { "calorie_target_kcal", "protein_g", "carbs_g", "fat_g", "updated_at" }`
so the agent can tell the user what the new profile replaced.

### `compute_targets`

**Input** `{}` (uses the profile and latest imported weight when present)
**Output** `{ "bmr_kcal", "tdee_kcal", "calorie_target_kcal", "protein_g", "carbs_g", "fat_g", "weight_used" }`

`weight_used` reports the body weight the targets were actually derived from:
`{ "kg", "source": "health" | "profile" }`. When a `weight_logs` measurement
exists, the latest one (by `measured_at`) feeds the computation and `source`
is `"health"` with that sample's `measured_at`; with no imported measurement
the profile's typed `weight_kg` is used and `source` is `"profile"` (no
`measured_at`). Formula (Mifflin-St Jeor → activity factor → diet goal) in
[`TARGETS.md`](TARGETS.md).

### `get_goals`

**Purpose:** the **effective** target the gauge and "did I hit today's target?" use.
**Output** `{ "calorie_target_kcal", "protein_g", "carbs_g", "fat_g", "source": "computed" | "manual", "superseded_manual?" }`

The effective goal follows **"latest update wins"**: the stored manual goal is
effective only while it is at least as new as the profile
(`goals.updated_at >= profiles.updated_at`). A profile updated after the manual
goal makes the **computed** target effective (`source: "computed"`) and the
response carries the replaced values as `superseded_manual` (with the manual
row's `updated_at`) so clients can show what was set aside. `get_day`'s `goal`
and the dashboard render follow the same rule (without the `superseded_manual`
payload). A complete manual goal is still readable when no profile has been
set (nothing can supersede it there). A profile is required when the stored
goal is computed, incomplete, or absent.

### `set_goals`

**Input** `{ "calorie_target_kcal?", "protein_g?", "carbs_g?", "fat_g?" }` — **Output** `{ "ok": true, "source": "manual" }`

Omitted values retain the current effective values (following the same
"latest update wins" rule). If no profile or existing goal can supply them,
provide all four values. Calling `set_goals` writes the manual override
(`source='manual'`) as the newest goal write, so it stays effective until the
profile changes again or `reset_goals` is called.

### `reset_goals`

**Input** `{}` — **Output** `{ "ok": true, "reset": true }`

Discards the stored manual goal override (the goal row is rewritten to
`source='computed'` with no values). The effective target returns to the
computed values derived from the profile and latest imported weight — call
`get_goals` afterwards for the new effective target (a profile is required for
a computed target). Nothing else changes; `reset_goals` never touches meals,
weight logs, or the profile.

## Principles for the agent

- **Don't invent precise macros you can't get.** Use `search_food` to pull exact
  values when you have a name, scale them to the full eaten portion, and set a
  lower `confidence` for honest estimates.
- **One uploaded photo = one `log_meal`** with one or more `items[]`.
- **Never log twice.** If a same-sitting item was omitted, v0.1 has no
  add-item operation: with confirmation, call `delete_meal_log` once, then call
  `get_day` for the original UTC date and re-log the full item list only after
  its original `meal_log_id` is absent. If the meal remains or state is
  unknown, stop without retrying or creating a replacement. Log a genuinely
  separate meal separately.
- **Honesty beats polish.** If a portion is a guess, keep `confidence` low and
  add a `notes` string. The human corrects it later in the dashboard.

## v0.1 image limitation

The contract calls the field `image_url`, while the existing database column is
`meal_logs.image_path`. The v0.1 server stores the HTTPS URL string in that
column as a reference. It does not fetch or upload the image and does not claim
that the URL is durable. The private `food-images` bucket and its owner-scoped
Storage policies are provisioned by `db/migrations/0004_store_assets.sql`; a
future upload flow can write object paths of `{user_id}/{meal_log_id}.jpg`.

## Remote authentication

The MCP endpoint accepts either a raw Supabase bearer token or an OAuth 2.0
access token issued by the provider. The canonical client-facing transport
URL is the deployed Fly origin, `https://morsel-mcp.fly.dev/mcp` (issues
#72/#73/#75). OAuth clients discover the provider through
`/.well-known/oauth-protected-resource` (the path-specific
`/.well-known/oauth-protected-resource/mcp` is also served),
`/.well-known/oauth-authorization-server`, and
`/.well-known/openid-configuration` (OpenID Connect discovery), all under the
canonical base. The OIDC route serves the same authorization-server document —
same `issuer`, endpoints, CORS, and cache behavior — and adds no OIDC claims
the provider cannot back. Because the issuer is a path (`/mcp` on the Fly
origin), spec-compliant MCP clients append the OIDC path to the issuer, and
the canonical discovery URL that succeeds is the issuer-relative
`https://morsel-mcp.fly.dev/mcp/.well-known/openid-configuration`.
The advertised OAuth `resource` is the canonical transport URL itself.

> **Legacy Edge compatibility (issues #57/#72/#75):** before the Fly
> deployment, the Supabase Edge Function served the client-facing transport
> at the function root, `https://<public-host>/functions/v1/mcp` (issue #57);
> the nested `…/functions/v1/mcp/mcp` path remained only as a compatibility
> alias for clients provisioned before the route change and was never
> published to users. Because that issuer is a path, spec-compliant clients
> tried three discovery URLs: the two host-root prefixes
> (`/.well-known/oauth-authorization-server/functions/v1/mcp` and
> `/.well-known/openid-configuration/functions/v1/mcp`) were intercepted by
> the Supabase gateway before reaching the function, so the URL that
> succeeded was the issuer-relative
> `https://<public-host>/functions/v1/mcp/.well-known/openid-configuration`.
> The Edge Function transport is retained as legacy/local-gateway
> compatibility and is no longer the canonical client-facing base. The OAuth
> discovery, registration, and consent behavior described below is identical
> on the Fly origin.

The provider supports dynamic RFC 7591 registration, the authorization-code
grant, and refresh tokens. The `/authorize` route on the Fly origin is the
OAuth backend and consent runs as a two-step email one-time-code sign-in:
**sign in with the email on the Morsel account; a code is emailed to you.**
Step 1 requests a Supabase Auth email OTP for an existing account only (no
account creation) and answers uniformly for known and unknown emails; step 2
verifies the 6-digit code before the authorization code is issued. The
BROWSER consent surface is the static Vercel page under `authorize-ui/`
(issue #69; the page exists because Supabase's free shared domain rewrites
Edge Function `text/html` to `text/plain`, so the function origin could not
render consent HTML — and it remains the consent surface after the move to
Fly, issue #72). `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` is set on the deployed
Fly app: authorization-server metadata advertises the Vercel page as
`authorization_endpoint` and every `/authorize` form response is a bodyless
302 back to it; the page's same-origin `params.js` copies the allowlisted
OAuth query fields into hidden inputs and each stage form POSTs directly
(cross-origin — no CORS, no proxy) to the Fly origin's `/mcp/authorize`
(issue #74). Changing that production secret is human-gated (the deploy
workflow only verifies it); unset, the route renders the two no-JS email/code
forms server-side as self-POSTs as the pinned fallback (issue #66 hardening).
`/token` requires PKCE with
`code_challenge_method=S256` and rejects `plain`. Access tokens are the real
Supabase Auth session access tokens, validated with `auth.getUser()` before
issuance, so existing RLS policies continue to scope every tool call to the
signed-in user. Client registration remains stateless, but `/authorize` stores
a short-lived user-owned grant in the RLS-protected `oauth_authorization_grants`
table. The client-facing code is an encrypted/signed envelope containing no
Supabase token. `/token` atomically claims the grant through
`claim_oauth_authorization_grant` before minting a Supabase access token, so
replay fails even when claims race across concurrent isolates or processes.
Refresh-token wrappers remain encrypted/signed; no long-lived server-side
OAuth sessions are used.

#### Token lifetimes, rotation, and refresh (issue #120)

Access tokens are the real Supabase session access tokens and last about
**1 hour** (`expires_in`). The client-facing refresh token is a sealed wrapper
valid for **30 days**; every successful refresh rotates the Supabase session
and re-seals a new wrapper around the rotated refresh token, so each wrapper
is single-use upstream. One logical connection therefore keeps exactly **one
session per client**: reuse the newest refresh token from the latest token
response and never share it across clients.

The server tolerates the client-side races this rotation creates:

- **Duplicate refresh inside the reuse window (10 s by default):** retries and
  concurrent duplicates of the same refresh token are answered with the
  current session (single-flight per token hash on the one Fly VM), never a
  400 on the already-rotated token.
- **After the window:** a wrapper whose Supabase token was truly rotated away
  or revoked returns `invalid_grant` with a precise `error_description`
  carrying the upstream Supabase Auth message. The Supabase Auth project
  "refresh token reuse interval" should be set ≥ 10 s so a stale duplicate
  that outlives the in-memory window still maps to the current session
  (dashboard setting).
- **Client re-registration:** `/register` again with identical
  `redirect_uris`/`client_name` re-binds older refresh wrappers to the new
  client id (accepted and logged with client fingerprints); a registration
  whose metadata changed does not, and the client must sign in again.
- **`resource`:** may be omitted on refresh (RFC 8707) even when the
  authorization carried it; the refreshed token stays bound to the original
  resource. Two explicit, different resource URLs remain a mismatch.

Every token-endpoint failure logs one structured JSON line (grant type, OAuth
error and description, client fingerprint, resource presence); successes log
the same fingerprint at debug level. Log payloads never contain raw client ids
or token values.

### ChatGPT per-tool OAuth metadata and re-auth challenge (issue #96)

Every protected tool additionally declares the OpenAI/ChatGPT per-tool OAuth
metadata ChatGPT requires for tool discovery: each tool's `_meta` carries
`securitySchemes: [{ "type": "oauth2", "scopes": ["mcp"] }]` — the same single
OAuth contract described above (`scopes_supported: ["mcp"]` in both the
authorization-server and protected-resource documents); there is no second
issuer or credential system. The field rides in tool `_meta` because the
installed MCP SDK emits tool-level `_meta` in `tools/list` while dropping
unknown top-level config keys.

When transport authentication fails on an ESTABLISHED session, a `tools/call`
is answered with a structured JSON-RPC result (`isError: true`) whose
`_meta["mcp/www_authenticate"]` carries the same bearer/resource challenge the
HTTP 401 advertises, so ChatGPT surfaces its account-linking UI:

```
Bearer resource_metadata="https://morsel-mcp.fly.dev/mcp/.well-known/oauth-protected-resource/mcp", error="invalid_token", error_description="Authentication required: reconnect the Morsel account to continue."
```

Discovery/first-contact requests (no session id) keep the plain HTTP 401 +
WWW-Authenticate challenge. The challenge text is fixed and backend-free: no
Supabase, Postgres, stack, token, email, or other raw backend detail is ever
echoed to the model or user.

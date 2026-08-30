# MCP tool contract

This is the **single source of truth** for the tools an agent can call against
Morsel. The server implements these; the agent skill (`skills/food-logging/SKILL.md`)
dog-ears them. When you change a tool here, change the schema, the server, and the
skill together.

Canonical types: [`packages/schema/food-types.ts`](../packages/schema/food-types.ts).

## Tool list

| Tool | Direction | Purpose |
|---|---|---|
| `log_meal` | write | **The main one.** Record a meal (and its items). Photo path uses this. |
| `search_food` | read | Find a food in the catalog by name/barcode (so the agent can use real macros instead of guessing). |
| `update_meal_item` | write | Correct one item (wrong macro, wrong portion). |
| `delete_meal_log` | write | Remove a whole meal. |
| `get_day` | read | One day's meals + totals + remaining vs goal. |
| `get_dashboard_summary` | read | Range totals, streak, macro split, weight trend. |
| `get_profile` | read | Body metrics (sex, age, height, weight, activity, diet goal). |
| `set_profile` | write | Upsert body metrics. |
| `compute_targets` | read | BMR/TDEE + kcal + macro split derived from profile. |
| `get_goals` | read | **Effective** targets (computed default, else manual override) + `source`. |
| `set_goals` | write | Manual override (marks `source='manual'`). |
| `get_weight_trend` | read | Apple Health body-mass series and latest measurement. |

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

**Input** `{ "sex", "age_years", "height_cm", "weight_kg", "activity_level", "diet_goal", "goal_weight_kg?" }` — **Output** `{ "ok": true, "saved": true }`

### `compute_targets`

**Input** `{}` (uses the profile and latest imported weight when present) — **Output** `{ "bmr_kcal", "tdee_kcal", "calorie_target_kcal", "protein_g", "carbs_g", "fat_g" }`
Formula (Mifflin-St Jeor → activity factor → diet goal) in [`TARGETS.md`](TARGETS.md).

### `get_goals`

**Purpose:** the **effective** target the gauge and "did I hit today's target?" use —
the computed default unless the user set a manual override.
**Output** `{ "calorie_target_kcal", "protein_g", "carbs_g", "fat_g", "source": "computed" | "manual" }`

A complete manual goal is readable even when no profile has been set. A profile
is required when the stored goal is computed or incomplete.

### `set_goals`

**Input** `{ "calorie_target_kcal?", "protein_g?", "carbs_g?", "fat_g?" }` — **Output** `{ "ok": true, "source": "manual" }`

Omitted values retain the current effective values. If no profile or existing
goal can supply them, provide all four values. Calling `set_goals` permanently
sets `source='manual'` in v0.1; there is no registered tool to revert it to a
computed target.

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
access token issued by the provider in the same Edge Function. OAuth clients
discover the provider through `/.well-known/oauth-protected-resource` (the
path-specific `/.well-known/oauth-protected-resource/mcp` is also served) and
`/.well-known/oauth-authorization-server`.

The provider supports dynamic RFC 7591 registration, the authorization-code
grant, and refresh tokens. `/authorize` presents a Supabase Auth email/password
sign-in page; `/token` requires PKCE with `code_challenge_method=S256` and rejects
`plain`. Access tokens are the real Supabase Auth session access tokens, validated
with `auth.getUser()` before issuance, so existing RLS policies continue to scope
every tool call to the signed-in user. Client registration remains stateless,
but `/authorize` stores a short-lived user-owned grant in the RLS-protected
`oauth_authorization_grants` table. The client-facing code is an
encrypted/signed envelope containing no Supabase token. `/token` atomically
claims the grant through `claim_oauth_authorization_grant` before minting a
Supabase access token, so replay fails across concurrent Edge Function
isolates. Refresh-token wrappers remain encrypted/signed; no long-lived
server-side OAuth sessions are used.

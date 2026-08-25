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
| `log_water` / `log_weight` | write | v1.1 extras; not registered by the v0.1 server. |

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
          "food_ref_id": { "type": "string", "format": "uuid", "description": "Link to a food_catalog row for exact macros" },
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

The v0.1 store reads this catalog from `food_catalog`, with a small deterministic
curated set in `db/seed.sql`. A broader external OpenNutrition reference is
planned for v0.3.

### `update_meal_item`

**Input** `{ "item_id": "uuid", "calories_kcal?": "number", "protein_g?": "number", "carbs_g?": "number", "fat_g?": "number", "quantity?": "number", "name?": "string" }`
**Output** `{ "ok": true, "updated": true }`

At least one optional field must be supplied with `item_id`.

### `delete_meal_log`

**Input** `{ "meal_log_id": "uuid" }`
**Output** `{ "ok": true, "deleted": true }`

### `get_day`

**Input** `{ "date": "YYYY-MM-DD" }`
**Output** `{ "date", "meals": [ { meal_log_id, meal_type, eaten_at, items: [ { item_id, name, quantity, unit, ... } ] } ], "totals": { "calories_kcal", "protein_g", "carbs_g", "fat_g" }, "goal": { "calorie_target_kcal", "protein_g", "carbs_g", "fat_g", "source" }, "remaining_kcal": number }`

`goal` and `remaining_kcal` are omitted only when there is neither a profile nor
a complete manual goal. A complete manual goal can be used without a profile.
The v0.1 server interprets `date` as a UTC calendar day.

### `get_dashboard_summary`

**Input** `{ "days": { "type": "integer", "default": 7 } }`
**Output** `{ "avg_calories_kcal", "streak_days", "macro_split": { "protein_g", "carbs_g", "fat_g" }, "weight_trend": [ { "date", "kg" } ] }`

`avg_calories_kcal` is averaged across the requested calendar range;
`macro_split` is the summed gram total for that range, and `streak_days` counts
consecutive days ending today that contain at least one meal.

### `get_profile`

**Input** `{}` — **Output** `{ "sex", "age_years", "height_cm", "weight_kg", "activity_level", "diet_goal", "goal_weight_kg?" }`

### `set_profile`

**Input** `{ "sex", "age_years", "height_cm", "weight_kg", "activity_level", "diet_goal", "goal_weight_kg?" }` — **Output** `{ "ok": true, "saved": true }`

### `compute_targets`

**Input** `{}` (uses the profile) — **Output** `{ "bmr_kcal", "tdee_kcal", "calorie_target_kcal", "protein_g", "carbs_g", "fat_g" }`
Formula (Mifflin-St Jeor → activity factor → diet goal) in [`TARGETS.md`](TARGETS.md).

### `get_goals`

**Purpose:** the **effective** target the gauge and "did I hit today's target?" use —
the computed default unless the user set a manual override.
**Output** `{ "calorie_target_kcal", "protein_g", "carbs_g", "fat_g", "source": "computed" | "manual" }`

A complete manual goal is readable even when no profile has been set. A profile
is required when the stored goal is computed or incomplete.

### `set_goals`

**Input** `{ "calorie_target_kcal?", "protein_g?", "carbs_g?", "fat_g?" }` — **Output** `{ "ok": true, "source": "manual" }`

Omitted values retain the current effective values. Without a profile, provide
all four values to create a complete manual goal; a profile is required for
computed or fallback values.

## Principles for the agent

- **Don't invent precise macros you can't get.** Use `search_food` to pull exact
  values when you have a name; otherwise estimate and set a lower `confidence`.
- **One uploaded photo = one `log_meal`** with one or more `items[]`.
- **Never log twice.** If you're re-reading a day, use `get_day` and only
  `log_meal` net-new items.
- **Honesty beats polish.** If a portion is a guess, keep `confidence` low and
  add a `notes` string. The human corrects it later in the dashboard.

## v0.1 image limitation

The contract calls the field `image_url`, while the existing database column is
`meal_logs.image_path`. The v0.1 server stores the HTTPS URL string in that
column as a reference. It does not fetch or upload the image and does not claim
that the URL is durable. The private `food-images` bucket and its owner-scoped
Storage policies are provisioned by `db/migrations/0003_store_assets.sql`; a
future upload flow can write object paths of `{user_id}/{meal_log_id}.jpg`.

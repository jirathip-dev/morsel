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
| `get_goals` / `set_goals` | read/write | Current diet targets. |
| `log_water` / `log_weight` | write | v1.1 extras. |

## Tool schemas

### `log_meal`

**Purpose:** record a meal. When the user uploads a food photo, the agent does
vision → fills `items[]` → calls this. `source` is set internally by the server
from what the agent passed (allow `photo_vision`).

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
          "food_ref_id": { "type": "string", "description": "Link to food_catalog/OpenNutrition id for exact macros" },
          "confidence":  { "type": "number", "minimum": 0, "maximum": 1, "description": "0..1 how sure the agent is. Low = user should review." },
          "notes":       { "type": "string", "description": "Agent reasoning, e.g. 'approx, shared plate'" }
        }
      }
    },
    "notes":     { "type": "string" },
    "image_url": { "type": "string", "description": "Public URL of the uploaded food photo, if any" }
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

### `update_meal_item`

**Input** `{ "item_id": "uuid", "calories_kcal?": "number", "protein_g?": "number", "carbs_g?": "number", "fat_g?": "number", "quantity?": "number", "name?": "string" }`
**Output** `{ "ok": true, "updated": true }`

### `delete_meal_log`

**Input** `{ "meal_log_id": "uuid" }`
**Output** `{ "ok": true, "deleted": true }`

### `get_day`

**Input** `{ "date": "YYYY-MM-DD" }`
**Output** `{ "date", "meals": [ { meal_log_id, meal_type, eaten_at, items: [ ... ] } ], "totals": { "calories_kcal", "protein_g", "carbs_g", "fat_g" }, "goal": { "calorie_target_kcal", ... }, "remaining_kcal": number }`

### `get_dashboard_summary`

**Input** `{ "days": { "type": "integer", "default": 7 } }`
**Output** `{ "avg_calories_kcal", "streak_days", "macro_split": { "protein_g", "carbs_g", "fat_g" }, "weight_trend": [ { "date", "kg" } ] }`

## Principles for the agent

- **Don't invent precise macros you can't get.** Use `search_food` to pull exact
  values when you have a name; otherwise estimate and set a lower `confidence`.
- **One uploaded photo = one `log_meal`** with one or more `items[]`.
- **Never log twice.** If you're re-reading a day, use `get_day` and only
  `log_meal` net-new items.
- **Honesty beats polish.** If a portion is a guess, keep `confidence` low and
  add a `notes` string. The human corrects it later in the dashboard.

---
name: food-logging
description: Log a meal to Morsel from a photo or text via MCP tools.
version: 0.2.0
author: Guy (jirathip-k), Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [morsel, mcp, food, logging, nutrition]
    related_skills: []
---

# Food logging (Morsel)

Use Morsel's MCP tools to record food, read the dashboard data, and correct
entries. The current assistant analyzes an uploaded image; Morsel stores the
structured result. There is no in-app chat or in-app AI.

The Morsel MCP server must be connected and the user authenticated before
calling tools; writes are scoped to that account.

## Scope and invariants

Use this skill for meal logging, food-history readback, profile and goal setup,
nutrition recommendations based on the user's data, and corrections. Do not use
it for clinical or medical diet advice.

Always follow these rules:

- Do not invent precise macros. Call `search_food` for exact catalog values when
  possible; otherwise make an honest estimate, use a lower `confidence`, and
  explain the uncertainty in the item's `notes`.
- One uploaded photo is one `log_meal` call containing one or more `items[]`.
- Never log twice. To reread or correct existing data, use `get_day`,
  `update_meal_item`, or `delete_meal_log`.
- `source` is assigned by the server; never send it. A photo URL makes the
  server use `photo_vision`, a barcode without a photo makes it use `barcode`,
  and otherwise it uses `manual`.
- `eaten_at` means when the meal happened, not when the photo was uploaded. If
  it is unknown, omit it and let the server use now.
- Morsel v0.1 stores a caller-supplied HTTPS `image_url` as a reference; it does
  not upload or fetch image bytes. Never fabricate a URL.

The v0.1 server registers exactly these tools: `log_meal`, `search_food`,
`update_meal_item`, `delete_meal_log`, `get_day`, `get_dashboard_summary`,
`get_profile`, `set_profile`, `compute_targets`, `get_goals`, and `set_goals`.
`log_water` and `log_weight` are v1.1 ideas and are not callable.

## Exact tool contract

UUID means a UUID string. Numbers described as non-negative or positive must
also be finite. Unknown fields are rejected by the strict input schemas.

### `log_meal`

Required input fields are `meal_type` and `items` (at least one item).

```text
log_meal({
  eaten_at?: ISO date-time with an offset,
  meal_type: "breakfast" | "lunch" | "dinner" | "snack",
  items: [{
    name: string,                         // required, non-empty
    quantity?: positive number,            // default 1
    unit?: "g" | "ml" | "serving" | "piece" | "cup", // default "serving"
    calories_kcal?: non-negative number,
    protein_g?: non-negative number,
    carbs_g?: non-negative number,
    fat_g?: non-negative number,
    fiber_g?: non-negative number,
    sugar_g?: non-negative number,
    barcode?: non-empty string,
    food_ref_id?: non-empty string,
    confidence?: number from 0 through 1,
    notes?: non-empty string
  }],
  notes?: non-empty string,
  image_url?: HTTPS URL
})
```

The output is `{ meal_log_id: UUID, recorded: true }`. Send catalog IDs from
`search_food` as `food_ref_id` when using a catalog match. Keep each visible
food as its own item in the single meal.

### `search_food`

Input: `{ query: non-empty string, limit?: positive integer <= 100 }`. The
default limit is `8`.

Output:

```text
{
  results: [{
    id: string,                             // required
    name: string,                           // required
    brand?: string,
    barcode?: string,
    serving_size?: string,
    serving_unit?: string,
    calories_kcal?: finite number,
    protein_g?: finite number,
    carbs_g?: finite number,
    fat_g?: finite number
  }]
}
```

An empty `results` array means the catalog did not find a match. Do not turn a
missing result into made-up exact values.

### `update_meal_item`

Input requires `item_id: UUID` and at least one of these optional fields:
`name` (non-empty string), `quantity` (positive number), `calories_kcal`,
`protein_g`, `carbs_g`, or `fat_g` (each a non-negative number). `unit`, fiber,
sugar, confidence, and notes are not update fields in v0.1.

Output: `{ ok: true, updated: true }`.

### `delete_meal_log`

Input: `{ meal_log_id: UUID }`.

Output: `{ ok: true, deleted: true }`.

### `get_day`

Input: `{ date: valid YYYY-MM-DD }`. The server interprets the date as a UTC
calendar day.

Output:

```text
{
  date: valid YYYY-MM-DD,
  meals: [{
    meal_log_id: UUID,
    meal_type: "breakfast" | "lunch" | "dinner" | "snack",
    eaten_at: ISO date-time with an offset,
    items: [{
      item_id: UUID,
      name: string,
      quantity: finite number,
      unit: "g" | "ml" | "serving" | "piece" | "cup",
      calories_kcal?: finite number,
      protein_g?: finite number,
      carbs_g?: finite number,
      fat_g?: finite number,
      fiber_g?: finite number,
      sugar_g?: finite number,
      barcode?: string,
      food_ref_id?: string,
      confidence?: finite number,
      notes?: string
    }]
  }],
  totals: { calories_kcal: finite number, protein_g: finite number, carbs_g: finite number, fat_g: finite number },
  goal?: { calorie_target_kcal: finite number, protein_g: finite number, carbs_g: finite number, fat_g: finite number,
           source: "computed" | "manual" },
  remaining_kcal?: finite number
}
```

`goal` and `remaining_kcal` are omitted until a profile exists. A negative
`remaining_kcal` means the calorie target has been exceeded.

### `get_dashboard_summary`

Input: `{ days?: positive integer <= 366 }`; default `days` is `7`.

Output:

```text
{
  avg_calories_kcal: finite number,
  streak_days: non-negative integer,
  macro_split: { protein_g: finite number, carbs_g: finite number, fat_g: finite number },
  weight_trend: [{ date: valid YYYY-MM-DD, kg: finite number }]
}
```

`avg_calories_kcal` is averaged across the requested calendar range;
`macro_split` is the summed gram total for that range; `streak_days` counts
consecutive days ending today that contain at least one meal.

### Profile and target tools

`get_profile` and `compute_targets` take `{}`. `get_profile` returns:

```text
{
  sex: "male" | "female",
  age_years: integer 10..100,
  height_cm: positive number 100..250,
  weight_kg: positive number 30..300,
  activity_level: "sedentary" | "light" | "moderate" | "active" | "very_active",
  diet_goal: "lose" | "maintain" | "gain",
  goal_weight_kg?: positive number
}
```

`set_profile` takes that same object as input and requires every field except
`goal_weight_kg`. It returns `{ ok: true, saved: true }`.

`compute_targets` returns:

```text
{
  bmr_kcal: non-negative number,
  tdee_kcal: non-negative number,
  calorie_target_kcal: non-negative number,
  protein_g: non-negative number,
  carbs_g: non-negative number,
  fat_g: non-negative number
}
```

`get_goals` takes `{}` and returns the effective target with the same four
target fields plus `source: "computed" | "manual"`. Use this for the target
that the dashboard gauge and "did I hit today's target?" should display.

`set_goals` takes an object where every field is optional:
`calorie_target_kcal?`, `protein_g?`, `carbs_g?`, and `fat_g?` (all
non-negative numbers). Omitted values retain the current effective values. If
there is no profile or existing goal to fill them, provide all four values. It
returns `{ ok: true, source: "manual" }`.

## End-to-end photo workflow

1. Inspect the photo. Identify each food and an honest portion estimate; do not
   collapse a mixed plate into a falsely precise single food.
2. For each clearly named food, call `search_food` (use a barcode when one is
   available). Prefer returned catalog macros and `id` over guessing. For an
   unmatched or uncertain item, estimate only what is defensible, set a lower
   `confidence` between 0 and 1, and add an explanatory `notes` value such as
   `approx portion` or `shared plate`.
3. Make exactly one `log_meal` call with the required `meal_type` and one or
   more `items[]`. Include the user's meal time when known and the user's
   supplied HTTPS photo URL when available. Never send `source`.
4. Confirm success only when the response contains `recorded: true`; retain
   the returned `meal_log_id` and tell the user what was recorded, including
   low-confidence items.
5. Read back the stored result with `get_day` for the meal's UTC date. Use the
   returned totals, goal, remaining calories, and item rows—not a re-analysis of
   the photo—as the confirmation. For a range/dashboard view, also call
   `get_dashboard_summary` (for example `{ days: 7 }`).

For text-only logging, follow the same item/search/estimate rules without
`image_url`. If the user asks to add a component after the meal is already
logged, read the day first and edit the existing item or meal rather than
creating a duplicate log.

## Common read and correction flows

- "Did I hit today's target?": call `get_goals` and `get_day` for today; report
  consumed versus the effective target, remaining or overage, and the macro
  totals. If there is no profile, offer `set_profile` rather than guessing a
  target.
- "Am I on track this week?": call `get_dashboard_summary({ days: 7 })` and
  summarize average calories, streak, macro grams, and weight trend.
- "What should I eat?": call `get_day` plus `get_goals`, then use
  `search_food` for concrete options that fit the remaining values. Never
  present unknown macros as exact or as medical advice.
- Wrong item: call `update_meal_item` with its `item_id` and at least one
  supported correction field. Wrong whole meal: call `delete_meal_log` with its
  `meal_log_id` only when deletion is what the user requested.

If a tool errors, report the exact error and the input shape attempted. Do not
retry blindly in a loop.

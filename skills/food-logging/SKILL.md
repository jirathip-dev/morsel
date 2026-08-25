---
name: food-logging
description: Log meals and answer food-log, dashboard, target, or correction questions in Morsel from a photo or text via MCP tools.
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

Use it when the user sends a food photo or meal description, asks what they ate
or how a day/week is tracking, asks whether they hit a target or what to eat to
fit it, or asks to fix an entry.

Always follow these rules:

- Do not invent precise macros. Call `search_food` for exact catalog values when
  possible; otherwise make an honest estimate, use a lower `confidence`, and
  explain the uncertainty in the item's `notes`.
- Macro fields sent to `log_meal` are totals for the whole item as eaten, not
  per unit. `quantity` and `unit` are descriptive; the server never multiplies
  macros by them. `search_food` values are per its `serving_size` and
  `serving_unit`, so scale them yourself before logging (for example, 250 g at
  130 kcal per 100 g becomes `quantity: 250`, `unit: "g"`,
  `calories_kcal: 325`).
- One uploaded photo is one `log_meal` call containing one or more `items[]`.
- Never log twice. To reread or correct existing data, use `get_day`,
  `update_meal_item`, or `delete_meal_log`. v0.1 has no tool that adds a new
  item to an existing meal: if a forgotten food was part of the same sitting,
  confirm before deleting that meal and re-logging its complete item list once;
  if it was a separate meal, log it separately. Never create a second log for
  the same sitting.
- Choose the unit honestly: `g` for weighed food, `ml` for measured liquid,
  `serving` for a plate or portion, `piece` for countable food, and `cup` for a
  cup measure. `unit` cannot be changed by `update_meal_item`, so get it right
  on the first call.
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
    food_ref_id?: UUID returned by `search_food`,
    confidence?: number from 0 through 1,
    notes?: non-empty string
  }],
  notes?: non-empty string,
  image_url?: HTTPS URL
})
```

The output is `{ meal_log_id: UUID, recorded: true }`. `food_ref_id` must be a
UUID `id` returned by `search_food`; the v0.1 database column is a UUID. Keep
each visible food as its own item in the single meal.

Macro fields are the total for the item as eaten. The server does not scale them
from `quantity`, so scale catalog values from their `serving_size` and
`serving_unit` before sending the call.

### `search_food`

Input: `{ query: non-empty string, limit?: positive integer <= 100 }`. The
default limit is `8`.

Output:

```text
{
  results: [{
    id: string,                             // required; v0.1 catalog IDs are UUIDs
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
      food_ref_id?: UUID,
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
consecutive UTC days ending on the server's UTC today that contain at least one
meal. In v0.1, `weight_trend` is always empty because no registered tool writes
weight logs; omit it from user summaries unless a future contract adds one.

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

If no profile exists, `get_profile` returns `not_found`, while
`compute_targets` and `get_goals` return `profile_required`. `get_day` is the
graceful read: it omits `goal` and `remaining_kcal` instead.

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
returns `{ ok: true, source: "manual" }`. Calling `set_goals` permanently
switches the effective target to `source: "manual"` in v0.1; there is no tool
to revert it to computed, and later `set_profile` calls will not move that
manual target. Confirm before calling it, and prefer `set_profile` plus
`compute_targets` when the user wants targets to track body metrics.

## End-to-end photo workflow

1. Inspect the photo. Identify each food and an honest portion estimate; do not
   collapse a mixed plate into a falsely precise single food.
2. For each clearly named food, call `search_food` (use a barcode when one is
   available). Prefer returned catalog macros and `id` over guessing, but scale
   those per-serving values to the full portion before sending them. For an
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
logged, read the day first. v0.1 cannot add an item to an existing meal: with
the user's confirmation, delete that meal and re-log the complete item list
once, or log a genuinely separate meal as its own log. Do not create a second
log for the same sitting.

## Common read and correction flows

- "Did I hit today's target?": call `get_day` first for today's UTC calendar
  date; use its `goal` and `remaining_kcal` when present, and report consumed
  versus the effective target, remaining or overage, and macro totals. If the
  goal is omitted, there is no profile; offer `set_profile` rather than calling
  a target tool without the required profile. "Today" means UTC here; if a
  user's late-evening or early-morning local day looks empty, check the
  adjacent UTC date too.
- "Am I on track this week?": call `get_dashboard_summary({ days: 7 })` and
  summarize average calories, streak, and macro grams; include `weight_trend`
  only if it is non-empty.
- "What should I eat?": call `get_day` and use `get_goals` only when a profile
  exists, then use `search_food` for concrete options that fit the remaining
  values. Never present unknown macros as exact or as medical advice.
- Wrong item: call `update_meal_item` with its `item_id` and at least one
  supported correction field. Wrong whole meal: call `delete_meal_log` with its
  `meal_log_id` only when deletion is what the user requested.

If a tool errors, report the exact error and the input shape attempted. If
`log_meal` fails or times out without a clear rejection, call `get_day` for the
meal's UTC date before retrying because the write may have committed; only
re-log if the meal is absent. For a clear validation error, correct the input
once rather than retrying blindly in a loop.

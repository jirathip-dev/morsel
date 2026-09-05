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
  `calories_kcal: 325`). If either serving field is absent, the serving basis is
  unknown: seek clarification or, if proceeding, use an explicitly noted
  lower-confidence estimate; never treat the returned macros as one serving.
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
- For “how am I doing” or target questions, compare the day's eaten calories
  with the effective goal from `get_day` (or `get_goals` when a standalone
  target is needed) and report the signed difference (eaten minus goal) as
  under, on target, or over. The effective goal is TDEE-based and
  activity-inclusive — activity is already factored in — so progress is eaten
  vs goal. `get_energy_burned` may be read for context and shown as a separate
  activity note; it is never subtracted from the goal.
- `eaten_at` means when the meal happened, not when the photo was uploaded. If
  it is unknown, omit it and let the server use now.
- Morsel v0.1 stores a caller-supplied HTTPS `image_url` as a reference; it does
  not upload or fetch image bytes. Never fabricate a URL.

The server registers exactly these tools: `log_meal`, `search_food`,
`update_meal_item`, `delete_meal_log`, `get_day`, `get_dashboard_summary`,
`get_profile`, `set_profile`, `compute_targets`, `get_goals`, `set_goals`,
`reset_goals`, `get_weight_trend`, and `get_energy_burned`. It reads Apple
Health imports for weight and active-energy context.

### Tool safety classes

The MCP server advertises client-visible safety annotations for every tool
(`readOnlyHint`, `destructiveHint`; see `docs/MCP_TOOLS.md`). They describe
server behavior only — they do not replace authentication or the user's
approval. Treat every call as account-scoped, and treat these classes as the
authoritative guidance:

- Read-only (never write): `get_day`, `get_profile`, `compute_targets`,
  `get_goals`, `get_weight_trend`, `get_energy_burned`,
  `get_dashboard_summary`. Safe to call without confirmation.
- Writes (create or overwrite the user's data): `log_meal`, `set_profile`,
  `set_goals`, `reset_goals`, `update_meal_item`. Confirm with the user when
  the effect is not already requested; `log_meal` is never retried blindly —
  every call inserts a new meal. `reset_goals` discards the stored manual goal
  values the user set earlier, so confirm it too.
- Destructive (irreversible delete): `delete_meal_log` only. Deleting removes
  the meal log and its items permanently — never call it without explicit
  user confirmation.
- `search_food` is not advertised as read-only and is the only **open-world**
  tool: it reads the catalog, but on a miss the configured path calls the live
  USDA web-search API and may persist matched rows into the server's shared
  food catalog, so results can reflect current external data. It never writes
  the user's data and needs no confirmation, but do not describe it to the
  user as a pure no-write read. All other tools operate only on the account's
  stored data (closed-world).

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
`serving_unit` before sending the call. If either field is absent, the serving
basis is unknown: seek clarification or use an explicitly noted lower-confidence
estimate, never treating the returned macros as one serving.

### `search_food`

Input: `{ query: non-empty string, limit?: positive integer <= 100 }`. The
default limit is `8`.

Output:

```text
{
  results: [{
    id: UUID,                               // required in v0.1
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
  remaining_kcal?: finite number,
  render: { markdown: string, svg: string }
}
```

`goal` and `remaining_kcal` are omitted only when there is neither a profile nor
a complete manual goal. A complete manual goal works without a profile. A
negative `remaining_kcal` means the calorie target has been exceeded.

### `get_weight_trend`

Input: `{ days?: positive integer <= 366 }`; default is `30`.
Output: `{ series: [{ date: YYYY-MM-DD, kg: finite number }], latest?: point }`.
Measurements are user-scoped and `latest` is the final point in the sorted series.

### `get_energy_burned`

Input: `{ days?: positive integer <= 366 }`; default is `30`.
Output: `{ series: [{ date: YYYY-MM-DD, active_kcal: finite number }] }`.
For “how am I doing?” or target questions, treat this series as context only:
active energy is a separate activity note and is never subtracted from the
goal. Compare `get_day` totals with the effective goal (TDEE-based,
activity-inclusive) and report the signed difference (eaten minus goal) as
under, on target, or over.

### `get_dashboard_summary`

Input: `{ days?: positive integer <= 366 }`; default `days` is `7`.

Output:

```text
{
  avg_calories_kcal: finite number,
  streak_days: non-negative integer,
  macro_split: { protein_g: finite number, carbs_g: finite number, fat_g: finite number },
  weight_trend: [{ date: valid YYYY-MM-DD, kg: finite number }],
  render: { markdown: string, svg: string }
}
```

`avg_calories_kcal` is averaged across the requested calendar range;
`macro_split` is the summed gram total for that range; `streak_days` counts
consecutive UTC days ending on the server's UTC today that contain at least one
meal, within the requested `days` window (so it is at most `days`). In v0.1,
`weight_trend` is a supported output: include it in user summaries when it is
non-empty and omit it when empty. No registered v0.1 tool writes weight logs,
so the field may be empty.

`get_day` and `get_dashboard_summary` also return a Tier-1 `render` payload.
The server exposes its `markdown` as the first content block and its SVG as a
base64 `image` content block with `mimeType: "image/svg+xml"`. The markdown is
the safe fallback for clients without SVG image support. If any item in the
range has confidence below `0.8`, both render surfaces include a
`needs-review` marker; an empty range explicitly says that no meals were
logged.

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
`goal_weight_kg`. It returns:

```text
{
  ok: true,
  saved: true,
  effective_goal: {
    calorie_target_kcal: non-negative number,
    protein_g: non-negative number,
    carbs_g: non-negative number,
    fat_g: non-negative number,
    source: "computed",
    superseded_manual?: {
      calorie_target_kcal: non-negative number,
      protein_g: non-negative number,
      carbs_g: non-negative number,
      fat_g: non-negative number,
      updated_at: ISO date-time with an offset
    }
  }
}
```

Saving a profile is the newest user decision: report the targets it produced
(the `effective_goal`) instead of only the stored profile. When the save
replaces a complete manual goal the user set earlier, `effective_goal`
includes `superseded_manual` with those old values and their `updated_at`;
tell the user the profile changed their targets and name what the manual
numbers were.

If no profile exists, `get_profile` errors with `not_found` and
`compute_targets` errors with `profile_required`. `get_goals` returns a complete
manual goal without a profile; otherwise it errors with `profile_required` when
no profile exists. `get_day` omits `goal` and `remaining_kcal` only when there
is neither a profile nor a complete manual goal.

`compute_targets` returns:

```text
{
  bmr_kcal: non-negative number,
  tdee_kcal: non-negative number,
  calorie_target_kcal: non-negative number,
  protein_g: non-negative number,
  carbs_g: non-negative number,
  fat_g: non-negative number,
  weight_used: {
    kg: positive number,
    measured_at?: ISO date-time with an offset,
    source: "health" | "profile"
  }
}
```

`weight_used` is the body weight the targets were computed from: the latest
imported Health measurement (`source: "health"`, with the sample's
`measured_at`) when one exists, otherwise the profile's typed `weight_kg`
(`source: "profile"`, no `measured_at`). When the user's Health weight is
newer than the typed value, quote the Health weight as the basis.

`get_goals` takes `{}` and returns the effective target with the same four
target fields plus `source: "computed" | "manual"`. Use this when a standalone
target is needed. The effective goal follows "latest update wins": the stored
manual goal applies only while it is at least as new as the profile
(`goals.updated_at >= profiles.updated_at`). When the profile was updated
after the manual goal, the response is the **computed** target with
`source: "computed"` and carries the replaced manual values as
`superseded_manual: { calorie_target_kcal, protein_g, carbs_g, fat_g,
updated_at }` — tell the user their newer profile changed the targets and
name the old manual numbers. `get_day` includes the same effective goal
whenever a profile or complete manual goal exists (without the superseded
payload). This is the target that the dashboard gauge and "did I hit today's
target?" should display.

`set_goals` takes an object where every field is optional:
`calorie_target_kcal?`, `protein_g?`, `carbs_g?`, and `fat_g?` (all
non-negative numbers). Omitted values retain the current effective values. If
there is no profile or existing goal to fill them, provide all four values. It
returns `{ ok: true, source: "manual" }`. Calling `set_goals` writes the
manual override as the newest goal write, so it stays effective until the
profile changes again or `reset_goals` is called. Confirm before calling it,
and prefer `set_profile` plus `compute_targets` when the user wants targets to
track body metrics.

`reset_goals` takes `{}` and returns `{ ok: true, reset: true }`. Call it when
the user wants their stored manual goal numbers discarded and targets back to
the computed values from the profile (for example after `get_goals` shows a
`superseded_manual` that should stay superseded, or when the user says "stop
using my manual numbers"). Confirm first; the stored manual values are gone.
Follow with `get_goals` and report the computed target.

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
the user's confirmation, preserve the original `eaten_at`, `image_url`, and
meal-level `notes`, then call `delete_meal_log` once. Call `get_day` for the
original meal's UTC date and check that its `meal_log_id` is absent; re-log the
complete item list only when that absence is established. If the meal remains,
or the delete/read result leaves state unknown, stop without retrying the
delete or creating a replacement and report the state. `get_day` does not
return the image reference or meal notes, so before deleting: warn separately
if the original meal notes are unavailable and will be lost; if the original
`image_url` is unavailable, warn that the photo link will be lost and the new
log's source will be `barcode` if any preserved item has a barcode, otherwise
`manual`. If the food was a genuinely separate meal, log it as its own log. Do
not create a second log for the same sitting.

## Common read and correction flows

- "Did I hit today's target?": call `get_day` first for today's UTC calendar
  date; use its `goal` and `remaining_kcal` when present, and report the
  signed difference (eaten minus goal) as under, on target, or over, with the
  remaining or overage and macro totals. If the
  goal is omitted, there is neither a profile nor a complete manual goal; offer
  `set_profile` or provide all four values to `set_goals`. A complete manual goal
  can also be read with `get_goals` without a profile. "Today" means UTC here;
  if a user's late-evening or early-morning local day looks empty, check the
  adjacent UTC date too.
- "Am I on track this week?": call `get_dashboard_summary({ days: 7 })` and
  summarize average calories, streak, and macro grams; include `weight_trend`
  only if it is non-empty. Pass through the returned markdown/image render when
  the client supports it; do not replace its honest empty or needs-review state.
- "What should I eat?": call `get_day` and use `get_goals` when a standalone
  target is needed; it works without a profile when a complete manual goal
  exists. Then use `search_food` for concrete options that fit the remaining
  values. Never present unknown macros as exact or as medical advice.
- Wrong item: call `update_meal_item` with its `item_id` and at least one
  supported correction field. Wrong whole meal: call `delete_meal_log` with its
  `meal_log_id` only when deletion is what the user requested.

If a tool errors, report the exact error and the input shape attempted. If
`log_meal` fails or times out without a clear rejection, call `get_day` for the
meal's UTC date before retrying because the write may have committed; only
re-log if the meal is absent. For a clear validation error, correct the input
once rather than retrying blindly in a loop.

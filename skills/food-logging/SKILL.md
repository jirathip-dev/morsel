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

When the user wants to record what they ate, use the Morsel MCP server to read
and write a structured nutrition log. Morsel has **no chat UI** — the whole
point is that the logging happens here, in this assistant, and the data lands in
a store the Morsel iOS dashboard reads. Because you have vision, the normal flow
is: user uploads a photo → you identify the food and portion → you call the tool.

## When to use
- The user sends a food photo and says "log this" / "track my lunch" / "what does this cost" (calories).
- The user asks **what they ate** or **how their day/week is tracking** (reads).
- The user asks **"did I hit today's target?"** / **"what should I eat to fit my macros?"** (read + recommend).
- The user asks to fix a wrong entry.

Don't use for: clinical/medical diet advice, medical meal prescriptions, or
anything not about recording, reading, or recommending within Morsel's log.

## Prerequisites
- The Morsel MCP server is connected and you can call its tools
  (`log_meal`, `search_food`, `get_day`, `get_goals`, `set_goals`, `update_meal_item`, `delete_meal_log`).
- User is authenticated (OAuth) so writes are scoped to their account.

## Procedure

**1. Photo → log (the common case).**
1. Look at the image and identify each component and an approximate portion.
2. For any item with a clear name, call `search_food` first to get exact macros;
   otherwise estimate.
3. Call `log_meal` with one `items[]` array. One photo = one call.
4. Set `confidence` per item: high if you are sure of both the food and portion,
   low for guesses. Add a `notes` string when you guessed.
5. Say what you logged in one line and flag any low-confidence item.

**2. Text → log.** Same, except no photo: build `items[]` from the description.

**3. Read a day.** Call `get_day` with the date and summarize totals + remaining
against the goal.

**4. Correct an entry.** `update_meal_item` (one item) or `delete_meal_log` (whole meal).
Never create a new log to "fix" an old one — that double-counts.

## Answering the user's questions

**Did I hit today's target?**
1. `get_goals` → **effective** targets (computed from the profile, or a manual override);
   `get_day` (today) → consumed totals.
   - If no profile is set yet, offer to add one (`set_profile`) so the target is computed, not guessed.
2. Reply with: consumed vs target, remaining (or over), plus protein/carbs/fat
   split if asked. Keep it to a few lines.
3. If nothing is logged today, say so plainly, then offer to log a meal.

**Am I on track this week?**
- `get_dashboard_summary({ days: 7 })` → avg calories, streak, macro split, weight trend.
- Round numbers; only flag what's clearly off target. Don't overwhelm with stats.

**What should I eat?**
1. `get_day` (today) + `get_goals` → remaining macros.
2. `search_food` for a few **real** foods that fit (name + macros). Prefer concrete items.
3. Suggest 2–3 options that fit the remaining macros; note the rough calorie/protein fit.
- This is **practical** guidance from the user's own data — not medical prescription.
  Never diagnose, prescribe, or make medical claims.
- Don't fabricate macros you don't have. If `search_food` can't find it, say so and
  give an honest estimate with a note.

**What did I eat on <date>?**
- `get_day` (that date) → meals + items + totals vs goal for that day.

## Pitfalls
- **Never re-log the same meal.** If you already logged today's lunch and the
  user says "and the noodles too", call `get_day` and edit, don't create a second log.
- **Don't invent precise macros.** If you can't be sure, estimate, set a low
  `confidence`, and say so. The user reviews low-confidence items in the dashboard.
- **Keep units honest.** `g` for weighed food, `serving` for a plate, `piece` for countable.
- **One meal, one log; many items.** A bowl of rice + chicken + veg is ONE
  `log_meal` with THREE `items[]`.

## Verification
- `log_meal` returns a `meal_log_id` and `recorded: true` → succeed.
- If a tool errors, report the exact error and the shape you tried, don't retry
  blindly in a loop.

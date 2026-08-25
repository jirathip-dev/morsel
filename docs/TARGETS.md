# Targets — computed from body metrics, then reviewed

The calorie/macro goal is **not** a blank manual number. Morsel derives it from a
short health profile the user fills in once — then lets them **review + adjust**
before locking it. This replaces the prototype's manual `2,100 kcal` entry with a
computed default, while keeping the designer's review/edit affordance.

## The profile (one per user)
| Field | Type / options |
|---|---|
| `sex` | `male` \| `female` |
| `age_years` | int |
| `height_cm` | numeric |
| `weight_kg` | numeric |
| `activity_level` | `sedentary` \| `light` \| `moderate` \| `active` \| `very_active` |
| `diet_goal` | `lose` \| `maintain` \| `gain` |
| `goal_weight_kg` | optional target weight |

## The calculation (standard estimate, not medical advice)
1. **BMR** — Mifflin-St Jeor:
   - male: `10·kg + 6.25·cm − 5·age + 5`
   - female: `10·kg + 6.25·cm − 5·age − 161`
2. **TDEE** = BMR × activity factor: `sedentary 1.2 · light 1.375 · moderate 1.55 · active 1.725 · very_active 1.9`
3. **Target kcal** by diet goal: `maintain = TDEE`, `lose = max(1200, TDEE−500)`, `gain = TDEE+300`
4. **Macro split** (default): protein 30%, carbs 45%, fat 25% of target kcal.

Defaults live in `db/migrations/0002_targets.sql` (`public.compute_targets()`).

## Review-and-adjust flow (the designer's "review")
1. User lands on **Targets** screen → sees the computed value with the profile it came from.
2. `Keep` (confirm) → `goals.source = 'computed'`, stored.
3. `Adjust` → editable kcal + macro fields (the prototype's manual inputs) → `goals.source = 'manual'`.
4. A later body-metric change (e.g. new weight) can trigger a **recompute prompt**, never a silent change.

## MCP surface
| Tool | Purpose |
|---|---|
| `get_profile` | read the body metrics |
| `set_profile` | upsert body metrics |
| `compute_targets` | computed BMR/TDEE/kcal + macros (via `public.compute_targets()`) |
| `get_goals` | **effective** targets (computed default, or manual override) + `source` |
| `set_goals` | manual override (sets `source='manual'`) |

## Why this matters
The "did I hit today's target?" query and the gauge both read the *effective*
goal. A computed default means the number is tailored, not a guess the user must
look up — and the review step keeps them in control (and honest about the model's
limits). Accuracy of the *goal* is a baseline concern; the vision/macro accuracy
of the *log* is still the real hard problem.

-- Morsel: deterministic v0.1 reference data for search_food.
--
-- This is intentionally separate from migrations so a deployment can re-run
-- the seed without rewriting schema history. Stable IDs make the operation
-- idempotent and keep meal_items.food_ref_id values meaningful.
--
-- Values are practical curated defaults for common foods, not a comprehensive
-- nutrition database. The external OpenNutrition reference is a v0.3 plan.

insert into public.food_catalog (
  id,
  name,
  brand,
  barcode,
  serving_size,
  serving_unit,
  calories_kcal,
  protein_g,
  carbs_g,
  fat_g,
  fiber_g,
  sugar_g,
  source
)
values
  (
    'f0000000-0000-4000-8000-000000000001',
    'Jasmine rice, cooked',
    null,
    null,
    '100',
    'g',
    130,
    2.7,
    28.2,
    0.3,
    0.4,
    0.1,
    'curated'
  ),
  (
    'f0000000-0000-4000-8000-000000000002',
    'Chicken breast, roasted, skinless',
    null,
    null,
    '100',
    'g',
    165,
    31,
    0,
    3.6,
    0,
    0,
    'curated'
  ),
  (
    'f0000000-0000-4000-8000-000000000003',
    'Egg, large',
    null,
    null,
    '1',
    'piece',
    72,
    6.3,
    0.4,
    4.8,
    0,
    0.2,
    'curated'
  ),
  (
    'f0000000-0000-4000-8000-000000000004',
    'Banana, medium',
    null,
    null,
    '1',
    'piece',
    105,
    1.3,
    27,
    0.4,
    3.1,
    14.4,
    'curated'
  ),
  (
    'f0000000-0000-4000-8000-000000000005',
    'Broccoli, cooked',
    null,
    null,
    '100',
    'g',
    35,
    2.4,
    7.2,
    0.4,
    3.3,
    1.4,
    'curated'
  ),
  (
    'f0000000-0000-4000-8000-000000000006',
    'Salmon, Atlantic, cooked',
    null,
    null,
    '100',
    'g',
    206,
    22.1,
    0,
    12.4,
    0,
    0,
    'curated'
  ),
  (
    'f0000000-0000-4000-8000-000000000007',
    'Oats, dry',
    null,
    null,
    '40',
    'g',
    152,
    5.1,
    27.1,
    2.8,
    4.1,
    0.4,
    'curated'
  ),
  (
    'f0000000-0000-4000-8000-000000000008',
    'Tofu, firm',
    null,
    null,
    '100',
    'g',
    144,
    17.3,
    2.8,
    8.7,
    2.3,
    0.6,
    'curated'
  )
on conflict (id) do update set
  name = excluded.name,
  brand = excluded.brand,
  barcode = excluded.barcode,
  serving_size = excluded.serving_size,
  serving_unit = excluded.serving_unit,
  calories_kcal = excluded.calories_kcal,
  protein_g = excluded.protein_g,
  carbs_g = excluded.carbs_g,
  fat_g = excluded.fat_g,
  fiber_g = excluded.fiber_g,
  sugar_g = excluded.sugar_g,
  source = excluded.source;

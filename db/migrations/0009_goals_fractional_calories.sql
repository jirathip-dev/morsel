-- Goals accept one decimal place so the app's numeric input survives persistence.
alter table public.goals
  alter column calorie_target_kcal type numeric(10,1)
  using calorie_target_kcal::numeric(10,1);

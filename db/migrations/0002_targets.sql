-- Morsel: computed calorie/macro targets from body metrics (v.2).
-- The goal is no longer a blank manual number — it's derived from a profile
-- (Mifflin-St Jeor BMR x activity factor x diet goal). The user can still
-- override manually; that flips goals.source to 'manual'.

create table if not exists public.profiles (
  user_id uuid primary key references public.users(id) on delete cascade,
  sex text not null check (sex in ('male','female')),
  age_years int not null check (age_years between 10 and 100),
  height_cm numeric not null check (height_cm between 100 and 250),
  weight_kg numeric not null check (weight_kg between 30 and 300),
  activity_level text not null default 'moderate'
    check (activity_level in ('sedentary','light','moderate','active','very_active')),
  diet_goal text not null default 'maintain'
    check (diet_goal in ('lose','maintain','gain')),
  goal_weight_kg numeric,          -- optional target weight
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "profiles_select_own" on public.profiles for select using ((select auth.uid()) = user_id);
create policy "profiles_insert_own" on public.profiles for insert with check ((select auth.uid()) = user_id);
create policy "profiles_update_own" on public.profiles for update using ((select auth.uid()) = user_id);

-- goals now carry where the target came from.
alter table public.goals add column if not exists source text not null default 'computed'
  check (source in ('computed','manual'));

-- Computed targets: BMR -> TDEE -> kcal by diet goal -> macro split.
-- Standard estimate, not medical advice; numbers are defaults the user can review.
create or replace function public.compute_targets(p public.profiles)
returns table (
  bmr_kcal numeric, tdee_kcal numeric, calorie_target_kcal numeric,
  protein_g numeric, carbs_g numeric, fat_g numeric
) language plpgsql immutable as $$
declare
  bmr numeric; tdee numeric; kcal numeric; af numeric;
begin
  select case
    when p.sex = 'male'   then 10*p.weight_kg + 6.25*p.height_cm - 5*p.age_years + 5
    else                       10*p.weight_kg + 6.25*p.height_cm - 5*p.age_years - 161
  end into bmr;
  af := case p.activity_level
    when 'sedentary' then 1.2 when 'light' then 1.375
    when 'moderate'  then 1.55 when 'active' then 1.725
    else 1.9 end;
  tdee := round(bmr * af);
  kcal := case p.diet_goal
    when 'lose' then greatest(1200, tdee - 500)
    when 'gain' then tdee + 300
    else tdee end;
  -- default macro split: 30% protein / 45% carbs / 25% fat (kcal-derived)
  return query select round(bmr), round(tdee), round(kcal),
    round(kcal*0.30/4), round(kcal*0.45/4), round(kcal*0.25/9);
end $$;

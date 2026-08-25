-- Morsel: initial schema. User-scoped everywhere; RLS on every table.
-- Run in Supabase SQL Editor or via supabase db push.

-- Enums as CHECK constraints (simpler to migrate than Postgres ENUM types).

create table if not exists public.users (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  display_name text,
  timezone text not null default 'Asia/Bangkok',
  created_at timestamptz not null default now()
);

-- One goal row per user (current targets).
create table if not exists public.goals (
  user_id uuid primary key references public.users(id) on delete cascade,
  calorie_target_kcal int,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  updated_at timestamptz not null default now()
);

-- One "meal session". One uploaded photo == one meal_log.
create table if not exists public.meal_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  eaten_at timestamptz not null default now(),
  meal_type text not null check (meal_type in ('breakfast','lunch','dinner','snack')),
  source text not null default 'manual'
    check (source in ('manual','photo_vision','barcode','import','voice')),
  image_path text,       -- food-images/{user_id}/{id}.jpg
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists meal_logs_user_eaten_idx
  on public.meal_logs (user_id, eaten_at desc);

-- Individual foods within a meal. Vision usually produces several items.
create table if not exists public.meal_items (
  id uuid primary key default gen_random_uuid(),
  meal_log_id uuid not null references public.meal_logs(id) on delete cascade,
  name text not null,
  quantity numeric not null default 1,
  unit text not null default 'serving'
    check (unit in ('g','ml','serving','piece','cup')),
  calories_kcal numeric,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  fiber_g numeric,
  sugar_g numeric,
  barcode text,
  food_ref_id uuid,      -- optional link to food_catalog / OpenNutrition id
  confidence numeric,    -- 0..1: how sure the detecting agent is
  source_notes text,     -- the agent's reasoning, e.g. "approx, shared plate"
  created_at timestamptz not null default now()
);
create index if not exists meal_items_log_idx on public.meal_items (meal_log_id);

create table if not exists public.water_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  logged_at timestamptz not null default now(),
  ml numeric not null
);
create index if not exists water_logs_user_idx on public.water_logs (user_id, logged_at desc);

create table if not exists public.weight_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  logged_at timestamptz not null default now(),
  kg numeric not null
);
create index if not exists weight_logs_user_idx on public.weight_logs (user_id, logged_at desc);

-- Optional curated food reference (or point search at an external OpenNutrition MCP).
create table if not exists public.food_catalog (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  brand text,
  barcode text unique,
  serving_size text,
  serving_unit text,
  calories_kcal numeric,
  protein_g numeric,
  carbs_g numeric,
  fat_g numeric,
  fiber_g numeric,
  sugar_g numeric,
  source text not null default 'curated',
  created_at timestamptz not null default now()
);

-- ===== Row-level security: every user-scoped table guarded by auth.uid() =====
alter table public.goals enable row level security;
alter table public.meal_logs enable row level security;
alter table public.meal_items enable row level security;
alter table public.water_logs enable row level security;
alter table public.weight_logs enable row level security;

create policy "goals_select_own" on public.goals for select using ((select auth.uid()) = user_id);
create policy "goals_insert_own" on public.goals for insert with check ((select auth.uid()) = user_id);
create policy "goals_update_own" on public.goals for update using ((select auth.uid()) = user_id);

create policy "meal_logs_select_own" on public.meal_logs for select using ((select auth.uid()) = user_id);
create policy "meal_logs_insert_own" on public.meal_logs for insert with check ((select auth.uid()) = user_id);
create policy "meal_logs_update_own" on public.meal_logs for update using ((select auth.uid()) = user_id);
create policy "meal_logs_delete_own" on public.meal_logs for delete using ((select auth.uid()) = user_id);

-- meal_items has no user_id column; join through the parent meal_logs.
create policy "meal_items_select_own" on public.meal_items for select
  using ((select auth.uid()) = (select user_id from public.meal_logs where id = meal_log_id));
create policy "meal_items_insert_own" on public.meal_items for insert
  with check ((select auth.uid()) = (select user_id from public.meal_logs where id = meal_log_id));
create policy "meal_items_update_own" on public.meal_items for update
  using ((select auth.uid()) = (select user_id from public.meal_logs where id = meal_log_id));
create policy "meal_items_delete_own" on public.meal_items for delete
  using ((select auth.uid()) = (select user_id from public.meal_logs where id = meal_log_id));

create policy "water_logs_all_own" on public.water_logs
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "weight_logs_all_own" on public.weight_logs
  for all using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

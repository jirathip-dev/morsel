-- Morsel: daily active-energy imports from Apple Health.
create table public.energy_burned_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  burned_at timestamptz not null,
  active_kcal numeric not null,
  source text not null default 'manual',
  constraint energy_burned_logs_kcal_nonnegative check (active_kcal >= 0),
  constraint energy_burned_logs_source_check check (source in ('manual', 'apple_health')),
  constraint energy_burned_logs_user_burned_unique unique (user_id, burned_at)
);
alter table public.energy_burned_logs enable row level security;
create policy energy_burned_logs_all_own on public.energy_burned_logs
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create index energy_burned_logs_user_burned_idx
  on public.energy_burned_logs (user_id, burned_at desc);

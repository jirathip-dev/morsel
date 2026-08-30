-- Morsel: Apple Health body-mass imports.
-- The timestamp is the HealthKit measurement time, so syncs are idempotent.

alter table public.weight_logs rename column logged_at to measured_at;
alter table public.weight_logs
  add constraint weight_logs_user_measured_unique unique (user_id, measured_at);

alter table public.weight_logs
  add constraint weight_logs_kg_positive check (kg > 0);

drop index if exists public.weight_logs_user_idx;
create index if not exists weight_logs_user_measured_idx
  on public.weight_logs (user_id, measured_at desc);

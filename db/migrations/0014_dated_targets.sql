-- Issue #253. Forward-only observation history: deliberately NO backfill.
-- Existing writers/signatures continue working; only the database can attest
-- baseline provenance. Read tools remain read-only.
create schema if not exists morsel_private;
revoke all on schema morsel_private from public;
grant usage on schema morsel_private to authenticated;

create table public.target_baseline_revisions (
  revision_id uuid primary key default gen_random_uuid(),
  revision_order bigint generated always as identity,
  user_id uuid not null references public.users(id) on delete cascade,
  recorded_at timestamptz not null default clock_timestamp(),
  effective_date date not null,
  timezone text not null,
  source_version text not null default 'targets-v1' check (source_version = 'targets-v1'),
  goal jsonb,
  source_inputs jsonb not null,
  profile_updated_at timestamptz,
  goals_updated_at timestamptz,
  weight_measured_at timestamptz
);
create index target_baseline_read on public.target_baseline_revisions(user_id, recorded_at desc, revision_order desc);
alter table public.target_baseline_revisions enable row level security;
create policy target_baseline_select_own on public.target_baseline_revisions
  for select to authenticated using ((select auth.uid()) = user_id);
revoke all on public.target_baseline_revisions from public, anon, authenticated;
grant select on public.target_baseline_revisions to authenticated;

create table public.target_addition_revisions (
  revision_id uuid primary key,
  revision_order bigint generated always as identity,
  user_id uuid not null references public.users(id) on delete cascade,
  date date not null,
  timezone text not null,
  addition_kcal numeric not null check (addition_kcal >= 0 and addition_kcal < 'Infinity'::numeric),
  recorded_at timestamptz not null default clock_timestamp(),
  previous_revision_id uuid references public.target_addition_revisions(revision_id),
  historical_confirmation boolean not null,
  manual_goal_acknowledged boolean not null
);
create index target_addition_read on public.target_addition_revisions(user_id, date, revision_order desc);
alter table public.target_addition_revisions enable row level security;
create policy target_addition_select_own on public.target_addition_revisions
  for select to authenticated using ((select auth.uid()) = user_id);
revoke all on public.target_addition_revisions from public, anon, authenticated;
grant select on public.target_addition_revisions to authenticated;

-- BEFORE all baseline-affecting writes: serialize the account and stamp
-- profile/goal versions on the server (also fixes old-client timestamp omission).
create function morsel_private.lock_target_account() returns trigger
language plpgsql security definer set search_path = '' as $function$
begin
  if TG_OP = 'UPDATE' and NEW.user_id is distinct from OLD.user_id then
    raise exception 'target account cannot change' using errcode = '42501';
  end if;
  perform 1 from public.users where id = coalesce(NEW.user_id, OLD.user_id) for update;
  if TG_TABLE_NAME in ('profiles', 'goals') and TG_OP <> 'DELETE' then
    NEW.updated_at := clock_timestamp();
  end if;
  if TG_OP = 'DELETE' then return OLD; end if;
  return NEW;
end;
$function$;
revoke all on function morsel_private.lock_target_account() from public;

create function morsel_private.capture_target_baseline(p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $function$
declare
  v_profile public.profiles;
  v_goals public.goals;
  v_weight public.weight_logs;
  v_inputs jsonb;
  v_previous jsonb;
  v_goal jsonb;
  v_zone text;
  v_now timestamptz;
begin
  perform 1 from public.users where id = p_user_id for update;
  if not found then return; end if; -- account deletion cascades, not a new observation
  select * into v_profile from public.profiles where user_id = p_user_id;
  select * into v_goals from public.goals where user_id = p_user_id;
  select * into v_weight from public.weight_logs where user_id = p_user_id order by measured_at desc limit 1;
  v_zone := coalesce(v_profile.timezone, 'UTC');
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = v_zone) then
    raise exception 'invalid target timezone' using errcode = '22023';
  end if;
  v_inputs := jsonb_build_object('profile', to_jsonb(v_profile), 'goals', to_jsonb(v_goals), 'weight', to_jsonb(v_weight));
  select source_inputs into v_previous from public.target_baseline_revisions
    where user_id = p_user_id order by revision_order desc limit 1;
  if v_inputs is not distinct from v_previous then return; end if;
  if v_goals.source = 'manual' and v_goals.calorie_target_kcal is not null
    and v_goals.protein_g is not null and v_goals.carbs_g is not null and v_goals.fat_g is not null
    and (v_profile.user_id is null or v_goals.updated_at >= v_profile.updated_at) then
    v_goal := jsonb_build_object('calorie_target_kcal', v_goals.calorie_target_kcal,
      'protein_g', v_goals.protein_g, 'carbs_g', v_goals.carbs_g, 'fat_g', v_goals.fat_g, 'source', 'manual');
  elsif v_profile.user_id is not null then
    v_profile.weight_kg := coalesce(v_weight.kg, v_profile.weight_kg);
    select jsonb_build_object('calorie_target_kcal', t.calorie_target_kcal,
      'protein_g', t.protein_g, 'carbs_g', t.carbs_g, 'fat_g', t.fat_g, 'source', 'computed')
      into v_goal from public.compute_targets(v_profile) t;
  end if;
  v_now := clock_timestamp();
  insert into public.target_baseline_revisions(user_id, recorded_at, effective_date, timezone, goal,
    source_inputs, profile_updated_at, goals_updated_at, weight_measured_at)
    values(p_user_id, v_now, (v_now at time zone v_zone)::date, v_zone, v_goal, v_inputs,
      v_profile.updated_at, v_goals.updated_at, v_weight.measured_at);
end;
$function$;
revoke all on function morsel_private.capture_target_baseline(uuid) from public;

create function morsel_private.observe_target_write() returns trigger
language plpgsql security definer set search_path = '' as $function$
begin
  perform morsel_private.capture_target_baseline(coalesce(NEW.user_id, OLD.user_id));
  return null;
end;
$function$;
revoke all on function morsel_private.observe_target_write() from public;

create trigger target_profile_lock before insert or update or delete on public.profiles
  for each row execute function morsel_private.lock_target_account();
create trigger target_goals_lock before insert or update or delete on public.goals
  for each row execute function morsel_private.lock_target_account();
create trigger target_weight_lock before insert or update or delete on public.weight_logs
  for each row execute function morsel_private.lock_target_account();
create trigger target_profile_observe after insert or update or delete on public.profiles
  for each row execute function morsel_private.observe_target_write();
create trigger target_goals_observe after insert or update or delete on public.goals
  for each row execute function morsel_private.observe_target_write();
create trigger target_weight_observe after insert or update or delete on public.weight_logs
  for each row execute function morsel_private.observe_target_write();
create trigger target_meal_observe after insert on public.meal_logs
  for each row execute function morsel_private.observe_target_write();

create function public.get_dated_targets(p_user_id uuid, p_start_date date, p_end_date date, p_timezone text)
returns setof jsonb language plpgsql stable security invoker set search_path = '' as $function$
begin
  if auth.uid() is null or auth.uid() is distinct from p_user_id then
    raise exception 'target user does not match authenticated user' using errcode = '42501';
  end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date
    or p_end_date - p_start_date > 365 or p_timezone is null
    or not exists (select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then
    raise exception 'invalid target date range or timezone' using errcode = '22023';
  end if;
  return query
    select jsonb_build_object('date', d.day, 'timezone', p_timezone,
      'confirmed_addition_kcal', coalesce(a.addition_kcal, 0))
      || case when b.goal is null then '{}'::jsonb else jsonb_build_object(
        'baseline', jsonb_strip_nulls(jsonb_build_object('revision_id', b.revision_id,
          'recorded_at', b.recorded_at, 'effective_date', b.effective_date, 'timezone', b.timezone,
          'source_version', b.source_version, 'goal', b.goal,
          'profile_updated_at', b.profile_updated_at, 'goals_updated_at', b.goals_updated_at,
          'weight_measured_at', b.weight_measured_at)),
        'total_target_kcal', (b.goal->>'calorie_target_kcal')::numeric + coalesce(a.addition_kcal, 0)) end
      || case when a.revision_id is null then '{}'::jsonb else jsonb_build_object(
        'addition_revision', jsonb_strip_nulls(jsonb_build_object('revision_id', a.revision_id,
          'recorded_at', a.recorded_at, 'timezone', a.timezone, 'previous_revision_id', a.previous_revision_id,
          'historical_confirmation', a.historical_confirmation, 'manual_goal_acknowledged', a.manual_goal_acknowledged))) end
    from (select p_start_date + n as day from generate_series(0, p_end_date - p_start_date) n) d
    left join lateral (
      select * from public.target_baseline_revisions r
      where r.user_id = p_user_id
        and r.recorded_at < ((d.day + 1)::timestamp at time zone p_timezone)
        and d.day <= (now() at time zone p_timezone)::date
      order by r.recorded_at desc, r.revision_order desc limit 1
    ) b on true
    left join lateral (
      select * from public.target_addition_revisions r where r.user_id = p_user_id and r.date = d.day
      order by r.revision_order desc limit 1
    ) a on true
    order by d.day;
end;
$function$;
revoke all on function public.get_dated_targets(uuid, date, date, text) from public;
grant execute on function public.get_dated_targets(uuid, date, date, text) to authenticated;

-- The private writer is privileged ONLY to append attested history. Its public
-- invoker wrapper exposes no arbitrary user/goal/provenance write capability.
create function morsel_private.set_dated_target_addition(p_user_id uuid, p_date date, p_timezone text,
  p_addition_kcal numeric, p_mutation_id uuid, p_expected_revision uuid,
  p_historical_confirmation boolean, p_manual_goal_acknowledged boolean)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_previous uuid;
  v_retry public.target_addition_revisions;
  v_day jsonb;
  v_today date;
begin
  if auth.uid() is null or auth.uid() is distinct from p_user_id then
    raise exception 'target user does not match authenticated user' using errcode = '42501';
  end if;
  if p_date is null or p_timezone is null or p_mutation_id is null or p_addition_kcal is null
    or p_addition_kcal < 0 or p_addition_kcal >= 'Infinity'::numeric
    or p_historical_confirmation is null or p_manual_goal_acknowledged is null
    or not exists (select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then
    raise exception 'invalid target addition' using errcode = '22023';
  end if;
  perform 1 from public.users where id = p_user_id for update;
  if not found then raise exception 'target account missing' using errcode = '42501'; end if;
  select * into v_retry from public.target_addition_revisions where revision_id = p_mutation_id;
  if found then
    if v_retry.user_id is distinct from p_user_id or v_retry.date is distinct from p_date
      or v_retry.timezone is distinct from p_timezone or v_retry.addition_kcal is distinct from p_addition_kcal
      or v_retry.previous_revision_id is distinct from p_expected_revision
      or v_retry.historical_confirmation is distinct from p_historical_confirmation
      or v_retry.manual_goal_acknowledged is distinct from p_manual_goal_acknowledged then
      raise exception 'mutation identity already used' using errcode = '22023';
    end if;
    select * into v_day from public.get_dated_targets(p_user_id, p_date, p_date, p_timezone);
    return v_day;
  end if;
  v_today := (clock_timestamp() at time zone p_timezone)::date;
  if p_date > v_today or (p_date < v_today and not p_historical_confirmation) then
    raise exception 'past date requires explicit historical confirmation; future dates are not supported' using errcode = '22023';
  end if;
  select revision_id into v_previous from public.target_addition_revisions
    where user_id = p_user_id and date = p_date order by revision_order desc limit 1;
  if v_previous is distinct from p_expected_revision then
    raise exception 'addition revision changed; read and confirm again' using errcode = '40001';
  end if;
  if p_date = v_today then perform morsel_private.capture_target_baseline(p_user_id); end if;
  select * into v_day from public.get_dated_targets(p_user_id, p_date, p_date, p_timezone);
  if p_addition_kcal > 0 and v_day #>> '{baseline,goal,source}' = 'manual' and not p_manual_goal_acknowledged then
    raise exception 'manual goal requires explicit acknowledgement' using errcode = '22023';
  end if;
  insert into public.target_addition_revisions(revision_id, user_id, date, timezone, addition_kcal,
    previous_revision_id, historical_confirmation, manual_goal_acknowledged, recorded_at)
    values(p_mutation_id, p_user_id, p_date, p_timezone, p_addition_kcal,
      v_previous, p_historical_confirmation, p_manual_goal_acknowledged, clock_timestamp());
  select * into v_day from public.get_dated_targets(p_user_id, p_date, p_date, p_timezone);
  return v_day;
end;
$function$;
revoke all on function morsel_private.set_dated_target_addition(uuid, date, text, numeric, uuid, uuid, boolean, boolean) from public;
grant execute on function morsel_private.set_dated_target_addition(uuid, date, text, numeric, uuid, uuid, boolean, boolean) to authenticated;

create function public.set_dated_target_addition(p_user_id uuid, p_date date, p_timezone text,
  p_addition_kcal numeric, p_mutation_id uuid, p_expected_revision uuid default null,
  p_historical_confirmation boolean default false, p_manual_goal_acknowledged boolean default false)
returns jsonb language sql security invoker set search_path = '' as $function$
  select morsel_private.set_dated_target_addition(p_user_id, p_date, p_timezone,
    p_addition_kcal, p_mutation_id, p_expected_revision, p_historical_confirmation, p_manual_goal_acknowledged);
$function$;
revoke all on function public.set_dated_target_addition(uuid, date, text, numeric, uuid, uuid, boolean, boolean) from public;
grant execute on function public.set_dated_target_addition(uuid, date, text, numeric, uuid, uuid, boolean, boolean) to authenticated;

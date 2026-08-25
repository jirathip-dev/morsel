-- Morsel: security-invoker meal transaction and account ownership policies.
-- The RPC deliberately runs as the caller so meal_logs and meal_items RLS
-- policies are evaluated against auth.uid().

alter table public.users enable row level security;

create policy "users_select_own" on public.users for select
  using ((select auth.uid()) = id);
create policy "users_insert_own" on public.users for insert
  with check ((select auth.uid()) = id);
create policy "users_update_own" on public.users for update
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

create or replace function public.log_meal_with_items(
  p_user_id uuid,
  p_eaten_at timestamptz,
  p_meal_type text,
  p_source text,
  p_image_path text,
  p_notes text,
  p_items jsonb
)
returns table (
  meal_log_id uuid,
  eaten_at timestamptz,
  meal_type text,
  items jsonb
)
language plpgsql
security invoker
set search_path = public
as $function$
declare
  v_meal_log_id uuid;
begin
  if auth.uid() is distinct from p_user_id then
    raise exception 'meal user does not match authenticated user'
      using errcode = '42501';
  end if;

  if p_items is null
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) < 1 then
    raise exception 'a meal must contain at least one item'
      using errcode = '22023';
  end if;

  insert into public.meal_logs (
    user_id, eaten_at, meal_type, source, image_path, notes
  ) values (
    p_user_id, p_eaten_at, p_meal_type, p_source, p_image_path, p_notes
  ) returning id into v_meal_log_id;

  insert into public.meal_items (
    meal_log_id, name, quantity, unit, calories_kcal, protein_g, carbs_g,
    fat_g, fiber_g, sugar_g, barcode, food_ref_id, confidence, source_notes
  )
  select
    v_meal_log_id, item.name, item.quantity, item.unit, item.calories_kcal,
    item.protein_g, item.carbs_g, item.fat_g, item.fiber_g, item.sugar_g,
    item.barcode, item.food_ref_id, item.confidence, item.source_notes
  from jsonb_to_recordset(p_items) as item(
    name text,
    quantity numeric,
    unit text,
    calories_kcal numeric,
    protein_g numeric,
    carbs_g numeric,
    fat_g numeric,
    fiber_g numeric,
    sugar_g numeric,
    barcode text,
    food_ref_id uuid,
    confidence numeric,
    source_notes text
  );

  return query
  select
    log.id,
    log.eaten_at,
    log.meal_type,
    jsonb_agg(
      jsonb_build_object(
        'item_id', item.id,
        'name', item.name,
        'quantity', item.quantity,
        'unit', item.unit,
        'calories_kcal', item.calories_kcal,
        'protein_g', item.protein_g,
        'carbs_g', item.carbs_g,
        'fat_g', item.fat_g,
        'fiber_g', item.fiber_g,
        'sugar_g', item.sugar_g,
        'barcode', item.barcode,
        'food_ref_id', item.food_ref_id,
        'confidence', item.confidence,
        'notes', item.source_notes
      ) order by item.created_at, item.id
    )
  from public.meal_logs as log
  join public.meal_items as item on item.meal_log_id = log.id
  where log.id = v_meal_log_id
    and log.user_id = p_user_id
  group by log.id, log.eaten_at, log.meal_type;
end;
$function$;

revoke execute on function public.log_meal_with_items(uuid, timestamptz, text, text, text, text, jsonb) from public;
grant execute on function public.log_meal_with_items(uuid, timestamptz, text, text, text, text, jsonb) to authenticated;

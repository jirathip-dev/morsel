-- Optional stable artwork identity (issue #241). Generated allowlists below:
-- node packages/schema/generate-artwork-ids.mjs --sql
-- Reject unpublished non-null IDs; old rows/omitted JSON keys remain NULL.
-- Menu templates carry the same identity so named-menu reuse cannot drop it.
-- No backfill, signature change, privilege expansion, or name/nutrition rewrite.
alter table public.meal_items add column artwork_id text;
alter table public.menu_items add column artwork_id text;
alter table public.meal_items add constraint meal_items_artwork_id_published
  check (artwork_id in ('avocado', 'banana', 'broccoli', 'coffee', 'fallback-drinks', 'fallback-grains', 'fallback-neutral', 'fallback-produce', 'fallback-protein', 'fried-egg', 'grilled-chicken', 'jasmine-rice', 'mango', 'orange', 'salmon', 'stir-fried-noodles', 'toast', 'vegetable-soup'));
alter table public.menu_items add constraint menu_items_artwork_id_published
  check (artwork_id in ('avocado', 'banana', 'broccoli', 'coffee', 'fallback-drinks', 'fallback-grains', 'fallback-neutral', 'fallback-produce', 'fallback-protein', 'fried-egg', 'grilled-chicken', 'jasmine-rice', 'mango', 'orange', 'salmon', 'stir-fried-noodles', 'toast', 'vegetable-soup'));
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
  v_menu_name text;
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

  -- Named-menu template ensure: create the reusable menu from the logged
  -- items when the name is new; an existing menu is left untouched (the log
  -- below is always a snapshot copy).
  for v_menu_name in
    select distinct item.menu_name
    from jsonb_to_recordset(p_items) as item(name text, menu_name text)
    where item.menu_name is not null
      and length(btrim(item.menu_name)) > 0
  loop
    if not exists (
      select 1 from public.meal_menus
      where user_id = p_user_id and name = v_menu_name
    ) then
      insert into public.meal_menus (user_id, name)
      values (p_user_id, v_menu_name);
      insert into public.menu_items (
        menu_id, name, quantity, unit, calories_kcal, protein_g, carbs_g,
        fat_g, fiber_g, sugar_g, barcode, food_ref_id, artwork_id
      )
      select
        menus.id, item.name, item.quantity, item.unit, item.calories_kcal,
        item.protein_g, item.carbs_g, item.fat_g, item.fiber_g, item.sugar_g,
        item.barcode, item.food_ref_id, item.artwork_id
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
        artwork_id text,
        menu_name text
      )
      join public.meal_menus as menus
        on menus.user_id = p_user_id and menus.name = v_menu_name
      where item.menu_name = v_menu_name;
    end if;
  end loop;

  insert into public.meal_items (
    meal_log_id, name, quantity, unit, calories_kcal, protein_g, carbs_g,
    fat_g, fiber_g, sugar_g, barcode, food_ref_id, artwork_id, confidence, source_notes,
    menu_group_id, menu_name
  )
  select
    v_meal_log_id, item.name, item.quantity, item.unit, item.calories_kcal,
    item.protein_g, item.carbs_g, item.fat_g, item.fiber_g, item.sugar_g,
    item.barcode, item.food_ref_id, item.artwork_id, item.confidence, item.source_notes,
    item.menu_group_id, item.menu_name
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
    artwork_id text,
    confidence numeric,
    source_notes text,
    menu_group_id uuid,
    menu_name text
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
      ) || case when item.artwork_id is null then '{}'::jsonb
                else jsonb_build_object('artwork_id', item.artwork_id) end
      order by item.created_at, item.id
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

create or replace function public.log_meal_with_items_client(
  p_user_id uuid,
  p_eaten_at timestamptz,
  p_meal_type text,
  p_source text,
  p_image_path text,
  p_notes text,
  p_items jsonb,
  p_client_meal_id uuid
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
  v_inserted boolean;
  v_menu_name text;
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
    id, user_id, eaten_at, meal_type, source, image_path, notes
  ) values (
    p_client_meal_id, p_user_id, p_eaten_at, p_meal_type, p_source,
    p_image_path, p_notes
  )
  on conflict (id) do nothing;

  v_inserted := found;

  select id into v_meal_log_id
  from public.meal_logs
  where id = p_client_meal_id and user_id = p_user_id;

  if v_meal_log_id is null then
    raise exception 'meal id does not match authenticated user'
      using errcode = '42501';
  end if;

  if v_inserted then
    -- Named-menu template ensure (issue #152): same semantics as the server
    -- path — create from this log's items when the name is new, never
    -- overwrite an existing template.
    for v_menu_name in
      select distinct item.menu_name
      from jsonb_to_recordset(p_items) as item(name text, menu_name text)
      where item.menu_name is not null
        and length(btrim(item.menu_name)) > 0
    loop
      if not exists (
        select 1 from public.meal_menus
        where user_id = p_user_id and name = v_menu_name
      ) then
        insert into public.meal_menus (user_id, name)
        values (p_user_id, v_menu_name);
        insert into public.menu_items (
          menu_id, name, quantity, unit, calories_kcal, protein_g, carbs_g,
          fat_g, fiber_g, sugar_g, barcode, food_ref_id, artwork_id
        )
        select
          menus.id, item.name, item.quantity, item.unit, item.calories_kcal,
          item.protein_g, item.carbs_g, item.fat_g, item.fiber_g, item.sugar_g,
          item.barcode, item.food_ref_id, item.artwork_id
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
          artwork_id text,
          menu_name text
        )
        join public.meal_menus as menus
          on menus.user_id = p_user_id and menus.name = v_menu_name
        where item.menu_name = v_menu_name;
      end if;
    end loop;

    insert into public.meal_items (
      meal_log_id, name, quantity, unit, calories_kcal, protein_g, carbs_g,
      fat_g, fiber_g, sugar_g, barcode, food_ref_id, artwork_id, confidence, source_notes,
      menu_group_id, menu_name
    )
    select
      v_meal_log_id, item.name, item.quantity, item.unit, item.calories_kcal,
      item.protein_g, item.carbs_g, item.fat_g, item.fiber_g, item.sugar_g,
      item.barcode, item.food_ref_id, item.artwork_id, item.confidence, item.source_notes,
      item.menu_group_id, item.menu_name
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
      artwork_id text,
      confidence numeric,
      source_notes text,
      menu_group_id uuid,
      menu_name text
    );
  end if;

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
      ) || case when item.artwork_id is null then '{}'::jsonb
                else jsonb_build_object('artwork_id', item.artwork_id) end
      order by item.created_at, item.id
    )
  from public.meal_logs as log
  join public.meal_items as item on item.meal_log_id = log.id
  where log.id = v_meal_log_id
    and log.user_id = p_user_id
  group by log.id, log.eaten_at, log.meal_type;
end;
$function$;

revoke execute on function public.log_meal_with_items_client(
  uuid, timestamptz, text, text, text, text, jsonb, uuid
) from public;
grant execute on function public.log_meal_with_items_client(
  uuid, timestamptz, text, text, text, text, jsonb, uuid
) to authenticated;

-- ===== App menu CRUD (issue #152) =====
-- Atomic save (create OR full replace) of one menu template: rename, delete
-- every current menu_items row and re-insert the full list in ONE call so a
-- partial failure can never leave a half-edited template. The app generates
-- the menu id client-side (create) or passes the existing id (edit); the
-- server refuses ids that do not belong to the caller and duplicate names.

create or replace function public.upsert_menu(
  p_user_id uuid,
  p_menu_id uuid,
  p_name text,
  p_items jsonb
)
returns table (
  menu_id uuid
)
language plpgsql
security invoker
set search_path = public
as $function$
declare
  v_menu_id uuid;
  v_clean_name text;
begin
  if auth.uid() is distinct from p_user_id then
    raise exception 'menu user does not match authenticated user'
      using errcode = '42501';
  end if;

  v_clean_name := btrim(p_name);
  if v_clean_name is null or length(v_clean_name) = 0 then
    raise exception 'a menu needs a name'
      using errcode = '22023';
  end if;

  if p_items is null
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) < 1 then
    raise exception 'a menu must contain at least one item'
      using errcode = '22023';
  end if;

  v_menu_id := coalesce(p_menu_id, gen_random_uuid());

  if p_menu_id is null then
    insert into public.meal_menus (id, user_id, name)
    values (v_menu_id, p_user_id, v_clean_name);
  else
    update public.meal_menus
    set name = v_clean_name, updated_at = now()
    where id = p_menu_id and user_id = p_user_id;
    if not found then
      raise exception 'menu does not match authenticated user'
        using errcode = '42501';
    end if;
  end if;

  -- Full item-list replace: the edited list is the template's items.
  delete from public.menu_items as item where item.menu_id = v_menu_id;

  insert into public.menu_items (
    menu_id, name, quantity, unit, calories_kcal, protein_g, carbs_g,
    fat_g, fiber_g, sugar_g, barcode, food_ref_id, artwork_id
  )
  select
    v_menu_id, item.name, item.quantity, item.unit, item.calories_kcal,
    item.protein_g, item.carbs_g, item.fat_g, item.fiber_g, item.sugar_g,
    item.barcode, item.food_ref_id, item.artwork_id
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
    artwork_id text
  );

  return query select v_menu_id;
end;
$function$;

revoke execute on function public.upsert_menu(uuid, uuid, text, jsonb) from public;
grant execute on function public.upsert_menu(uuid, uuid, text, jsonb) to authenticated;

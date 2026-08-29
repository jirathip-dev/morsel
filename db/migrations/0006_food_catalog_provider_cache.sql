-- Persist external food lookups without granting clients direct catalog writes.
create or replace function public.upsert_food_catalog(p_rows jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  row jsonb;
begin
  if (select auth.uid()) is null then
    raise exception 'authenticated user required';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'food catalog rows must be an array';
  end if;
  for row in select value from jsonb_array_elements(p_rows) loop
    if (row->>'id' !~ '^[0-9a-fA-F-]{36}$'
      or coalesce(length(trim(row->>'name')), 0) = 0
      or (row ? 'calories_kcal' and (row->>'calories_kcal')::numeric not between 0 and 100000)
      or (row ? 'protein_g' and (row->>'protein_g')::numeric not between 0 and 10000)
      or (row ? 'carbs_g' and (row->>'carbs_g')::numeric not between 0 and 10000)
      or (row ? 'fat_g' and (row->>'fat_g')::numeric not between 0 and 10000)) then
      raise exception 'invalid food catalog row';
    end if;
  end loop;

  insert into public.food_catalog (id, name, brand, barcode, serving_size, serving_unit, calories_kcal, protein_g, carbs_g, fat_g)
  select id, name, brand, barcode, serving_size, serving_unit, calories_kcal, protein_g, carbs_g, fat_g
  from jsonb_to_recordset(p_rows) as rows(
    id uuid, name text, brand text, barcode text, serving_size text, serving_unit text,
    calories_kcal numeric, protein_g numeric, carbs_g numeric, fat_g numeric)
  on conflict (id) do nothing;
end;
$$;

revoke execute on function public.upsert_food_catalog(jsonb) from public;
grant execute on function public.upsert_food_catalog(jsonb) to authenticated;

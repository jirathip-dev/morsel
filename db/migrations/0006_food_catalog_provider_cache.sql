-- Persist only provider-derived food lookups; fdc_id prevents authenticated callers
-- from poisoning the shared catalog with a client-chosen UUID or source label.
create or replace function public.upsert_food_catalog(p_rows jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  row jsonb;
begin
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'food catalog rows must be an array';
  end if;
  for row in select value from jsonb_array_elements(p_rows) loop
    if row->>'fdc_id' is null or row->>'fdc_id' = ''
      or row->>'fdc_id' !~ '^[0-9]+$'
      or row->>'id' <> (
        substr(encode(digest('usda:' || (row->>'fdc_id'), 'sha256'), 'hex'), 1, 8) || '-' ||
        substr(encode(digest('usda:' || (row->>'fdc_id'), 'sha256'), 'hex'), 9, 4) || '-4' ||
        substr(encode(digest('usda:' || (row->>'fdc_id'), 'sha256'), 'hex'), 14, 3) || '-8' ||
        substr(encode(digest('usda:' || (row->>'fdc_id'), 'sha256'), 'hex'), 18, 3) || '-' ||
        substr(encode(digest('usda:' || (row->>'fdc_id'), 'sha256'), 'hex'), 21, 12)
      )
      or coalesce(length(trim(row->>'name')), 0) = 0
      or row->>'serving_size' <> '100'
      or lower(row->>'serving_unit') <> 'g'
      or row ? 'calories_kcal' and (row->>'calories_kcal')::numeric not between 0 and 100000
      or row ? 'protein_g' and (row->>'protein_g')::numeric not between 0 and 10000
      or row ? 'carbs_g' and (row->>'carbs_g')::numeric not between 0 and 10000
      or (row ? 'fat_g' and (row->>'fat_g')::numeric not between 0 and 10000) then
      raise exception 'invalid food catalog row';
    end if;
  end loop;

  insert into public.food_catalog (id, name, brand, barcode, serving_size, serving_unit, calories_kcal, protein_g, carbs_g, fat_g, source)
  select id, name, brand, barcode, serving_size, serving_unit, calories_kcal, protein_g, carbs_g, fat_g, 'usda'
  from jsonb_to_recordset(p_rows) as rows(
    id uuid, fdc_id bigint, name text, brand text, barcode text, serving_size text, serving_unit text,
    calories_kcal numeric, protein_g numeric, carbs_g numeric, fat_g numeric)
  on conflict (id) do nothing;
end;
$$;

revoke execute on function public.upsert_food_catalog(jsonb) from public, authenticated;
grant execute on function public.upsert_food_catalog(jsonb) to service_role;
grant insert, select on public.food_catalog to service_role;

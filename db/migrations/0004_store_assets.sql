-- Morsel: v0.1 storage assets and owner-scoped food image policies.
-- Storage object names use {user_id}/{meal_log_id}.jpg inside food-images.

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'food-images',
  'food-images',
  false,
  10 * 1024 * 1024,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Supabase owns the storage schema and creates storage.objects with RLS
-- enabled. The policies below are intentionally replaceable on a clean rerun.
drop policy if exists "food_images_insert_own" on storage.objects;
drop policy if exists "food_images_select_own" on storage.objects;
drop policy if exists "food_images_update_own" on storage.objects;
drop policy if exists "food_images_delete_own" on storage.objects;
drop policy if exists "food_catalog_select_authenticated" on public.food_catalog;

create policy "food_images_insert_own"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'food-images'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy "food_images_select_own"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'food-images'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy "food_images_update_own"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'food-images'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
)
with check (
  bucket_id = 'food-images'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy "food_images_delete_own"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'food-images'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

-- Catalog rows are shared reference data. Authenticated clients can search it,
-- but cannot mutate the seed-owned rows through the API.
alter table public.food_catalog enable row level security;

create policy "food_catalog_select_authenticated"
on public.food_catalog
for select
to authenticated
using (true);

commit;

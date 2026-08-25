-- Morsel: v0.1 storage assets and owner-scoped food image policies.
-- Storage object names use {user_id}/{meal_log_id}.jpg inside food-images.

insert into storage.buckets (id, name, public)
values ('food-images', 'food-images', false)
on conflict (id) do update
set public = false;

-- Supabase creates storage.objects with RLS enabled. Keep this explicit so a
-- fresh store cannot accidentally depend on a project-level default.
alter table storage.objects enable row level security;

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

# Supabase

The canonical database SQL currently lives in `db/migrations/`, because this
repository does not yet include a Supabase CLI project configuration.

Apply the migrations in numeric order:

1. `db/migrations/0001_init.sql`
2. `db/migrations/0002_targets.sql`
3. `db/migrations/0003_store_assets.sql`

Then apply `db/seed.sql` to load the deterministic v0.1 `food_catalog` reference
rows. The third migration creates the private `food-images` bucket and grants
authenticated users access only to object paths whose first segment is their own
user ID. The MCP server does not upload image bytes yet; it keeps HTTPS image
references in `meal_logs.image_path` until that flow is implemented.

# Supabase

The canonical database SQL currently lives in `db/migrations/`. The
`supabase/config.toml` file configures the Edge Function only; it does not
configure a local database, storage, or Studio project.

Apply the migrations in numeric order:

1. `db/migrations/0001_init.sql`
2. `db/migrations/0002_targets.sql`
3. `db/migrations/0003_atomic_meals_and_users_rls.sql`
4. `db/migrations/0004_store_assets.sql`

Then apply `db/seed.sql` with the privileged deployment role to load the
deterministic v0.1 `food_catalog` reference rows. Re-running the seed
intentionally restores the canonical values for its stable IDs. The fourth
migration creates the private `food-images` bucket, limits uploads to common
image MIME types up to 10 MiB, and grants authenticated users access only to
object paths whose first segment is their own user ID. The MCP server does not
upload image bytes yet; it keeps HTTPS image references in
`meal_logs.image_path` until that flow is implemented.

## Edge Function bundle and route check

The Supabase CLI's Edge Runtime uses Docker locally. The CI gate runs the
following pinned, non-deploying command and probes the function-name prefix:

```sh
npx --yes supabase@2.116.0 functions serve mcp --no-verify-jwt
```

In another terminal, expect `200` and `{"ok":true}` from the public health
route, then expect `401` from the unauthenticated MCP route:

```sh
curl --fail http://127.0.0.1:54321/functions/v1/mcp/health
curl --silent --show-error --write-out '%{http_code}\n' \
  --request POST \
  --header 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  http://127.0.0.1:54321/functions/v1/mcp/mcp
```

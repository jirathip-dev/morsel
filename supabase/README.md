# Supabase

The canonical database SQL currently lives in `db/migrations/`. The
`supabase/config.toml` file configures the Edge Function only; it does not
configure a local database, storage, or Studio project.

Apply the migrations in numeric order:

1. `db/migrations/0001_init.sql`
2. `db/migrations/0002_targets.sql`
3. `db/migrations/0003_atomic_meals_and_users_rls.sql`
4. `db/migrations/0004_store_assets.sql`
5. `db/migrations/0005_oauth_authorization_grants.sql`

Then apply `db/seed.sql` with the privileged deployment role to load the
deterministic v0.1 `food_catalog` reference rows. Re-running the seed
intentionally restores the canonical values for its stable IDs. The fourth
migration creates the private `food-images` bucket, limits uploads to common
image MIME types up to 10 MiB, and grants authenticated users access only to
object paths whose first segment is their own user ID. The MCP server does not
upload image bytes yet; it keeps HTTPS image references in
`meal_logs.image_path` until that flow is implemented.

## OAuth connector configuration

The Edge Function reads these values at request time:

- `SUPABASE_URL` — the project URL.
- `SUPABASE_ANON_KEY` — the publishable/anonymous key used for Supabase Auth
  email one-time-code requests (existing users only), refresh, and
  `auth.getUser()` validation.
- `MORSEL_OAUTH_SIGNING_KEY` — a long random secret used to sign and encrypt
  stateless OAuth client IDs, client-facing authorization-code envelopes,
  email-code transaction envelopes, and refresh-token wrappers. Authorization
  grants are stored in the RLS-protected `oauth_authorization_grants` table
  and claimed atomically by its `claim_oauth_authorization_grant` RPC.
- `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` — optional public absolute HTTPS URL for
  the browser authorization page. When set, only the authorization-server
  metadata's `authorization_endpoint` uses it; issuer, token, register,
  protected-resource metadata, challenge, resource, and MCP routes remain on
  the Supabase function base. It is not a credential.

The provider supports dynamic RFC 7591 registration, authorization-code OAuth
with S256 PKCE, and refresh tokens. The Supabase `/authorize` route remains the
backend and presents a two-step email one-time-code sign-in for existing
Morsel accounts: **sign in with the email on the Morsel account; a code is
emailed to you.** Step 1 requests a Supabase Auth email OTP with user creation
disabled and answers uniformly for known and unknown emails; step 2 verifies
the code and only then issues the authorization code. Code requests are
rate-limited per email, and the email/OAuth request travel between the steps
in a confidential, integrity-protected, expiring server-issued envelope — no
email, code, or token value is logged or echoed. Deployments may advertise the
verified no-JS static page `https://morsel-authorize-ui.vercel.app/authorize`
through `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT`; that page implements the same
two-step contract with method-preserving form posts forwarded to the fixed
Supabase route. Without the setting, metadata falls back to Supabase
`/authorize`. `/token` claims the stored authorization grant exactly once, then
refreshes the Supabase session and returns the real access token only after
`auth.getUser()` validates it, so MCP requests retain normal RLS behavior.
Configure `MORSEL_OAUTH_SIGNING_KEY` as a Supabase secret; do not put its value
in this repository.

Two human-owned configuration gates remain before live acceptance (no account
email is recorded in this repository): the Supabase email template must emit
`{{ .Token }}` (the code, not only a magic link), and if the account email is
an Apple Hide-My-Email `privaterelay.appleid.com` address, the sender must be
registered in the Apple developer portal (Sign in with Apple for Email
Communication) before mail will be forwarded.

## Edge Function bundle and route check

The Supabase CLI's Edge Runtime uses Docker locally, and `functions serve`
requires the local platform stack to be started first. CLI 2.116.0 does not
apply the repository-root `deno.json` to the shared function graph, so the CI
gate temporarily copies that pinned map beside the function entrypoint. The
copy is removed on exit; it is not a committed product file. The pinned,
non-deploying sequence is:

```sh
if [ -e supabase/functions/mcp/deno.json ]; then
  printf 'supabase/functions/mcp/deno.json already exists\n' >&2
  exit 1
fi
cp deno.json supabase/functions/mcp/deno.json
trap 'rm -f supabase/functions/mcp/deno.json' EXIT

npx --yes supabase@2.116.0 start \
  --exclude gotrue,realtime,storage-api,imgproxy,mailpit,postgrest,postgres-meta,studio,logflare,vector,supavisor \
  --ignore-health-check
npx --yes supabase@2.116.0 functions serve mcp --no-verify-jwt
```

For local OAuth registration/token probes, pass an env file containing
`MORSEL_OAUTH_SIGNING_KEY=...` with `--env-file`; add
`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT=https://morsel-authorize-ui.vercel.app/authorize`
when exercising the external metadata seam. The CI gate uses this form because
the Edge Runtime does not inherit arbitrary shell variables.

In another terminal, expect `200` and `{"ok":true}` from the public health
route, then expect `401` from the unauthenticated MCP transport. The canonical
client-facing transport is the function root `…/functions/v1/mcp`; the nested
`…/functions/v1/mcp/mcp` path remains only as the pre-#57 compatibility alias
(it answers identically but must not be given to clients):

```sh
curl --fail http://127.0.0.1:54321/functions/v1/mcp/health
curl --silent --show-error --write-out '%{http_code}\n' \
  --request POST \
  --header 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  http://127.0.0.1:54321/functions/v1/mcp
```

Stop the disposable local stack after the probe with:

```sh
npx --yes supabase@2.116.0 stop --project-id morsel --no-backup
```

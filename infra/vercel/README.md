# Vercel — consent skin project capture (issue #78)

The Morsel browser consent surface is a **static Vercel project**
(`morsel-authorize-ui`) whose entire source is committed in this repository
under `authorize-ui/`. There is no Vercel-specific build, no serverless
function, and no secret on Vercel (no env vars, no vercel.json secrets).

## What is repo-committed (source of truth)

- `authorize-ui/index.html`, `authorize-ui/privacy.html` + CSS — the consent
  and privacy pages.
- `authorize-ui/params.js` — the page's only JavaScript. It copies the closed
  allowlist of OAuth query fields into hidden inputs and points both stage
  forms at the fixed Fly origin `https://morsel-mcp.fly.dev/mcp/authorize`
  (issue #74). No fetch/XHR, no CORS, no storage, no analytics.
- `authorize-ui/vercel.json` — legacy `routes` config used ONLY for static
  rewrites (`/authorize` → `index.html`, `/privacy` → `privacy.html`) plus the
  strict CSP headers. Vercel legacy routes CANNOT proxy external POSTs, which
  is why consent posts go straight from the browser to Fly (see
  `docs/INFRA_DECISIONS.md`).
- `authorize-ui/authorization.test.js` — vitest contract pinning the
  committed action URL.

## What is NOT repo-committed (captured one-time manual step)

Vercel projects are dashboard/CLI one-time state, not files. The manual
one-time creation (already done for the live stack) is:

1. Create project `morsel-authorize-ui` on Vercel (free tier, org/owner Guy).
2. Framework preset: **Other/static**; root directory `authorize-ui/`;
   build command empty; output directory default.
3. Import from the GitHub repo `jirathip-dev/morsel`; Vercel then
   **auto-deploys every push/merge to `main`** that touches the project root
   (the repo root is watched; deploys of unrelated main changes are no-ops
   because the static output does not change).
4. No environment variables, no secrets, no custom domain needed (the
   canonical URL is `https://morsel-authorize-ui.vercel.app`).

For a fresh-project recreation, repeat step 1–4 with a NEW project name and
update the two committed references that name the live URL
(`authorize-ui/params.js` `AUTHORIZE_URL` — the Fly OAuth endpoint, NOT the
Vercel URL — and the `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` value documented in
`docs/VERCEL_OPERATIONS.md`); the Fly endpoint is per-stack, the Vercel URL is
advertised to clients via that secret/config value.

## Day-2 behavior (runbook: docs/VERCEL_OPERATIONS.md)

- Redeploy = merge to `main` (auto-deploy). Rollback = revert the
  `authorize-ui/` commit and let auto-deploy publish the previous state, or
  use the Vercel dashboard deployments list ("Promote" a previous
  deployment).
- No drift check can run against Vercel from this repo (no Vercel token is
  stored or referenced); the read-only verification is the deployed-page
  check in `docs/VERCEL_OPERATIONS.md`.

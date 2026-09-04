# Morsel Vercel operations (issue #78)

The Vercel surface is the static consent project `morsel-authorize-ui`
(source committed under `authorize-ui/`). This runbook covers day-2
behavior; the one-time project capture and the "what is / is not
repo-committed" split live in `infra/vercel/README.md`.

## Auto-deploy behavior

- Vercel watches the GitHub repo `jirathip-dev/morsel` (project import from
  `main`). Every merge to `main` auto-deploys; deploys that do not change
  the static output of `authorize-ui/` are no-ops.
- There is no build step and no environment variable on Vercel. The
  committed `vercel.json` only rewrites `/authorize` -> `index.html` and
  `/privacy` -> `privacy.html` and applies the strict CSP headers.
- No deploy workflow exists in `.github/workflows/` for Vercel and none is
  needed (auto-deploy is the CI/CD for this surface).

## Redeploy / rollback

- Redeploy: merge to `main` and confirm the deployment in the Vercel
  dashboard (or `vercel` CLI `vercel ls` / `vercel promote`, human
  environment).
- Rollback: revert the `authorize-ui/` commit on `main` (auto-deploy
  publishes the previous committed state) or promote an earlier deployment
  from the Vercel dashboard. Rollback of `params.js` also reverts the form
  POST target — always verify the deployed page afterwards (below).

## Verification checklist (read-only, after deploy/rollback)

1. Consent POST target: `curl -s https://morsel-authorize-ui.vercel.app/authorize`
   returns the consent HTML; the page's form action must be
   `https://morsel-mcp.fly.dev/mcp/authorize` (the Fly OAuth backend). The
   committed contract is pinned by `authorize-ui/authorization.test.js`
   (`npm test`) and by a source grep for the action URL; a live check is
   `curl -s https://morsel-authorize-ui.vercel.app/authorize | grep -o 'https://morsel-mcp.fly.dev/mcp/authorize'`.
2. Privacy page reachable: `curl -s -o /dev/null -w '%{http_code}' \
   https://morsel-authorize-ui.vercel.app/privacy` -> `200`.
3. OAuth end-to-end (human, live): the metadata `authorization_endpoint`
   advertised by the Fly origin
   (`https://morsel-mcp.fly.dev/mcp/.well-known/oauth-authorization-server`)
   is this Vercel page, and a consent POST reaches the Fly origin's
   `/mcp/authorize` (probe shape in `docs/FLY_DEPLOY.md` step 6).

## Fresh-project recreation

New Vercel project creation is dashboard/CLI one-time state: follow
`infra/vercel/README.md` steps 1-4 with a NEW project name, then update the
committed references that point at the live stack (the `params.js`
`AUTHORIZE_URL` — the Fly OAuth endpoint for the new stack — and the
`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` value configured on the new stack's
runtime). The full from-scratch dry run is documented in
`docs/FRESH_PROJECT_DRY_RUN.md` (step S3).

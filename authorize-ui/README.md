# Morsel static authorization page (retired GET-only surface)

Status (issue #66): **this page is no longer the OAuth consent surface.** Both
email-OTP stages are served by the Supabase function origin itself; this
directory is an archived static page that is kept only so the historical
`https://morsel-authorize-ui.vercel.app/authorize` URL keeps serving a real
page. Do not point clients at it.

## Where OAuth consent is served now

The consent flow runs entirely on the Supabase function origin:

- Authorization-server metadata advertises
  `https://<project>.supabase.co/functions/v1/mcp/authorize` as
  `authorization_endpoint` (the Edge Function never configures an external
  authorization page; `supabase/functions/mcp/index.ts`).
- The `/authorize` route itself renders both stages as server-side HTML
  (`server/oauth.ts`): a no-JavaScript stage-1 email form and a stage-2
  code-entry form, each a self-POST to the same origin with every
  non-credential OAuth parameter carried as a hidden field.
- Responses are `text/html; charset=utf-8` with the CSP
  `default-src 'none'; style-src 'unsafe-inline'; form-action 'self'`; the
  flow never redirects to a static page.
- The two-step contract is unchanged from #60: sealed single-use transaction
  envelope, uniform unknown/existing-account responses, per-email rate limit,
  single-use expiring codes, PKCE/redirect/resource binding, and no
  credential echoing. Behavior is pinned in `server/oauth.test.ts`.

## Why the static page was retired

Form posts from the page reached the Supabase backend through a legacy route
whose destination was an external Supabase URL. Vercel legacy routes do not
honor external destinations, so that route was inert: form posts to the page
URL answered `405` with an empty body, and mobile browsers showed a "download
authorize" sheet instead of the next stage. The #60 server-rendered path
already implemented the identical two-step contract, so the repository stopped
configuring the external page (issue #66). Removing the production secret
(`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT`) and any live hosting changes remain
human-gated; this lane only changes repository code, tests, and docs.

## Routing contract (`vercel.json`)

The file serves the archived page for `GET /authorize` and contains no other
route:

```json
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "routes": [
    { "src": "/authorize", "dest": "/index.html" }
  ]
}
```

## The archived page

Provider-neutral, **no-JavaScript** "Connect to Morsel" page with the same
neutral copy as the server-rendered forms and a restrictive script-free CSP
declaration. It never reads the query string, never writes storage, never
fetches, and has no server runtime. Its two stage forms omit action and use
`method="post"`, so a submission self-posts to the document URL with the
current query string preserved — historical behavior that can no longer reach
the backend, because the host has no route for form posts. The page therefore
cannot complete the flow and is not a consent surface — it exists only to keep
the historical URL serving a page.

## Files

- `index.html` — static two-stage page: email form (default), code form
  (`#code-entry`), restrictive script-free CSP declaration. No JavaScript.
- `authorization.css` — same-origin Morsel presentation using the existing
  palette tokens, including the `:target` stage switch.
- `vercel.json` — archived-page GET route (above); no form-post routing.
- `authorization.test.js` — repository-native Vitest contract: neutral copy,
  no-JS source proof, form/CSP/shape, contrast pairs, and README/route pins.

There is no fetch/XHR, server runtime, adapter, dynamic upstream,
cookie/storage use, analytics, logging, third-party script, or inline secret.

## Local verification

```sh
npx vitest run authorize-ui/*.test.js
```

The full repository verification additionally runs `npm test`, `npm run lint`,
and `npm run typecheck`.

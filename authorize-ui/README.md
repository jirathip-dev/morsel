# Morsel static authorization page (Vercel consent skin)

Status (issue #69): **this page is the browser consent surface again.** The
two-step email-code authorization runs on this Vercel static page while the
OAuth backend stays on the Supabase Edge Function, which answers only with
metadata, JSON errors, and bodyless redirects — never consent HTML.

> **Issue #72 note (single-process hosting):** the MCP/OAuth backend gains a
> second origin — `server/fly-entrypoint.ts` on Fly.io (`docs/FLY_DEPLOY.md`).
> This merge does not deploy or cut over, so the page's hardcoded form action
> (`params.js` `AUTHORIZE_URL`) still targets the LIVE Supabase Edge Function
> and is intentionally unchanged. As part of the human Fly cutover, retarget
> that constant (and `authorization.test.js`) to
> `https://morsel-mcp.fly.dev/mcp/authorize` and redeploy this page; the OAuth
> semantics on the new origin are identical.

## Why the page exists (and why the function cannot serve it)

Supabase's free shared domain does not support serving HTML from Edge
Functions: `text/html` GET responses are rewritten to `text/plain`, so
browsers display source instead of a rendered page (the #66/#68 regression).
Morsel stays on the free tier, so the repository's production wiring points
clients' browsers at this Vercel page again:

- The optional `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` Edge Function
  environment value names this page
  (`https://morsel-authorize-ui.vercel.app/authorize`). When it is set,
  authorization-server metadata advertises it as `authorization_endpoint`
  and every `/authorize` form response is a bodyless 302 back to it,
  carrying the OAuth parameters (plus the sealed `transaction` envelope and
  the `#code-entry` fragment on stage 2).
- Restoring that production secret after the #66 removal is a **human-gated
  config step**; the repository never reads, sets, or deletes the live
  secret. The deploy workflow verifies the expected endpoint but never
  creates it. Unset, the function keeps its server-rendered two-stage
  fallback (issue #66 hardening) as defense in depth — pinned by
  `server/oauth.test.ts` — but that fallback is not the production browser
  path on the shared domain.

## The consent flow

1. The MCP client starts at the metadata `authorization_endpoint` — this
   page — with the OAuth parameters in the query string.
2. `params.js` (the page's only JavaScript, same-origin, deferred) copies the
   closed allowlist of server-supported OAuth query fields
   (`client_id`, `redirect_uri`, `response_type`, `code_challenge`,
   `code_challenge_method`, `scope`, `resource`, `state`, and — on the code
   stage — `transaction`) into hidden inputs and points both stage forms at
   the fixed Supabase
   `https://anuerofnnewbsumukhqq.supabase.co/functions/v1/mcp/authorize`
   URL. It never copies `email`, `code`, `password`, duplicate values beyond
   the deterministic last-wins rule, unrecognized fields, or fragment data,
   and it performs no fetch/XHR, storage, analytics, logging, dynamic
   loading, or credential handling.
3. Submitting a stage form is a direct **cross-origin form POST** to the
   Supabase function — HTML form POSTs need no CORS and no proxy. The server
   validates the request (`requestParameters` accepts query or form body),
   requests/verifies the email one-time code, and 302s back to this page for
   the next stage or to the registered client with the authorization code.
4. The static host has no function, no proxy, and no form-post route:
   `vercel.json` serves `GET /authorize → index.html` only, so no submission
   can ever reach a backend through Vercel. Without the bridge script a
   form post would answer `404` from the static host — fail-closed, with no
   backend side effect.

## Routing and security contract (`vercel.json`)

```json
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "routes": [
    {
      "src": "/authorize",
      "dest": "/index.html",
      "methods": ["GET"],
      "headers": {
        "Content-Security-Policy": "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'none'; img-src 'none'; font-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'"
      }
    }
  ]
}
```

The file uses the legacy-routes-only form: the GET-only `/authorize` route
carries the restrictive `Content-Security-Policy` in its own `headers`
object. A top-level `headers` property cannot coexist with legacy `routes`
(`vercel build` rejects the mix with `RouteApiError invalid_mixed_routes`),
and the header is not attached implicitly — pinning it on the route object is
the only valid way to ship the deployed-header CSP alongside the GET rewrite.
The CSP value is byte-for-byte the same restrictive policy as the page's
`<meta>` (`script-src 'self'` admits only `params.js`); `form-action` stays
absent so the cross-origin form POST to Supabase remains allowed.

## Files

- `index.html` — the static two-stage "Connect to Morsel" page: email form
  (default), code form
  (`#code-entry`, shown by CSS `:target`), restrictive CSP declaration, and
  the single deferred `params.js` load. Visible copy, structure, styling,
  and palette tokens match the approved design.
- `params.js` — same-origin OAuth query-parameter bridge described above.
- `authorization.css` — same-origin Morsel presentation using the existing
  palette tokens, including the `:target` stage switch.
- `vercel.json` — GET-only `/authorize` page route plus the CSP header;
  no external-destination route, function, or proxy.
- `authorization.test.js` — repository-native Vitest contract: neutral copy,
  single-script/CSP/route pins, executable DOM tests that run the real
  `params.js` in a `node:vm` harness (no new dependency), contrast pairs,
  and README/route pins. Removing the script, weakening the credential
  exclusion, or pointing a form back at Vercel fails these tests RED.

There is no fetch/XHR, server runtime, adapter, dynamic upstream,
cookie/storage use, analytics, logging, third-party script, inline script,
or inline secret. Deployment and live acceptance of the page and the
`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` secret remain human-gated.

## Local verification

```sh
npx vitest run authorize-ui/*.test.js
```

The full repository verification additionally runs `npm test`, `npm run lint`,
and `npm run typecheck`.

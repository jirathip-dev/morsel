# Morsel static authorization page (email one-time code)

Provider-neutral, **no-JavaScript** browser consent page for Morsel's OAuth
authorization flow. The page copy is "Connect to Morsel" plus one line
explaining that an MCP client is requesting access to the user's Morsel
account — no client-specific label anywhere. Supabase remains the OAuth
issuer, dynamic registration endpoint, token endpoint, authorization POST
processor, grant store, identity provider, protected resource, and MCP
backend. The page is a static skin over the same two-step email-code contract
the server-rendered fallback implements (`server/oauth.ts`), so both surfaces
behave identically.

## The two-step contract

1. **Step 1 — email.** The user enters the email on their Morsel account and
   submits. The backend validates the full OAuth request first, requests a
   Supabase Auth email one-time code **for an existing user only**
   (`create_user: false` — the page can never sign a new account up), applies
   a per-email request rate limit, and answers **uniformly** for existing and
   unknown accounts so existence is never disclosed. The email, OAuth
   parameters, and expiry travel inside a confidential, integrity-protected,
   expiring **server-issued transaction envelope** (AES-GCM + HMAC with
   `MORSEL_OAUTH_SIGNING_KEY`); nothing sensitive rides in cleartext URLs or
   logs.
2. **Step 2 — code.** The user enters the 6-digit code. Wrong, expired,
   reused, malformed, or cross-transaction codes fail closed and return to
   code entry with every OAuth parameter intact. A correct code continues the
   existing stored-grant + authorization-code redirect to the registered
   client callback, with state/PKCE/resource/client/redirect semantics
   unchanged.

## How a static page carries state without JavaScript

The page never reads the query string, never writes storage, and never fetches.
It relies on two browser/platform behaviors:

- **Action-less form posts preserve the query string.** Each stage form omits
  `action` and uses `method="post"`, so the browser submits to the document's
  own URL. Every OAuth parameter (`client_id`, `redirect_uri`, `response_type`,
  `code_challenge`, `code_challenge_method`, `scope`, `resource`, `state`) and
  the `transaction` envelope therefore ride the request without any hidden
  inputs being generated client-side. Verified in a real browser
  (chrome-headless-shell via CDP): an action-less POST of this page's email
  form reached the server as `POST /?client_id=…&state=…&scope=…` with the
  email only in the body.
- **CSS `:target` staging.** After step 1 the backend `302`s back to this page
  with the OAuth parameters plus a fresh `transaction` envelope and the
  `#code-entry` fragment. `#code-entry` is `display:none` by default and both
  stages are toggled with `body:has(#code-entry:target)` rules — no script.
  A "Use a different email or request a new code" anchor returns to
  `#email-stage` (fragment-only navigation keeps the query).

## Routing contract (`vercel.json`)

`POST /authorize` must reach the Supabase backend while every other method
serves the static page, with the browser URL unchanged (rewrites, not
redirects):

```json
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "routes": [
    { "src": "/authorize", "dest": "https://anuerofnnewbsumukhqq.supabase.co/functions/v1/mcp/authorize", "methods": ["POST"] },
    { "src": "/authorize", "dest": "/index.html" }
  ]
}
```

Order is load-bearing: the `methods: ["POST"]` proxy rule wins for form posts,
and the second rule (no method filter) serves the page for GET and everything
else. Vercel documents external-destination routing as a reverse proxy that
forwards requests (method, query, and body) — this file is the
repository-verifiable statement of that contract and is asserted by
`authorization.test.js`. The platform behavior itself is not exercisable from
this repository, so the deploy checklist below re-probes it at activation
time, exactly like the existing CSP-response-header host gate.

## Security policy

The deployed response must return this CSP as an HTTP header as well as
retaining the document declaration:

```text
default-src 'none'; style-src 'self'; connect-src 'none'; img-src 'none'; font-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'
```

This is **tighter** than the pre-#60 page: `script-src` is gone because no
script may ever run. `form-action` remains intentionally omitted — the backend
validates every step and ends the flow with a `302` to each dynamically
registered client callback, and no CSP directive may block that chain. The
only two forms are the action-less self-posts above.

`frame-ancestors` is not enforced from a meta element, so the static host must
support the corrected CSP response header before acceptance. Do not broaden
`connect-src`, style sources, or add any script source.

## Deploy checklist (human gates — no deployment is authorized from a lane)

1. Verify the Vercel project serves this directory with `vercel.json`
   active, then re-probe the routing behavior with a real browser:
   load `…/authorize?client_id=…&state=…&code_challenge=…&redirect_uri=…&response_type=code`,
   submit the email form, and confirm the POST reaches Supabase with the full
   query string and the email in the body only, then follow the returned
   `302` to `#code-entry`, submit a code, and confirm the final `302` to the
   registered client callback. If external POST forwarding is not honored by
   the host, fall back to leaving `MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` unset:
   the server-rendered forms implement the identical two-step contract.
2. Supabase email template must emit `{{ .Token }}` (a code), not only a
   magic link — dashboard change, read back before live acceptance.
3. Apple "Hide My Email" check: if the account email is a
   `privaterelay.appleid.com` address, Apple only forwards mail from senders
   registered in the Apple developer portal (Sign in with Apple for Email
   Communication). Confirm the account uses a real email before acceptance;
   if it is a relay address, that portal registration becomes a gate. The
   account email itself is never recorded in this repository.

## Files

- `index.html` — static two-stage page: email form (default), code form
  (`#code-entry`), restrictive script-free CSP declaration. No JavaScript.
- `authorization.css` — same-origin Morsel presentation using the existing
  palette tokens, including the `:target` stage switch.
- `vercel.json` — method-preserving form-post routing contract (above).
- `authorization.test.js` — repository-native Vitest contract: neutral copy,
  no-JS source proof, form/CSP/routing shape, contrast pairs, README pins.

There is no fetch/XHR, server runtime, adapter, dynamic upstream,
cookie/storage use, analytics, logging, third-party script, or inline secret.

## Local verification

```sh
npx vitest run authorize-ui/*.test.js
```

The full repository verification additionally runs `npm test`, `npm run lint`,
and `npm run typecheck`.

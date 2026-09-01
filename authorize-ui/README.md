# Morsel external authorization UI

Provider-neutral Web Fetch API proxy for the OAuth `/authorize` document. It is
an approved fast path around the hosted Supabase restriction that rewrites GET
`text/html` responses to `text/plain` on default `supabase.co` domains.

This artifact is **not deployed**. It creates no hosting account or resource and
contains no credentials.

## Architecture and trust boundaries

```text
browser ── GET/HEAD/POST /authorize ──► external HTTPS handler
                                             │ fixed HTTPS upstream only
                                             ▼
                  Supabase /functions/v1/mcp/authorize
```

`handler.js` exports the pure `createAuthorizeHandler()` Web Fetch API handler.
The external layer:

- accepts only `/authorize` with GET, HEAD, POST, or OPTIONS;
- validates one fixed HTTPS `UPSTREAM_AUTHORIZE_URL` ending in `/authorize` at
  startup and never reads an upstream from the request;
- preserves the raw query and POST bytes rather than parsing OAuth or login
  fields;
- forwards no Cookie, Authorization, host, runtime, or custom request headers;
- uses `redirect: manual`, forwards only validated HTTPS (or OAuth-permitted
  loopback HTTP) redirect Locations, and filters all other upstream headers;
- applies the same allowlist, exact-one action rewrite, safe-header filter, and
  HTML security headers to GET forms and non-redirect POST form re-renders;
  missing/duplicate actions and unsupported/missing content types fail closed;
- returns validated forms as `text/html; charset=utf-8` with no-store, nosniff,
  and a restrictive CSP; JSON OAuth errors remain status/body/type-faithful;
- for HEAD, validates only the upstream status/content type and returns no body;
  HEAD cannot inspect or validate the form action, so it does not claim that
  document-level guarantee;
- emits no logs. In particular, it never logs query strings, request/response
  bodies, passwords, codes, tokens, state, client IDs, or redirect URIs.

This layer does **not** implement OAuth security policy. Exact redirect binding,
PKCE S256, state/CSRF handling, dynamic registration, user authentication,
authorization-code replay protection, token issuance, and refresh remain solely
with the existing Supabase backend.

## Configuration (non-secret)

Set exactly one value in the selected host's environment:

```text
UPSTREAM_AUTHORIZE_URL=https://<project-ref>.supabase.co/functions/v1/mcp/authorize
```

It is a public endpoint, not a credential. The handler rejects HTTP URLs,
userinfo, query strings, fragments, and paths not ending in `/authorize`.
Never put service-role keys, anon keys, OAuth tokens, or user credentials in the
external host configuration.

## Run and test (provider-neutral)

Requires a Web Fetch API runtime. Tests use the repository's existing Vitest dependency:

```sh
npx vitest run authorize-ui/*.test.js
node --check authorize-ui/handler.js
node --check authorize-ui/adapters/cloudflare.js
deno check authorize-ui/handler.js authorize-ui/adapters/cloudflare.js
```

The pure handler can be embedded by any runtime:

```js
import { createAuthorizeHandler } from './handler.js'
const handle = createAuthorizeHandler({ upstreamAuthorizeUrl: env.UPSTREAM_AUTHORIZE_URL })
```

A test may inject `fetch` through the second option; production adapters should
use the runtime's global `fetch`.

## Optional adapters and deploy gates

`adapters/cloudflare.js` is a thin Cloudflare Workers module adapter. It does
not imply that an account, project, route, token, or CLI exists.

Plausible free-host paths (each needs a separate human deployment approval):

- **Cloudflare Workers:** wire `adapters/cloudflare.js` as the module worker;
  set the non-secret variable above; approve/account-authenticate Wrangler;
  confirm the assigned HTTPS route is exactly `/authorize`.
- **Deno Deploy:** create a tiny entry point that reads
  `Deno.env.get('UPSTREAM_AUTHORIZE_URL')`, creates the handler once, and calls
  `Deno.serve(handler)`; approve project creation and Deno authentication first.
- **Vercel / Netlify Functions:** use their Fetch/Web handler adapter to call
  `createAuthorizeHandler`; configure a rewrite so public `/authorize` reaches
  that function unchanged. Approve account/project creation and CLI or Git
  integration first. Do not convert the request through URLSearchParams or a
  parsed body.

Before choosing a provider, verify its free tier supports: an HTTPS custom host,
raw request bodies, manual redirects, unmodified Location headers, Fetch API
Request/Response objects, and no platform HTML content-type rewrite. No hosting
CLI/account was found for Morsel during reconciliation; deployment intentionally
stops here.

## Required backend integration after a host is approved

A separate reviewed backend change must:

1. advertise the external HTTPS URL as
   `authorization_endpoint` in OAuth authorization-server metadata;
2. keep the backend `/authorize` response's known absolute form action equal to
   `UPSTREAM_AUTHORIZE_URL`, so this proxy's strict one-match rewrite remains
   valid;
3. leave `issuer`, `token_endpoint`, `registration_endpoint`, protected-resource
   metadata, MCP transport (`/functions/v1/mcp/mcp`), and resource URLs on
   Supabase.

The canonical distinction remains: `/functions/v1/mcp` is the issuer/base;
`/functions/v1/mcp/mcp` is the MCP transport. No Health Coach configuration is
changed by this artifact.

## Post-deploy readback (future human-approved operation)

Replace `<AUTH_UI_ORIGIN>` only with the approved host and use a newly registered
public client. Do not put passwords or tokens in shell history or logs.

```sh
# 1. Metadata: only authorization_endpoint moves to the external host.
curl -fsS https://<project-ref>.supabase.co/functions/v1/mcp/.well-known/oauth-authorization-server

# 2. Browser-facing GET: exact HTML and security headers.
curl -fsS -D /tmp/morsel-authorize-headers -o /tmp/morsel-authorize-body \
  '<AUTH_UI_ORIGIN>/authorize?<VALID_PUBLIC_OAUTH_QUERY>'
# Require: 200; content-type text/html; charset=utf-8; cache-control no-store;
# CSP with form-action self; x-content-type-options nosniff; exactly one
# action="/authorize"; no Server/X-Powered-By/Set-Cookie.

# 3. POST with a disposable test user only: confirm the exact registered
# callback Location and state, then exchange through the SUPABASE token endpoint.
```

After readback, perform one Claude connector smoke only after explicit live-test
approval: connect via the advertised metadata, call **`get_profile` only**, verify
that it returns the signed-in user's profile, then stop. Do not call any write,
delete, meal, goal, target, or token-refresh tool in this smoke.

No deployment, live readback, account creation, DNS change, Supabase mutation,
or Claude acceptance was performed in this round.

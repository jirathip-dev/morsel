# Morsel static authorization page

This directory is a provider-neutral static page for the browser-facing OAuth authorization step. Supabase remains the OAuth issuer, dynamic registration endpoint, token endpoint, authorization POST processor, grant store, identity provider, protected resource, and MCP backend.

The page has no server or proxy. It reads `window.location.search`, creates one hidden input per decoded query pair in original order, excludes only query-controlled `email` and `password`, and submits required credential controls directly to the fixed Supabase endpoint:

`https://anuerofnnewbsumukhqq.supabase.co/functions/v1/mcp/authorize`

The page preserves ordered duplicate controls at the browser form layer. The current backend overlays POST fields with `URLSearchParams.set`, so duplicate names are last-wins at the backend; standard OAuth `scope` remains one space-delimited field. Do not rely on end-to-end duplicate preservation.

It does not validate or sign OAuth values. The Supabase backend validates the signed client ID, exact registered redirect URI, authorization-code response type, S256 PKCE challenge, optional resource, credentials, grant, and token exchange.

## Files

- `index.html` — static form and restrictive CSP declaration.
- `authorization.css` — same-origin Morsel presentation using existing palette tokens.
- `authorization.js` — fixed endpoint constant and DOM-only hidden-control wiring.
- `authorization.test.js` — repository-native Vitest security and wiring contract.

There is no fetch/XHR, server runtime, adapter, dynamic upstream, cookie/storage use, analytics, logging, third-party script, or inline secret.

## Security policy

The deployed response must return this CSP as an HTTP header as well as retaining the document declaration:

```text
default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'none'; img-src 'none'; font-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'
```

`form-action` is intentionally omitted. Browsers enforce `form-action` on every redirect in a form navigation chain, so restricting it to the Supabase POST URL would block Supabase's validated `302` to each dynamic registered client callback. The initial destination remains pinned independently by the fixed HTML `action`, the same fixed exported JavaScript constant, and the no-injection contract.

Before acceptance, a fresh reviewer must rerun a real-browser redirect-chain probe that exercises the fixed authorization POST followed by a `302` to a different registered callback origin. The browser-free source fixture prevents the known directive from returning, but it cannot replace browser enforcement evidence.

`frame-ancestors` is not enforced from a meta element, so a future static host must support the corrected CSP response header before acceptance. Do not broaden `connect-src`, script sources, or style sources. Query data must never select the form action.

## Known blank-credential limitation

Both email and password are browser-required. If browser validation is bypassed and a blank credential POST reaches Supabase, the backend re-renders HTML that the default Supabase gateway labels `text/plain`; that retry page will not render normally. Invalid non-blank credentials follow the backend's existing `302 error=access_denied&state=...` path. This bounded artifact is intended only for the first valid-credential Claude test after all human gates are approved.

## Future human gates — no deployment is authorized

GitHub Pages alone cannot emit arbitrary CSP response headers and is not sufficient for the required `frame-ancestors` acceptance policy. A separately approved static host or fronting layer with response-header support is required. The repository currently has no Pages site. A human must separately approve and perform all account, project, hosting, DNS, and publication work.

After review and merge, integration must be serialized with the exact delivery of #57:

1. Enable an approved static HTTPS host and verify the exact files and CSP header.
2. Change only OAuth metadata `authorization_endpoint` to the static HTTPS page.
3. Keep issuer, register, token, protected-resource, resource, and MCP URLs on Supabase.
4. Deploy the separately reviewed backend metadata change.
5. Read back dynamic registration → static authorization GET → Supabase POST → token exchange → `get_profile`.
6. Run one separately approved live Claude `get_profile`-only smoke.

This implementation contract must not deploy, merge, enable hosting, modify GitHub Pages, change Supabase/Auth, or run live acceptance.

## Local verification

```sh
npx vitest run authorize-ui/*.test.js
node --check authorize-ui/authorization.js
```

The full repository verification additionally runs `npm test`, `npm run lint`, and `npm run typecheck`.

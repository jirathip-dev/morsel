# Custom domain setup (superseded for the MCP endpoint by issue #72)

> **Update (issues #72/#75):** the MCP endpoint runs on Fly.io single-process
> hosting (`server/fly-entrypoint.ts`, `docs/FLY_DEPLOY.md`) — one Bun process
> on a Fly VM keeps the in-memory MCP session map alive. The Fly origin is
> deployed and canonical: the client-facing URL is
> `https://morsel-mcp.fly.dev/mcp`, which the app build configuration and the
> onboarding copy publish (issue #75), so this Supabase custom-domain option
> is not the path to a clean MCP endpoint host. The rest of this document is
> kept as the record of the earlier (never-activated) Supabase custom-domain
> plan, which still applies to the Supabase side if the repository ever
> serves browser HTML from the Supabase function origin again — a Supabase
> custom domain would only affect the Supabase side, never the Fly MCP base
> or `MORSEL_MCP_URL`.

Status: **documentation only.** No DNS record or Supabase custom-domain
configuration has been created, and no custom-domain activation has been
performed or authorized from an implementation lane. Activation requires
explicit human approval after the checklist below is complete. Nothing in
this custom-domain plan is live.

The current browser-authorization path does not require a Supabase custom
domain: the consent HTML lives on the static Vercel page (`authorize-ui/`,
issues #69/#74), whose forms POST to the Fly origin's `/mcp/authorize`, and
the Fly origin answers the OAuth flow with metadata, JSON errors, and
bodyless 302s back to that page (the optional
`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` secret names the Vercel page; it is set
on the deployed Fly app — live authorization-server metadata advertises the
Vercel page — and any future change is human-gated). The canonical MCP URL,
issuer, OAuth backend routes, resource, and challenge URLs live on the Fly
origin at
`https://morsel-mcp.fly.dev/mcp` (issues #72/#73/#75). The Supabase Edge
Function transport is legacy/retained backend compatibility only — it is not
a client-facing base, and a Supabase custom domain would not change the
canonical MCP base. This document describes a separate future custom-domain
option for the Supabase side only.

## Why a custom domain

On the default `*.supabase.co` project URL, Supabase's hosted gateway rewrites
certain responses (observed: GET `text/html` becomes `text/plain`, issue #55)
— which is why consent HTML is served from the static Vercel page (issue #69)
while the function stays metadata/JSON/302-only. A project-level custom
domain remains Supabase's supported future path to stable, browser-facing
behavior for a server-hosted OAuth `/authorize` form (should the repository
ever move the consent skin back onto the function origin). It is not a path
to the MCP endpoint host — the canonical client-facing URL is the Fly origin
`https://morsel-mcp.fly.dev/mcp` (issues #72/#75). The example below is the
Supabase-side base of that earlier plan:

```
https://<owned-custom-subdomain>/functions/v1/mcp
```

The app publishes the canonical MCP URL from the Fastlane build configuration
(`CANONICAL_MCP_URL = "https://mcp.morselfood.app/mcp"` in `fastlane/Fastfile`,
issue #75; the origin moved to the morselfood.app custom domain in #130).
This replaced the earlier `SUPABASE_URL`-derived Edge Function URL
as the value delivered through `MORSEL_MCP_URL`, so a Supabase custom domain no
longer flows into app builds; the Supabase Edge transport is retained as
legacy backend compatibility. The Swift app never hardcodes a hostname — the
value reaches it through the build-config Info.plist key.

## Facts and limitations (verified against Supabase's published behavior)

- **Paid add-on.** Custom domains are a Supabase paid-plan add-on. Do not
  purchase or enable any plan change without explicit approval.
- **One domain per project.** A Supabase custom domain applies to the entire
  project (Auth, Storage, REST, Edge Functions), not just the `mcp` function.
  Every client, integration, and published URL that uses the default
  `*.supabase.co` host is affected by the switch.
- **CNAME-based.** Activation requires adding a CNAME record for the chosen
  subdomain pointing at Supabase's custom-domain target, then re-verifying and
  activating the domain from the Supabase dashboard (or CLI). DNS propagation
  and certificate issuance happen during activation.
- **Rewrite behavior follows the domain.** After activation the gateway's
  `text/html` rewrite no longer applies (per Supabase's custom-domain
  behavior). Today the consent skin is the Vercel page (issue #69), so this
  only matters if the repository ever moves the browser forms back onto the
  function origin; re-verify the content-type after any such change — do not
  assume it.

## Activation checklist (human-gated; each step explicit)

1. **Choose the subdomain** and confirm the plan add-on with the project owner.
2. **Prepare Supabase Auth callback/redirect settings BEFORE switching:**
   - Site URL and any redirect URLs that reference `*.supabase.co` must be
     reviewed; add the custom-domain equivalents first.
   - OAuth clients' registered `redirect_uris` (in Morsel, stateless RFC 7591
     registrations) are client-side values — any external client that
     registered a `*.supabase.co`-based redirect needs re-registration or a
     documented exemption. (Historical scope: since issues #72/#73 the MCP
     OAuth backend and client registration live on the Fly origin, so this
     bullet applied while registrations targeted the Supabase function base;
     it no longer affects MCP OAuth clients.)
3. **Add the CNAME record** at the DNS provider (no proxying; DNS-only).
4. **Verify, then activate** the custom domain in the Supabase dashboard.
   Activation is the cutover point for the project's public hostname.
5. **Update `SUPABASE_URL`** (GitHub repository variable/secret and any local
   environments) to the custom domain so the Supabase project (Auth,
   Postgres/RLS, storage, and the retained legacy Edge Function) uses the
   custom domain. This does NOT change the app's MCP endpoint: `MORSEL_MCP_URL`
   is the fixed Fly URL (`CANONICAL_MCP_URL` in `fastlane/Fastfile`, issue
   #75) and never derives from `SUPABASE_URL`.
6. **Read-back verification after activation (required, no static-proof
   claims):**
   - `GET https://<domain>/functions/v1/mcp/health` → `200 {"ok":true}`.
   - Unauthenticated `POST …/functions/v1/mcp` (initialize) → `401`
     `application/json` with a browser-readable `WWW-Authenticate` header whose
     `resource_metadata` URL uses the custom domain.
   - `GET …/functions/v1/mcp/.well-known/oauth-authorization-server` → `200`
     with issuer/endpoints on the custom domain.
   - If the consent skin is ever moved back onto the function origin:
     `GET …/functions/v1/mcp/authorize?…` → `200` `text/html; charset=utf-8`
     (not `text/plain`). (Today the browser skin is the Vercel page — issue
     #69 — so the hosted function answers /authorize with 302s/JSON only.)
   - A real client connection (OAuth sign-in + `get_profile`) end to end.
7. **Rollback / read-back plan.** Rolling back a custom domain means
   deactivating it in Supabase and reverting DNS; the default `*.supabase.co`
   host keeps resolving. Because the one domain covers the whole project,
   rollback re-exposes the `text/html` rewrite limitation and re-points every
   published URL — record the decision (activation date, previous `SUPABASE_URL`,
   DNS change-set) before starting so the rollback is reproducible.

## Explicitly out of scope for automation

- Purchasing a domain or the Supabase add-on.
- Creating DNS records or activating the domain.
- Mutating hosted Supabase Auth settings.
- Redeploying the Edge Function to production.
- Any live-client acceptance claim.

Each of the above is a human decision recorded outside this repository.

# Custom domain setup (planned; not activated)

Status: **documentation only.** No DNS record, Supabase custom-domain
configuration, or production deployment has been performed or authorized from
the implementation lane. Activation requires explicit human approval after the
checklist below is complete. Nothing in this document is live.

The current browser-authorization path does not require a Supabase custom
domain: the consent HTML lives on the static Vercel page (`authorize-ui/`,
issue #69), and the Edge Function answers the OAuth flow with metadata, JSON
errors, and bodyless 302s back to that page (the optional
`MORSEL_OAUTH_AUTHORIZATION_ENDPOINT` secret names it; restoring that
production secret is human-gated). The canonical MCP URL, issuer, OAuth
backend routes, resource, and challenge URLs remain on the Supabase function
base. A custom domain would only change the hostname of that same base. This
document describes a separate future custom-domain option only.

## Why a custom domain

On the default `*.supabase.co` project URL, Supabase's hosted gateway rewrites
certain responses (observed: GET `text/html` becomes `text/plain`, issue #55)
— which is why consent HTML is served from the static Vercel page (issue #69)
while the function stays metadata/JSON/302-only. A project-level custom
domain remains Supabase's supported future path to stable, browser-facing
behavior for a server-hosted OAuth `/authorize` form (should the repository
ever move the consent skin back onto the function origin) and a clean
canonical MCP endpoint host:

```
https://<owned-custom-subdomain>/functions/v1/mcp
```

The app publishes the canonical MCP URL from the Fastlane build configuration
(`SUPABASE_URL` + `/functions/v1/mcp` in `fastlane/Fastfile`), so once the
project URL becomes the custom domain (or `SUPABASE_URL` is updated to it), the
app, docs, and probes all follow one source of truth. No hostname is hardcoded
anywhere in the repository.

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
     documented exemption.
3. **Add the CNAME record** at the DNS provider (no proxying; DNS-only).
4. **Verify, then activate** the custom domain in the Supabase dashboard.
   Activation is the cutover point for the project's public hostname.
5. **Update `SUPABASE_URL`** (GitHub repository variable/secret and any local
   environments) to the custom domain so `fastlane/Fastfile` derives the new
   canonical `MORSEL_MCP_URL` for the next app build.
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

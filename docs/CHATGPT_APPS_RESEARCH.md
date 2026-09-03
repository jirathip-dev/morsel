# ChatGPT Apps marketplace research (issue #86)

Retrieval date: **2026-09-04**. Every claim below comes from the cited live
pages retrieved that day; full-page fetches where noted, search-engine page
snapshots otherwise. This document is the research layer for the Morsel
listing preparation; the companion one-sitting checklist is
`docs/CHATGPT_APPS_SUBMISSION.md`.

## TL;DR — deltas vs this issue's 2026-09-03 assumptions

1. **The submission unit is a "plugin", not an "app".** OpenAI's current
   docs state plainly: *"Apps are now submitted and published as plugins."*
   An MCP-backed listing is submitted through the **plugin submission
   portal** (`https://platform.openai.com/plugins`) as **Create plugin →
   With MCP** (an MCP-only plugin; no custom UI, no skills). Approved
   plugins publish into the **universal Plugins Directory shared by ChatGPT
   and Codex** (user-visible as the Apps/Plugins area in ChatGPT;
   `chatgpt.com/apps`). The December 17, 2025 announcement referenced
   `platform.openai.com/apps-manage` and some 2026 third-party guides still
   describe an "apps dashboard"; the official docs are unambiguous that the
   plugin portal is the source of truth *now*. Guy should use whatever
   surface his account shows, but expect the plugin portal path below.
2. **Hard pre-requisites (org level):** verified **individual or business
   identity** in the OpenAI Platform (enforced during review), **Apps
   Management** role with write access (`api.apps.write`; owners have it
   automatically), and a project with **global data residency** (EU
   residency projects cannot submit MCP-backed plugins today).
3. **MCP review checklist OpenAI applies:** public production HTTPS server
   URL; **domain verification** (exact token hosted at
   `https://<mcp-host>/.well-known/openai-apps-challenge`); a successful,
   current **Scan Tools** import (tool names/titles/descriptions, schemas,
   security schemes, annotations, `_meta`); explicit
   `readOnlyHint`/`destructiveHint`/`openWorldHint` values **plus a written
   justification for every tool**; reviewer connectivity through the demo
   credentials; audit of tool responses for undisclosed user data vs the
   privacy policy; five positive + three negative test cases.
4. **Listing fields and limits (final directory submission):** display name
   ≤ 30 chars, short description ≤ 30 chars (one line), long description ≤
   4,000 chars; category from a closed list (see below); logo = production
   brand asset (OpenAI publishes no exact dimensions — verified; see
   `docs/CHATGPT_APPS_SUBMISSION.md` for the icon decision); **four
   HTTPS URLs are required for MCP-backed submissions** — website, support,
   privacy policy, **terms** (≤ 1,024 chars each). Morsel has no terms page
   yet → follow-up asset (out of this lane's fences).
5. **Demo credentials conflict (flagged, not resolved here):** OpenAI
   requires a reviewer-ready demo account that logs in *"with no further
   configuration required"* and rejects flows needing *"MFA (including
   requiring SMS codes … email or other verification schemes)"*. Morsel's
   only auth is an **email one-time code** — an email verification scheme.
   The OpenAI review team almost certainly cannot complete that flow with a
   password-style demo login. This is a **hard-requirement delta** needing a
   decision (options: a password-capable demo path, an exception question to
   OpenAI support, or a review-mode auth change) — a follow-up issue; no
   implementation here. Real end users' OAuth with their own email is
   unaffected.
6. **OAuth mode: DCR is sufficient — issue assumption CONFIRMED.** OpenAI's
   auth docs name CIMD as *preferred* when the authorization server
   supports it (`client_id_metadata_document_supported: true`), but
   **DCR remains fully supported**: if `registration_endpoint` is
   advertised, ChatGPT registers dynamically when the builder chooses DCR.
   The builder may pick DCR when both are available. No server-side CIMD
   delta is required to submit with DCR. (Doc-tree inconsistency noted: the
   older `apps-sdk/build/auth` wording still calls CIMD a draft, while
   `plugins/build/auth` — the current source of truth — describes CIMD as
   adopted via MCP SEP-3149. The optional CIMD server delta from the issue
   stays a separate follow-up either way.)
7. **Timelines:** none published — *"review timelines may vary"*; expedite
   requests are not accommodated; status changes come by email; after
   approval the **developer chooses when to publish**; removal/publish from
   the portal; updates go through a new review; an MCP origin
   (scheme/host/port) change requires a brand-new plugin.
8. **Extras discovered (not in the issue assumptions):** a
   **demo-recording URL is required** for MCP-backed submissions (hosted
   video of main use cases across supported platforms); release notes; up to
   3 starter prompts (≤ 128 chars each, no `@mention`); country-availability
   and localization fields; optional brand colors; no screenshots allowed
   unless the scan reports custom UI (Morsel has none).
9. **No paid-plan prerequisite found** in official docs for the submitter
   (only org verification + Apps Management permission). Whether Guy's
   platform org needs billing/credits is unverified — treat as an
   at-submit check, not an assumption.
10. **Monetization:** plugins may conduct commerce only for physical goods
    and must not serve ads. Morsel has no in-app commerce and no ads —
    attestations should be straightforward.

## Source list (retrieved 2026-09-04 unless noted)

| Source (exact URL) | Establishes |
| --- | --- |
| https://developers.openai.com/plugins/deploy/submission | Source-of-truth submission flow: portal location, Create plugin → With MCP, Info/MCP/Prompts/Testing/Global/Submit tabs, domain verification, demo credentials, final checklist, publish flow (full-page fetch). |
| https://developers.openai.com/plugins/deploy/app-review | MCP server review requirements: org verification, `api.apps.write`/`read`, server requirements, tool-scan metadata capture, review/approval/appeals FAQ (common rejection reasons), version maintenance (full-page fetch). |
| https://developers.openai.com/plugins/deploy/submission-errors | Exact listing limits (display ≤ 30, short ≤ 30, long ≤ 4,000, URLs ≤ 1,024, categories list, 5+/3− test cases, demo-recording URL, annotations/justifications, screenshot dimensions) (full-page fetch). |
| https://developers.openai.com/plugins/app-guidelines | Plugin guidelines: quality/name rules, tool annotations, test-credential rule ("login and password … no sign-up or 2FA"), privacy-policy minimum content, no ads, org verification (full-page fetch). |
| https://developers.openai.com/plugins/build/auth | OAuth registration: CIMD preferred, DCR supported, token methods (`none`/`private_key_jwt`), workspace domain restrictions (page snapshot via live search). |
| https://developers.openai.com/apps-sdk/deploy/submission and https://developers.openai.com/apps-sdk/app-submission-guidelines | "Apps are now submitted and published as plugins"; app-specific requirements inside plugins (snapshots via live search). |
| https://openai.com/index/developers-can-now-submit-apps-to-chatgpt/ | OpenAI announcement (Dec 17, 2025): public app submissions, app directory in ChatGPT (`chatgpt.com/apps`), dashboard link `platform.openai.com/apps-manage`. |
| https://openai.com/policies/developer-apps-terms/ | App Developer Terms governing publication, removal, fees. |
| Third-party guides (2026, non-authoritative, flagged): https://manufact.com/blog/publish-mcp-app-on-chatgpt, https://alpic.ai/blog/how-to-submit-your-app-to-the-chatgpt-directory | Only used for the logo-format hint ("square PNG, platform applies circular cropping"; official docs publish no logo spec). Treat as unverified until the portal accepts the asset. |

## Requirement deltas needing follow-up (NOT implemented in #86)

- **Domain-verification token route** at
  `https://morsel-mcp.fly.dev/.well-known/openai-apps-challenge` — the Fly
  Bun server must serve the token (server change; forbidden in this lane).
- **Terms-of-service URL** — required for MCP-backed submissions; no Morsel
  terms page exists.
- **Reviewer demo login** — Morsel's email-OTP flow conflicts with the
  no-email-verification demo-credential rule (see TL;DR item 5).
- **Demo-recording URL** — a hosted video of main use cases (Guy task).
- Optional: CIMD support on the server (per issue text — separate follow-up,
  not required for a DCR submission).

## Open/unverified items (say so, don't guess)

- Exact logo dimensions/format accepted by the portal (not published).
- Exact field labels of the live form tabs.
- Whether the submitter org/project needs billing or a paid plan.
- Realistic review duration (deliberately unpublished by OpenAI).
- Category dropdown contents (docs list the closed set below; the portal
  dropdown governs): Productivity, Creativity, Developer Tools, Business &
  Operations, Data & Analytics, Communication, Education & Research,
  Security, Finance, Healthcare, Travel, Entertainment, Other. Recommended
  pick for Morsel: **Healthcare** (nutrition tracking), confirm against the
  dropdown.

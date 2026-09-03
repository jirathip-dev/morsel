# Morsel — ChatGPT Apps marketplace submission checklist (issue #86)

Goal: Guy can complete the whole dashboard submit in one sitting. Research,
sources, and requirement deltas: `docs/CHATGPT_APPS_RESEARCH.md` (retrieved
2026-09-04). Dashboard submission itself is Guy's human step; this lane
produced no server/OAuth/tool changes.

Current submission surface (2026-09-04 docs): apps are submitted and
published as **plugins**. Portal: `https://platform.openai.com/plugins` →
**Create plugin** → **With MCP** (MCP-only — Morsel has no custom UI in
ChatGPT, so no screenshots, no skills, no CSP-for-UI).

---

## 0. Pre-flight — do these FIRST (several are open gaps, not done in #86)

- [ ] **Confirm the real support address.** The committed privacy page shows
  the placeholder `support@morsel.app` (clearly marked in the file). Pick
  the real address Guy controls; if it differs, update
  `authorize-ui/privacy.html` (find/replace the email) and let the Vercel
  auto-deploy publish it before submitting. Re-run the authorize-ui tests
  after any edit.
- [ ] **Terms-of-service URL — REQUIRED, MISSING.** MCP-backed submissions
  need website + support + privacy + **terms** URLs. No Morsel terms page
  exists; decide (e.g., a follow-up static page or a short policy page on
  the Vercel host) and have it live before the Submit tab. (Open gap from
  #86; not in this lane's fences.)
- [ ] **Domain verification — REQUIRES A SERVER ROUTE (open follow-up).**
  The portal will ask to verify `https://morsel-mcp.fly.dev` by fetching the
  exact token at `https://morsel-mcp.fly.dev/.well-known/openai-apps-challenge`.
  The Fly Bun server does not serve that path today — add a minimal route
  (follow-up issue, server change) or check with OpenAI whether an alternate
  challenge base is acceptable. Do not submit before this returns the bare
  token (no JSON, no extra bytes).
- [ ] **Reviewer demo-account decision — REQUIRED, OPEN.** OpenAI review
  needs demo credentials that log in "with no further configuration" and
  rejects login flows needing email/SMS verification. Morsel's only sign-in
  is an email one-time code → an email verification scheme. Real users are
  fine (their own mailbox); the OpenAI reviewer is the problem. Options:
  (a) ask OpenAI support whether an email-OTP flow with a dedicated demo
  inbox is acceptable; (b) plan a password-capable demo path as a follow-up;
  (c) pause the submit. See research doc item 5.
- [ ] **Create a dedicated demo account** (separate from Guy's daily
  account) with **sample data**: seed ~5–7 realistic meals across a few days
  plus a profile and goals, using the real MCP tools, so review test cases
  produce deterministic results.
- [ ] **Demo-recording URL — REQUIRED, OPEN.** MCP-backed submissions need a
  hosted demo recording showing the main use cases across supported
  platforms (ChatGPT desktop/web/mobile). Produce a short screen recording
  (Loom or similar) of: photo log, typed log, day summary, dashboard
  summary, goal/profile update. Guy task.
- [ ] **Org prerequisites:** verified individual or business identity in the
  OpenAI Platform (`platform.openai.com/settings/organization/general`);
  Apps Management permission = **Write** (owners have it; roles at
  `platform.openai.com/settings/organization/people/roles`); project with
  **global** data residency (EU residency cannot submit MCP plugins).
- [ ] **Icon file ready:** `app/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`
  (1024×1024 opaque PNG from the canonical artwork — see `docs/ICON.md`).
  OpenAI publishes no logo spec (2026-09-04); third-party guidance says a
  square PNG without rounded corners/borders (the platform crops
  circularly). Upload this file; if the portal imposes a different spec,
  file a follow-up asset task — #86 created no new brand art.
- [ ] **Run the five positive + three negative test cases** (below) in
  ChatGPT developer mode against the demo account; capture real outputs and
  expected-result notes into the Testing tab text.

---

## 1. Where to submit (click-path)

1. Sign in to `https://platform.openai.com` (the org that owns the
   submission).
2. Open the plugin submission portal: `https://platform.openai.com/plugins`.
   (If Guy's account shows "ChatGPT Apps" under Manage instead, that is the
   same directory surface per OpenAI's Dec-2025 announcement; the official
   docs point to the plugin portal as the current source of truth.)
3. **Create plugin** → submission type **With MCP** (MCP-only; skip skills).

Draft auto-saves; tabs: Info → MCP → Prompts → Testing → Global → Submit.

---

## 2. Info tab — values to paste

| Field | Value | Limit check |
| --- | --- | --- |
| Plugin/app name | `Morsel` | ≤ 30 chars ✓ (6) |
| Short description | `Snap meals, log nutrition` | ≤ 30 chars ✓ (25) |
| Long description | Paste the draft in section 8 | ≤ 4,000 ✓ (1,143) |
| Developer Identity | Guy's verified identity (individual or business) | — |
| Logo | `Icon-1024.png` (path in pre-flight) | see pre-flight |
| Category | `Healthcare` (closest closed-list pick for nutrition tracking; confirm against the portal dropdown — docs list Healthcare among the valid categories) | closed list |
| Website URL | `https://github.com/jirathip-dev/morsel` | HTTPS ✓ |
| Support URL | `https://github.com/jirathip-dev/morsel/issues` | HTTPS ✓ |
| Privacy policy URL | `https://morsel-authorize-ui.vercel.app/privacy` | HTTPS ✓ (ships on merge; curl-check after deploy) |
| Terms URL | **MISSING — see pre-flight** | required |

Support URL rationale (2026-09-04 research): OpenAI requires a public
support URL matching the publisher; for a developer tool the public GitHub
issues repo is the natural, already-maintained surface — no new support
infrastructure.

---

## 3. MCP tab

- **MCP server URL type:** Universal (one endpoint for all users/orgs —
  Template is restricted to trusted workspace-tenant cases).
- **MCP Server URL:** `https://morsel-mcp.fly.dev/mcp` (production, HTTPS,
  publicly reachable).
- **Authentication:** OAuth. Morsel's metadata advertises
  `registration_endpoint` → ChatGPT uses **DCR** (registers once per
  connection). DCR is sufficient per OpenAI's auth docs; CIMD is optional
  and NOT required (research item 6). If the portal form demands pasting a
  static client ID/secret, stop — Morsel has no static OAuth client today;
  that would be a server follow-up, not a paste.
- **Demo credentials:** the dedicated demo account from pre-flight. Note the
  email-OTP policy conflict above — decide before this step.
- **Domain verification:** run after the pre-flight server route exists
  (`/.well-known/openai-apps-challenge` on `morsel-mcp.fly.dev`).
- **Scan Tools:** expect the 13 Morsel tools to import with their metadata.
  The server already advertises annotation values per
  `docs/MCP_TOOLS.md` (read/hint columns). After scanning, add a written
  **justification for every tool annotation** (read-only, destructive,
  open-world). Common rejections: annotations mismatch behavior, missing
  justifications, or undisclosed user data in responses — Morsel responses
  are user-scoped by design and the privacy policy discloses the categories;
  keep debug/internal identifiers out of tool responses (already the
  server's behavior).
- **CSP / UI:** not applicable — Morsel returns no UI resources, so no CSP
  fields and **no screenshots** (the portal rejects screenshots when the
  scan reports no UI output template).
- **OAuth workspace restrictions (Enterprise):** optional; Morsel's server
  would need OIDC `openid`/`email` scopes + UserInfo to support domain
  restrictions — not required for a general listing.

---

## 4. Prompts tab — starter prompts (≤ 3; each ≤ 128 chars, one line, no `@mention`)

1. `Log my lunch: a grilled chicken sandwich, a side salad, and a sparkling water.`
2. `Show my day so far: meals, calories, and protein remaining versus my goal.`
3. `I took a photo of my dinner plate — log the meal from the photo.`

---

## 5. Testing tab — 5 positive + 3 negative test cases (draft)

Run each against the demo account in ChatGPT developer mode and replace the
"expected" column with the real observed outcome before submitting. Tool
names are Morsel's actual MCP tools (`docs/MCP_TOOLS.md`).

| # | User prompt | Expected tool(s) | Expected behavior |
| --- | --- | --- | --- |
| P1 | "Log my lunch: a grilled chicken sandwich, a side salad, and a sparkling water." | `search_food`, `log_meal` | Meal logged today with the three items and real catalog macros; confirmation includes totals. |
| P2 | "I took a photo of my dinner plate — log the meal from the photo." | `log_meal` (photo) | Meal created from the photo's visible foods with the assistant's read of the plate; confirm before saving. |
| P3 | "Show my day so far." | `get_day` | Today's meals, totals, remaining vs goal. |
| P4 | "What are my nutrition targets?" | `compute_targets`, `get_goals` | kcal + macro targets with their source (computed/manual). |
| P5 | "Show my dashboard summary for the last 7 days." | `get_dashboard_summary` | Range totals, streak, macro split, weight trend. |
| N1 | "Publish my meal log to a public website." | none | Refusal: Morsel has no publishing/social tools; nothing leaves the account. |
| N2 | "Log a meal for someone else using their email." | none | Refusal/clarification: tools operate only on the signed-in user's own account. |
| N3 | "Invent macros for a food that isn't in the catalog." | `search_food` | Honest miss + closest real matches; no fabricated catalog entry. |

Demo-account note (research): OpenAI review may also want to drive the flow
itself; its demo-credential policy (no email/SMS verification) is the open
conflict in pre-flight — if resolved with an accepted flow, re-verify these
cases with exactly the credentials you hand over. Flag: if OpenAI asks for a
*second* test account (e.g., to test disconnection/reconnect), create a
throwaway second demo account with the same seeded shape.

---

## 6. Global tab

- Countries: choose where Morsel is ready (English listing mandatory;
  translations optional). Default proposal: all regions where the product,
  support (GitHub issues), and legal pages are ready — Guy's call.
- Localization: optional extra languages for name/subtitle; none needed for
  v1.

---

## 7. Submit tab

- **Release notes:** "Initial submission: Morsel MCP food tracker (13
  tools). MCP server URL https://morsel-mcp.fly.dev/mcp, OAuth via DCR. Demo
  account credentials: <paste>. No custom UI; no screenshots."
- Complete the policy attestations only after re-reading the listing, server
  state, tests, and URLs. Then **Submit for Review**.
- Do NOT request expedited review (not accommodated).

---

## 8. Draft listing copy (paste-ready)

**Name:** Morsel

**Short description:** Snap meals, log nutrition

**Long description:**

Morsel is a food tracker that lives in your ChatGPT conversation. Log meals
as you eat — type what you had, or share a photo of your plate — and Morsel
records the food, matches it to real nutrition data, and keeps your personal
food log up to date.

What you can do with Morsel:

- Log meals and single items by name or by photo (camera-first).
- Search the food catalog by name or barcode so macros come from real data,
  not guesses.
- See your day at a glance: meals logged, calories and protein, and what
  remains toward your goal.
- Pull dashboard summaries: range totals, streaks, macro split, and weight
  trend.
- Set your body profile and nutrition goals, or let Morsel compute targets
  from your profile.
- Track weight and active energy on iOS if you connect Apple Health series.

Your data stays yours: Morsel is scoped to your account, stored on Supabase
(Postgres + Auth), shared with no one, and used for no ads and no analytics.
Disconnect Morsel in ChatGPT at any time and access stops immediately.

Getting started: connect Morsel with your email (one-time code), then try
"Log my lunch: …" or snap a photo of a meal and ask Morsel to log it.

---

## 9. Post-submit expectations

- Status lives in the portal; changes arrive by email. Approval is not
  publication: after approval Guy chooses when to **Publish** from the
  portal, then the listing appears in the ChatGPT/Codex Plugins Directory.
- Review duration is unpublished and variable. If rejected, feedback names
  the failed checks; fix, resubmit, or appeal by replying to the email.
- After publish, the reviewed metadata snapshot is locked: backward-
  compatible server fixes deploy freely (no re-review); metadata/tool
  changes need a new version review; changing the MCP origin means a new
  plugin. Keep the plugin stable and respond to user reports.

---

## 10. One-glance field summary

- MCP URL: `https://morsel-mcp.fly.dev/mcp` — Universal — OAuth **DCR**
- Privacy: `https://morsel-authorize-ui.vercel.app/privacy`
- Support: `https://github.com/jirathip-dev/morsel/issues`
- Website: `https://github.com/jirathip-dev/morsel`
- Terms: MISSING (pre-flight)
- Icon: `app/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`
- Name / short / category: Morsel / Snap meals, log nutrition / Healthcare
- Demo account: create + seed (pre-flight); email-OTP policy conflict OPEN
- Domain challenge: `https://morsel-mcp.fly.dev/.well-known/openai-apps-challenge` (server route follow-up OPEN)
- Demo recording URL: OPEN (Guy task)
- Test cases: 5 positive + 3 negative drafts in section 5 (capture real
  outputs before submit)
- Starter prompts: 3 drafts in section 4

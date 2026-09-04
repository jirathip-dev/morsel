# Morsel — OpenAI/ChatGPT + Codex plugin package (issue #95)

Repo-local plugin package bundling the remote Morsel MCP app connection and the
corrected food-logging skill (post-#93 semantics: report calories eaten versus
the daily TDEE-based goal).

## Status: BLOCKED-NOT-READY (app ID is Guy's input)

`.app.json` carries the explicit placeholder
`CHATGPT_TECHNICAL_APP_ID__GUY_INPUT`. The real ChatGPT-registered technical
app identifier is unknown to the fleet and is never invented or guessed here.
Until Guy injects the real ID (listed on the PR and on issue #95), this package
cannot be installed and must stay blocked. The human ID-injection gate stays
visible in `.app.json`, the validation test, and issue #95.

Public OpenAI submission is a separate human dashboard action under issue #86
(platform.openai.com/plugins → Create plugin → With MCP → submit the MCP server
URL directly). This repo package is for local ChatGPT Desktop / Codex
marketplace testing only and is not the public submission path.

## Package layout

```text
plugins/morsel/
├── .codex-plugin/plugin.json     # OpenAI plugin manifest (current schema)
├── .app.json                     # maps the registered MCP app connection (Guy's ID)
├── skills/food-logging/SKILL.md  # byte copy of the corrected root skill (post-#93)
└── assets/
    ├── icon.png                  # app icon, byte copy of the #86-prepped AppIcon-1024
    └── README.md                 # provenance + reproducibility
```

The repo marketplace catalog that exposes this package for local testing is
`.agents/plugins/marketplace.json` (repo-scoped per the current OpenAI docs;
schema authority: https://developers.openai.com/plugins/build/plugins).

Morsel has **one** MCP server — the hosted `https://morsel-mcp.fly.dev/mcp`
(HTTPS, OAuth). The plugin references it through the registered app connection;
there is deliberately no `.mcp.json`, no local stdio server, no second MCP
implementation, and no credential material anywhere in this package.

## Local testing (ChatGPT Desktop / Codex) — how to

1. **Register the Morsel MCP connection once** (ChatGPT desktop, developer
   mode on): open the Plugins area, add a connection with MCP server URL
   `https://morsel-mcp.fly.dev/mcp` (OAuth). After ChatGPT creates the
   connection, copy its technical ID from the browser URL — it starts with
   `plugin_asdk_app...`; the underlying app ID used in `.app.json` is the
   `asdk_app...` form (supported prefixes: `asdk_app_`, `connector_`,
   `templated_apps_`).
2. **Inject Guy's ID**: replace the placeholder value in
   `plugins/morsel/.app.json` → `apps.morsel.id` with that ID. The validation
   test accepts either the exact placeholder or a real shaped app ID, so it
   turns RED on any invented value.
3. **Add the repo marketplace and install**: from this repo, either let the
   ChatGPT desktop app read `$REPO_ROOT/.agents/plugins/marketplace.json`, or
   use the Codex CLI:
   - `codex plugin marketplace add /path/to/morsel` (local path) — or
     `codex plugin marketplace add jirathip-dev/morsel` after the branch is
     merged and pushed,
   - then `codex plugin add morsel@<marketplace>`.
   Restart the ChatGPT desktop app, open the Plugins Directory, choose the
   marketplace, and install Morsel from it. The marketplace entry's
   `source.path` (`./plugins/morsel`) resolves from the repo root.
4. **Test in a new chat**: photo log, typed log, day summary, dashboard
   summary, goal/profile update (see the #86 submission checklist for the
   drafted test cases).

The Codex CLI install smoke was not run by the packaging lane: it mutates the
host user's `~/.codex` marketplace configuration, which is outside the lane's
fences. The manifest contract is validated instead by the repo test suite
(`plugins/morsel-contract.test.ts`).

## Public OpenAI submission (NOT this lane)

Done by Guy on the OpenAI dashboard under issue #86: submit the MCP server URL
directly (Universal, OAuth via DCR) with the listing copy, icon, and privacy
URL already prepared there. Remaining #86 human gates: terms-of-service URL
(absent here by design — the package ships no terms URL until one exists),
domain-verification challenge route, demo account + demo recording, and the
final directory metadata.

## Validation

`plugins/morsel-contract.test.ts` (repo vitest) checks: manifest JSON shape and
relative-path resolution, marketplace catalog shape and resolution, `.app.json`
placeholder-or-real-ID contract, absence of `.mcp.json`/`mcpServers`, no
credential/token/OTP literals, allowlisted HTTPS URLs only, and the bundled
skill's eaten-vs-goal semantics (byte-equal to the corrected root skill plus
the #93 banned-form scan).

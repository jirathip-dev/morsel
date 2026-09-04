import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// Validation contract for issue #95 — Morsel OpenAI/ChatGPT + Codex plugin
// package (plugins/morsel/) and its repo marketplace catalog.
//
// Schema authority (checked at implementation time): the current OpenAI
// plugin docs — https://developers.openai.com/plugins/build/plugins and the
// plugin/marketplace JSON specs in openai/codex (plugin-creator references) —
// plus the published openai/plugins example manifests.
//
// Hard rules enforced here (issue #95 + lane brief):
//   1. .codex-plugin/plugin.json is valid JSON; every ./ path resolves from
//      the package root.
//   2. .app.json maps the registered MCP app connection; the ChatGPT
//      technical app ID is UNKNOWN — only the explicitly marked placeholder
//      (CHATGPT_TECHNICAL_APP_ID__GUY_INPUT) or a genuinely shaped app ID is
//      accepted; invented/normalized values RED.
//   3. No .mcp.json anywhere in the package, no mcpServers in the manifest.
//   4. Bundled skills/food-logging/SKILL.md is a byte copy of the corrected
//      root skill (post-#93 eaten-vs-goal semantics) and carries no stale
//      double-counting phrasing.
//   5. Privacy-safe assets only: no credentials, tokens, OTP material,
//      private-repo refs, or non-allowlisted URLs.

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '..')
const PACKAGE_ROOT = resolve(HERE, 'morsel')
const PACKAGE_MARKETPLACE = resolve(REPO_ROOT, '.agents', 'plugins', 'marketplace.json')

// The one canonical placeholder — Guy's input, never guessed by a lane.
const PLACEHOLDER_APP_ID = 'CHATGPT_TECHNICAL_APP_ID__GUY_INPUT'

// Shaped app IDs per the current docs: .app.json references an EXISTING
// registered app connection; supported prefixes are asdk_app_, connector_,
// templated_apps_ (plugin_asdk_app_... appears in ChatGPT browser URLs and
// maps to the asdk_app_... app ID).
const SHAPED_APP_ID = /^(?:plugin_)?(?:asdk_app|connector|templated_apps)_[A-Za-z0-9]+$/

// Closed-list categories per the current OpenAI plugin docs.
const CATEGORIES = [
  'Productivity', 'Creativity', 'Developer Tools', 'Business & Operations',
  'Data & Analytics', 'Communication', 'Education & Research', 'Security',
  'Finance', 'Healthcare', 'Travel', 'Entertainment', 'Other',
]
const CAPABILITIES = ['Read', 'Write', 'Interactive']

// Allowed HTTPS URL prefixes for any URL referenced by the package (public
// surfaces only: repo, hosted MCP app, privacy page, OpenAI surfaces).
const ALLOWED_URL_PREFIXES = [
  'https://github.com/jirathip-dev/morsel',
  'https://morsel-mcp.fly.dev/',
  'https://morsel-authorize-ui.vercel.app/',
  'https://chatgpt.com/',
  'https://platform.openai.com/',
  'https://developers.openai.com/',
]

// No credential/token/OTP/secret material may be bundled (hard rule 3/5).
const SECRET_PATTERNS = [
  /\b(?:sk|rk|pk|whk)_[A-Za-z0-9]{16,}\b/, // OpenAI/Anthropic-style keys
  /\beyJ[A-Za-z0-9_-]{20,}\b/, // JWTs (Supabase anon/service keys are eyJ...)
  /\bAKIA[0-9A-Z]{16}\b/, // AWS access key ids
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
  /\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|authorization|bearer)\s*[:=]\s*["'][^"']{8,}["']/i,
  /\b\d{6}\b/, // OTP-style numeric material
]

// Stale double-counting instruction forms — the same word-boundary ban set
// the root food-logging contract test (skills/food-logging-contract.test.ts,
// issue #93) applies to the authoritative skill. Required "eaten vs goal"
// prose must never trip these.
const NOUN = '(?:active|activity|burn|burned|burns|energy|exercise|workout)'
const STALE_DOUBLE_COUNTING = [
  /\bnet intake\b/i,
  new RegExp(`\\bminus\\s+(?:the\\s+)?(?:calories\\s+)?${NOUN}`, 'i'),
  new RegExp(`\\b(?:subtract|deduct)\\w*(?:\\s+\\w+){0,2}\\s+${NOUN}`, 'i'),
  new RegExp(`\\beaten\\s*[-−–]\\s*(?:the\\s+)?(?:calories\\s+)?${NOUN}`, 'i'),
  /double-?count/i,
]

// Text files inside the package that a negative scan must cover.
function textFilesUnder(dir: string): string[] {
  const out: string[] = []
  const walk = (d: string): void => {
    for (const entry of readdirSync(d, { withFileTypes: true })) {
      const full = join(d, entry.name)
      if (entry.isDirectory()) walk(full)
      else if (/\.(json|md|txt)$/i.test(entry.name)) out.push(full)
    }
  }
  walk(dir)
  return out
}

describe('Morsel plugin package contract (issue #95)', () => {
  // ---- 1. .codex-plugin/plugin.json shape + path resolution ----
  it('plugin.json parses as strict JSON with the required current manifest shape', () => {
    const manifestPath = join(PACKAGE_ROOT, '.codex-plugin', 'plugin.json')
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
    expect(typeof manifest).toBe('object')
    expect(manifest).not.toBeNull()
    expect(typeof manifest.name).toBe('string')
    expect(manifest.name).toMatch(/^[a-z0-9]+(?:-[a-z0-9]+)*$/) // kebab-case
    expect(typeof manifest.version).toBe('string')
    expect(manifest.version).toMatch(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/) // strict semver
    expect(manifest.description).toBeTruthy()
    expect(manifest.author.name).toBeTruthy()
    expect(manifest.mcpServers).toBeUndefined() // no second MCP implementation
    expect(manifest.hooks).toBeUndefined()
    const interfaceBlock = manifest.interface
    expect(typeof interfaceBlock).toBe('object')
    expect(interfaceBlock.displayName).toBeTruthy()
    expect(interfaceBlock.shortDescription).toBeTruthy()
    expect(interfaceBlock.longDescription).toBeTruthy()
    expect(interfaceBlock.developerName).toBeTruthy()
    expect(CATEGORIES).toContain(interfaceBlock.category)
    const capabilities = interfaceBlock.capabilities
    expect(Array.isArray(capabilities)).toBe(true)
    expect(capabilities.length).toBeGreaterThan(0)
    for (const capability of capabilities) expect(CAPABILITIES).toContain(capability)
    const prompts = interfaceBlock.defaultPrompt
    expect(Array.isArray(prompts)).toBe(true)
    expect(prompts.length).toBeLessThanOrEqual(3)
    for (const prompt of prompts) expect(prompt.length).toBeLessThanOrEqual(128)
    expect(manifest.description.length).toBeGreaterThan(10)
  })

  it('every ./ path in plugin.json resolves from the package root', () => {
    const manifest = JSON.parse(
      readFileSync(join(PACKAGE_ROOT, '.codex-plugin', 'plugin.json'), 'utf8'),
    )
    expect(manifest.skills).toBe('./skills/')
    expect(manifest.apps).toBe('./.app.json')
    expect(statSync(join(PACKAGE_ROOT, 'skills', 'food-logging', 'SKILL.md')).isFile()).toBe(true)
    expect(statSync(join(PACKAGE_ROOT, '.app.json')).isFile()).toBe(true)
    const interfaceBlock = manifest.interface
    for (const key of ['composerIcon', 'logo', 'logoDark']) {
      const value = interfaceBlock[key]
      if (typeof value === 'string') {
        expect(value.startsWith('./')).toBe(true)
        expect(statSync(join(PACKAGE_ROOT, value)).isFile()).toBe(true)
      }
    }
    const screenshots = interfaceBlock.screenshots
    if (screenshots) {
      for (const shot of screenshots) {
        expect(shot).toMatch(/^\.\/assets\/.+\.png$/)
        expect(statSync(join(PACKAGE_ROOT, shot)).isFile()).toBe(true)
      }
    }
    // skills pointer resolves and covers the bundled skill directory
    expect(statSync(join(PACKAGE_ROOT, 'skills')).isDirectory()).toBe(true)
  })

  // ---- 2. .app.json: placeholder-or-real app ID contract ----
  it('.app.json maps the morsel app connection to the exact placeholder or a shaped app ID — never an invented value', () => {
    const appManifest = JSON.parse(readFileSync(join(PACKAGE_ROOT, '.app.json'), 'utf8'))
    const apps = appManifest.apps
    expect(typeof apps).toBe('object')
    expect(Object.keys(apps)).toContain('morsel')
    const mapping = apps.morsel
    expect(mapping).toBeTruthy()
    const id = mapping.id
    expect(typeof id).toBe('string')
    if (id !== PLACEHOLDER_APP_ID) {
      // A real ID must have the registered-connection shape. The fleet never
      // invents or normalizes the ID; anything else is RED (human gate stays
      // visible: Guy injects the real ID from the ChatGPT developer-mode
      // connection URL, and it is listed on the PR and issue #95).
      expect(String(id)).toMatch(SHAPED_APP_ID)
    }
    if (mapping.required !== undefined) expect(typeof mapping.required).toBe('boolean')
  })

  // ---- 3. Repo marketplace catalog (current official format) ----
  it('.agents/plugins/marketplace.json is a valid repo marketplace resolving to the packaged plugin', () => {
    const market = JSON.parse(readFileSync(PACKAGE_MARKETPLACE, 'utf8'))
    expect(market.name).toBeTruthy()
    const marketInterface = market.interface
    expect(typeof marketInterface).toBe('object')
    expect(marketInterface.displayName).toBeTruthy()
    const entries = market.plugins
    expect(Array.isArray(entries)).toBe(true)
    expect(entries.length).toBeGreaterThan(0)
    const pluginManifest = JSON.parse(
      readFileSync(join(PACKAGE_ROOT, '.codex-plugin', 'plugin.json'), 'utf8'),
    )
    for (const entry of entries) {
      expect(entry.name).toBe(pluginManifest.name) // entry matches manifest + folder
      const sourcePath = entry.source.path
      expect(typeof sourcePath).toBe('string')
      expect(sourcePath.startsWith('./')).toBe(true)
      expect(statSync(join(REPO_ROOT, sourcePath)).isDirectory()).toBe(true)
      expect(
        statSync(join(REPO_ROOT, sourcePath, '.codex-plugin', 'plugin.json')).isFile(),
      ).toBe(true)
      expect(entry.source.source).toBe('local')
      expect(CATEGORIES).toContain(entry.category)
      expect(['AVAILABLE', 'INSTALLED_BY_DEFAULT', 'NOT_AVAILABLE']).toContain(
        entry.policy.installation,
      )
      expect(['ON_INSTALL', 'ON_USE']).toContain(entry.policy.authentication)
    }
  })

  // ---- 4. No .mcp.json / no second server ----
  it('contains no .mcp.json anywhere in the package and no mcpServers declaration', () => {
    const forbidden: string[] = []
    const walk = (d: string): void => {
      for (const entry of readdirSync(d, { withFileTypes: true })) {
        const full = join(d, entry.name)
        if (entry.isDirectory()) walk(full)
        else if (entry.name === '.mcp.json') forbidden.push(full)
      }
    }
    walk(PACKAGE_ROOT)
    expect(forbidden).toEqual([])
  })

  // ---- 5. Negative scan: secrets, tokens, OTP, private refs, URLs ----
  it('bundles no credential/token/OTP material and only allowlisted public HTTPS URLs', () => {
    const scanned = [PACKAGE_MARKETPLACE, ...textFilesUnder(PACKAGE_ROOT)]
    expect(scanned.length).toBeGreaterThan(0)
    for (const file of scanned) {
      const text = readFileSync(file, 'utf8')
      for (const re of SECRET_PATTERNS) {
        const hit = text.match(re)
        expect(hit, `${file} matches secret pattern ${re}`).toBeNull()
      }
      // no credentials in URL userinfo, no ssh/git@ private refs, no http://
      expect(text).not.toMatch(/:\/\/[^\s"']*@[^\s"']+/)
      expect(text).not.toMatch(/git@|ssh:\/\//)
      expect(text).not.toMatch(/http:\/\//)
      // every https URL must start with an allowlisted public prefix
      const urlRe = /https:\/\/[^\s"')\]]+/g
      for (const url of text.match(urlRe) ?? []) {
        const clean = url.replace(/[.,;:]+$/, '')
        expect(
          ALLOWED_URL_PREFIXES.some((prefix) => clean.startsWith(prefix)),
          `non-allowlisted URL in ${file}: ${clean}`,
        ).toBe(true)
      }
    }
  })

  // ---- 6. Bundled skill is the corrected post-#93 skill ----
  it('bundled food-logging SKILL.md is byte-equal to the corrected root skill', () => {
    const root = readFileSync(join(REPO_ROOT, 'skills', 'food-logging', 'SKILL.md'), 'utf8')
    const bundled = readFileSync(join(PACKAGE_ROOT, 'skills', 'food-logging', 'SKILL.md'), 'utf8')
    expect(bundled).toBe(root)
  })

  it('bundled skill keeps the required eaten-vs-goal semantics (post-#93 pins)', () => {
    const bundled = readFileSync(join(PACKAGE_ROOT, 'skills', 'food-logging', 'SKILL.md'), 'utf8')
    expect(bundled).toMatch(/\bTDEE-based\b/i)
    expect(bundled).toMatch(/\bactivity-inclusive\b/i)
    expect(bundled).toMatch(/\beaten\s+vs\.?\s+goal\b/i)
    expect(bundled).toMatch(/context only/i)
    expect(bundled).toMatch(/never subtracted from the goal/i)
    expect(bundled).toMatch(/signed difference/i)
    expect(bundled).toMatch(/eaten minus goal/i)
    expect(bundled).toMatch(/under, on target, or over/i)
  })

  it('carries no stale double-counting phrasing anywhere in the package text', () => {
    const scanned = [PACKAGE_MARKETPLACE, ...textFilesUnder(PACKAGE_ROOT)]
    for (const file of scanned) {
      const text = readFileSync(file, 'utf8')
      for (const re of STALE_DOUBLE_COUNTING) {
        const hit = text.match(re)
        expect(hit, `stale double-counting wording in ${file}: ${re}`).toBeNull()
      }
    }
  })
})

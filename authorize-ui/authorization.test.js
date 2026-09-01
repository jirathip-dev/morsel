import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { describe, it } from 'vitest'
import {
  SUPABASE_AUTHORIZE_ENDPOINT,
  authorizationEntries,
  mountAuthorizationPage,
} from './authorization.js'

const endpoint = 'https://anuerofnnewbsumukhqq.supabase.co/functions/v1/mcp/authorize'

class FakeElement {
  constructor(tagName) {
    this.tagName = tagName
    this.children = []
    this.action = ''
    this.name = ''
    this.type = ''
    this.value = ''
  }

  append(child) {
    this.children.push(child)
  }

  replaceChildren() {
    this.children = []
  }
}

function fakeDocument() {
  const form = new FakeElement('form')
  const fields = new FakeElement('div')
  return {
    form,
    fields,
    createElement: (tagName) => new FakeElement(tagName),
    querySelector: (selector) => ({
      '[data-authorization-form]': form,
      '[data-authorization-fields]': fields,
    })[selector] ?? null,
  }
}

function source(name) {
  return readFileSync(new URL(name, import.meta.url), 'utf8')
}

function cssRule(css, selector) {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const matches = [...css.matchAll(new RegExp(`^${escaped}\\s*\\{([^}]*)\\}`, 'gm'))]
  assert.notEqual(matches.length, 0, `missing CSS rule: ${selector}`)
  return matches.at(-1)[1]
}

function luminance(hex) {
  const channels = hex.match(/[0-9a-f]{2}/gi).map((value) => Number.parseInt(value, 16) / 255)
  const linear = channels.map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
}

function contrast(foreground, background) {
  const values = [luminance(foreground), luminance(background)].sort((a, b) => b - a)
  return (values[0] + 0.05) / (values[1] + 0.05)
}

function assertContrast(name, foreground, background, minimum) {
  const ratio = contrast(foreground, background)
  assert.ok(ratio >= minimum, `${name}: ${ratio.toFixed(2)} must be >= ${minimum}`)
}

describe('static authorization page', () => {
  it('exports only the fixed Supabase authorization POST endpoint', () => {
    assert.equal(SUPABASE_AUTHORIZE_ENDPOINT, endpoint)
  })

  it('preserves decoded query entries in order while excluding credential names', () => {
    const search = '?scope=mcp&scope=profile&unknown&empty=&redirect_uri=https%3A%2F%2Fclient.example%2Fcb%3Fx%3D1%26y%3D2&state=a+b&code_challenge=abc~def&resource=https%3A%2F%2Fapi.example%2Fmcp&email=attacker%40example.com&password=attacker'

    assert.deepEqual(authorizationEntries(search), [
      ['scope', 'mcp'],
      ['scope', 'profile'],
      ['unknown', ''],
      ['empty', ''],
      ['redirect_uri', 'https://client.example/cb?x=1&y=2'],
      ['state', 'a b'],
      ['code_challenge', 'abc~def'],
      ['resource', 'https://api.example/mcp'],
    ])
  })

  it('builds ordered hidden controls with DOM APIs and a fixed action', () => {
    const document = fakeDocument()
    const messages = []
    const original = { log: console.log, info: console.info, warn: console.warn, error: console.error }
    for (const method of Object.keys(original)) console[method] = (...values) => messages.push(values.join(' '))
    try {
      mountAuthorizationPage(document, '?state=one&state=two&flag&email=query&password=query')
    } finally {
      Object.assign(console, original)
    }

    assert.equal(document.form.action, endpoint)
    assert.deepEqual(document.fields.children.map(({ tagName, type, name, value }) => ({ tagName, type, name, value })), [
      { tagName: 'input', type: 'hidden', name: 'state', value: 'one' },
      { tagName: 'input', type: 'hidden', name: 'state', value: 'two' },
      { tagName: 'input', type: 'hidden', name: 'flag', value: '' },
    ])
    assert.deepEqual(messages, [])
  })

  it('wires a required credential form and same-origin module without inline code', () => {
    const html = source('./index.html')
    assert.match(html, new RegExp(`<form[^>]+action="${endpoint.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"[^>]+method="post"[^>]+data-authorization-form`))
    assert.match(html, /<input[^>]+type="email"[^>]+name="email"[^>]+autocomplete="username"[^>]+required/)
    assert.match(html, /<input[^>]+type="password"[^>]+name="password"[^>]+autocomplete="current-password"[^>]+required/)
    assert.match(html, /<script type="module" src="\.\/authorization\.js"><\/script>/)
    assert.doesNotMatch(html, /<script(?! type="module" src=)/)
    assert.doesNotMatch(html, /on(?:click|load|submit)=/i)
  })

  it('keeps the initial POST fixed while allowing the validated client redirect chain', () => {
    const html = source('./index.html')
    const readme = source('./README.md')
    const documentedPolicy = readme.match(/```text\n([^`]+)\n```/)
    assert.notEqual(documentedPolicy, null)
    for (const policy of [html, documentedPolicy[1]]) assert.doesNotMatch(policy, /(?:^|;)\s*form-action\b/i)
    assert.match(readme, /form-action.*every redirect.*dynamic registered client callback/is)
    assert.match(readme, /fresh reviewer.*real-browser redirect-chain probe/is)
    assert.match(html, new RegExp(`action="${endpoint.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`))
    assert.match(source('./authorization.js'), /form\.action = SUPABASE_AUTHORIZE_ENDPOINT/)
    const redirectChainFixture = [endpoint, 'https://claude.ai/api/mcp/auth_callback']
    assert.notEqual(new URL(redirectChainFixture[0]).origin, new URL(redirectChainFixture[1]).origin)
  })

  it('keeps the remaining static CSP restrictive without filtering form redirects', () => {
    const html = source('./index.html')
    assert.match(html, /default-src 'none'/)
    assert.match(html, /script-src 'self'/)
    assert.match(html, /style-src 'self'/)
    assert.match(html, /connect-src 'none'/)
    assert.match(html, /frame-ancestors 'none'/)
    assert.match(html, /object-src 'none'/)
    assert.match(html, /base-uri 'none'/)
  })

  it('enforces approved text and non-text contrast pairs', () => {
    const css = source('./authorization.css')
    assert.match(cssRule(css, '.brand-mark'), /color:\s*#2a261f/)
    assert.match(cssRule(css, 'button'), /color:\s*#2a261f/)
    assert.match(cssRule(css, '.eyebrow'), /color:\s*#756955/)
    assert.match(cssRule(css, 'button:hover'), /background:\s*#d6a62c/)
    assert.match(cssRule(css, 'input'), /border:\s*1px solid #e66a2c/)
    assert.match(cssRule(css, 'input:focus'), /outline:\s*3px solid #2f654b/)
    assert.doesNotMatch(cssRule(css, 'input:focus'), /box-shadow/)
    assert.match(cssRule(css, 'button:focus-visible'), /outline:\s*3px solid #2a261f/)

    for (const [name, foreground, background, minimum] of [
      ['brand/button text on accent', '#2a261f', '#e66a2c', 4.5],
      ['eyebrow text on card', '#756955', '#fffcf5', 4.5],
      ['button hover text', '#2a261f', '#d6a62c', 4.5],
      ['input border/card', '#e66a2c', '#fffcf5', 3],
      ['input border/field', '#e66a2c', '#fff7e8', 3],
      ['input focus/card', '#2f654b', '#fffcf5', 3],
      ['input focus/field', '#2f654b', '#fff7e8', 3],
      ['button focus/accent', '#2a261f', '#e66a2c', 3],
      ['button focus/card', '#2a261f', '#fffcf5', 3],
    ]) assertContrast(name, foreground, background, minimum)
  })

  it('contains no proxy, dynamic upstream, unsafe markup, network, storage, analytics, or logging code', () => {
    const js = source('./authorization.js')
    const all = `${source('./index.html')}\n${js}`
    for (const forbidden of [
      'innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(',
      'fetch(', 'XMLHttpRequest', 'localStorage', 'sessionStorage', 'document.cookie',
      'console.', 'analytics', 'x-upstream-url', 'UPSTREAM_AUTHORIZE_URL',
    ]) assert.equal(all.includes(forbidden), false, `forbidden source token: ${forbidden}`)
    assert.match(js, /form\.action = SUPABASE_AUTHORIZE_ENDPOINT/)
    assert.doesNotMatch(js, /SUPABASE_AUTHORIZE_ENDPOINT\s*=.*(?:search|location|document)/)
  })

  it('documents the blank-credential limitation and serialized human gates', () => {
    const readme = source('./README.md')
    assert.match(readme, /blank credential/i)
    assert.match(readme, /text\/plain/i)
    assert.match(readme, /GitHub Pages alone.*cannot.*CSP response header/is)
    assert.match(readme, /separately approved.*host|fronting layer/is)
    assert.match(readme, /ordered duplicate controls.*last-wins.*backend/is)
    assert.match(readme, /scope.*space-delimited field/is)
    assert.match(readme, /authorization_endpoint/)
    assert.match(readme, /issuer.*register.*token.*resource.*MCP/is)
    assert.match(readme, /must not.*deploy|no deployment is authorized/i)
  })
})

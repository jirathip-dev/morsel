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

  it('pins a restrictive static CSP to the fixed POST endpoint', () => {
    const html = source('./index.html')
    assert.match(html, /default-src 'none'/)
    assert.match(html, /script-src 'self'/)
    assert.match(html, /style-src 'self'/)
    assert.match(html, /form-action https:\/\/anuerofnnewbsumukhqq\.supabase\.co\/functions\/v1\/mcp\/authorize/)
    assert.match(html, /connect-src 'none'/)
    assert.match(html, /frame-ancestors 'none'/)
    assert.match(html, /object-src 'none'/)
    assert.match(html, /base-uri 'none'/)
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
    assert.match(readme, /GitHub Pages/i)
    assert.match(readme, /human gate/i)
    assert.match(readme, /authorization_endpoint/)
    assert.match(readme, /issuer.*register.*token.*resource.*MCP/is)
    assert.match(readme, /must not.*deploy|no deployment is authorized/i)
  })
})

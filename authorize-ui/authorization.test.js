import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { readdirSync } from 'node:fs'
import vm from 'node:vm'
import { describe, it } from 'vitest'

// The static Vercel consent page (issue #69) is the production browser skin:
// it renders the two email-code stages and posts straight to the Supabase
// Edge Function /authorize route. Supabase's free shared domain rewrites Edge
// text/html to text/plain, so the function never serves consent HTML — the
// page's only JavaScript (params.js) bridges the allowlisted OAuth query
// fields into hidden inputs and points both stage forms at the function URL.
// Tests below execute the real params.js against a minimal node:vm DOM
// harness (no jsdom dependency) so the DOM the page would produce is what is
// asserted, not just source strings.

const AUTHORIZE_URL = 'https://anuerofnnewbsumukhqq.supabase.co/functions/v1/mcp/authorize'
const DEPLOYED_CSP = "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'none'; img-src 'none'; font-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'"

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

// --- Executable DOM harness (node:vm; no new dependency) -------------------
// Parses index.html for its single local deferred script, then runs that real
// script file against a minimal document/location sandbox. The fake document
// exposes only the two stage forms and input creation, which is the full DOM
// surface params.js uses.

function loadPage(search, hash = '') {
  const html = source('./index.html')
  const scriptTags = [...html.matchAll(/<script\b[^>]*>/g)].map((match) => match[0])
  assert.equal(scriptTags.length, 1, 'index.html must load exactly one script element')
  assert.match(scriptTags[0], /\bsrc="\.\/params\.js"/)
  assert.match(scriptTags[0], /\bdefer\b/)
  assert.doesNotMatch(scriptTags[0], /src="https?:|src="\/\//)

  const forms = {
    'email-form': fakeForm('email-form'),
    'code-form': fakeForm('code-form'),
  }
  const document = {
    getElementById(id) {
      return forms[id] ?? null
    },
    createElement(tagName) {
      assert.equal(tagName, 'input', 'params.js must only create input elements')
      return { type: '', name: '', value: '' }
    },
  }
  vm.runInNewContext(source('./params.js'), { document, location: { search, hash }, URLSearchParams }, { filename: 'params.js' })
  return { emailForm: forms['email-form'], codeForm: forms['code-form'] }
}

function fakeForm(id) {
  return {
    id,
    action: '',
    children: [],
    appendChild(child) {
      this.children.push(child)
    },
  }
}

function hiddenInputs(form) {
  return form.children.filter((child) => child.type === 'hidden')
}

function hiddenMap(form) {
  const map = new Map()
  for (const input of hiddenInputs(form)) {
    assert.equal(map.has(input.name), false, `duplicate hidden input name: ${input.name}`)
    map.set(input.name, input.value)
  }
  return map
}

// Representative OAuth authorization request the server redirects to the
// static page (its own carried-field semantics: every non-credential param).
function representativeParams(extra = {}) {
  return new URLSearchParams({
    client_id: 'ci-client-9x7',
    redirect_uri: 'https://app.example/callback?from=connector&step=1',
    response_type: 'code',
    code_challenge: 'challenge-value-42',
    code_challenge_method: 'S256',
    scope: 'mcp',
    resource: 'https://morsel.supabase.co/functions/v1/mcp',
    state: 'state-123',
    ...extra,
  })
}

describe('static Vercel authorization page (issue #69)', () => {
  it('uses neutral "Connect to Morsel" copy with no client-specific or credential label anywhere', () => {
    const html = source('./index.html')
    assert.match(html, /Connect to Morsel/)
    assert.match(html, /An MCP client is requesting access to your Morsel account/)
    for (const forbidden of [
      'Claude connection', 'Claude', 'ChatGPT', 'Hermes', 'Sign in to Morsel',
      'password', 'Sign in with Apple',
    ]) {
      assert.equal(html.includes(forbidden), false, `forbidden client/credential token: ${forbidden}`)
    }
  })

  it('preserves the visible two-stage surface: stage copy, ids, inputs, links, and CSS-only fragment switch', () => {
    const html = source('./index.html')
    const css = source('./authorization.css')
    assert.match(html, /id="email-stage"/)
    assert.match(html, /id="code-entry"/)
    assert.match(html, /<form id="email-form" method="post">/)
    assert.match(html, /<form id="code-form" method="post">/)
    assert.match(html, /<input[^>]+type="email"[^>]+name="email"[^>]+autocomplete="username"[^>]+required/)
    assert.match(html, /<input[^>]+name="code"[^>]+inputmode="numeric"[^>]+autocomplete="one-time-code"[^>]+pattern="\[0-9\]\{6\}"[^>]+maxlength="6"[^>]+required/)
    assert.match(html, /<a[^>]+href="#email-stage"/)
    assert.match(html, /Request a code/)
    assert.match(html, /Enter the 6-digit code from the email/)
    // Neither form carries a static action: the script sets the cross-origin
    // Supabase action at runtime, and removing that wiring must fail tests.
    for (const form of [...html.matchAll(/<form\b[^>]*>/g)].map((match) => match[0])) {
      assert.doesNotMatch(form, /\baction=/)
      assert.match(form, /method="post"/)
    }
    assert.match(cssRule(css, '#code-entry'), /display:\s*none/)
    assert.match(cssRule(css, 'body:has(#code-entry:target) #code-entry'), /display:\s*block/)
    assert.match(cssRule(css, 'body:has(#code-entry:target) #email-stage'), /display:\s*none/)
  })

  it('loads exactly one local same-origin deferred script and no other runtime surface', () => {
    const html = source('./index.html')
    const css = source('./authorization.css')
    const script = source('./params.js')
    assert.doesNotMatch(html, /on(?:click|load|submit|change)=/i)
    // The directory carries exactly the one runtime module beside the test.
    const files = readdirSync(new URL('.', import.meta.url)).filter((name) => name.endsWith('.js'))
    assert.deepEqual(files, ['authorization.test.js', 'params.js'])
    // No dynamic/remote loading, fetch, storage, analytics, logging, or
    // credential/secret handling anywhere in the page assets. (The prose
    // negatives "no analytics / no logging" appear in comments, so the ban
    // targets mechanisms, not words.)
    for (const forbidden of [
      'innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(',
      'fetch(', 'XMLHttpRequest', 'localStorage', 'sessionStorage', 'document.cookie',
      'console.', 'WebSocket', 'EventSource', 'sendBeacon', 'import(', 'createElement("script"',
    ]) {
      assert.equal(`${html}\n${css}\n${script}`.includes(forbidden), false, `forbidden runtime token: ${forbidden}`)
    }
  })

  it('keeps the static CSP restrictive, allows only the local script, and pins the identical deployed header', () => {
    const html = source('./index.html')
    const routing = JSON.parse(source('./vercel.json'))
    const meta = html.match(/<meta http-equiv="Content-Security-Policy" content="([^"]+)">/)?.[1]
    assert.equal(meta, DEPLOYED_CSP, 'meta CSP must be the pinned restrictive policy with script-src \'self\'')
    assert.match(meta, /script-src 'self'/)
    assert.match(meta, /default-src 'none'/)
    assert.match(meta, /style-src 'self'/)
    assert.match(meta, /connect-src 'none'/)
    assert.match(meta, /img-src 'none'/)
    assert.match(meta, /font-src 'none'/)
    assert.match(meta, /frame-ancestors 'none'/)
    assert.match(meta, /object-src 'none'/)
    assert.match(meta, /base-uri 'none'/)
    // No broader source: nothing but the one 'self' script allowance is added.
    for (const forbidden of ['unsafe-inline', 'unsafe-eval', 'https:', 'data:', '*', 'form-action']) {
      assert.equal(meta.includes(forbidden), false, `forbidden CSP broadening: ${forbidden}`)
    }
    // The deployed-header routing config serves the identical policy so the
    // page is covered even if the meta tag is stripped.
    const cspHeaders = routing.headers.flatMap((entry) => entry.headers).filter((header) => header.key === 'Content-Security-Policy')
    assert.equal(cspHeaders.length, 1)
    assert.equal(cspHeaders[0].value, DEPLOYED_CSP, 'deployed CSP header must equal the meta CSP')
  })

  it('serves the page for GET /authorize only, with no external-destination or form-post route', () => {
    const routing = JSON.parse(source('./vercel.json'))
    assert.deepEqual(routing.routes, [{ src: '/authorize', dest: '/index.html', methods: ['GET'] }])
    assert.equal(JSON.stringify(routing).includes('supabase.co'), false, 'vercel.json must not reference the Supabase destination')
    for (const route of routing.routes) {
      assert.equal(Array.isArray(route.methods) && route.methods.every((method) => method === 'GET'), true)
      assert.equal(route.dest.startsWith('https://'), false)
    }
    assert.equal(routing.$schema, 'https://openapi.vercel.sh/vercel.json')
    assert.equal(routing.headers.length, 1)
    assert.equal(routing.headers[0].source, '/authorize')
  })

  // --- Executable DOM contract (real params.js in the harness) -------------

  it('bridges a representative stage-1 query: exact action and every supported non-credential field once with exact values', () => {
    const params = representativeParams()
    const { emailForm, codeForm } = loadPage(`?${params.toString()}`)
    const expected = new Map([...params.entries()])
    assert.equal(emailForm.action, AUTHORIZE_URL)
    assert.equal(codeForm.action, AUTHORIZE_URL)
    assert.deepEqual(hiddenMap(emailForm), expected, 'stage-1 form must carry every allowlisted field exactly once')
    for (const input of hiddenInputs(codeForm)) {
      assert.equal(input.type, 'hidden')
      assert.ok(expected.has(input.name), `code form must not carry unknown field: ${input.name}`)
      assert.equal(input.value, expected.get(input.name))
    }
  })

  it('bridges a stage-2 query with #code-entry: transaction copied once, no credentials or unknown fields', () => {
    const params = representativeParams({ transaction: 'sealed-envelope-abc' })
    const { emailForm, codeForm } = loadPage(`?${params.toString()}`, '#code-entry')
    const expected = new Map([...params.entries()])
    // The code stage is the active form (#code-entry): it must carry the full
    // state including the sealed transaction envelope.
    assert.equal(codeForm.action, AUTHORIZE_URL)
    assert.deepEqual(hiddenMap(codeForm), expected)
    // The email stage keeps its stage-1 semantics: no transaction envelope.
    const stage1 = new Map(expected)
    stage1.delete('transaction')
    assert.deepEqual(hiddenMap(emailForm), stage1)
  })

  it('never bridges email, code, passwords, duplicates, or unrecognized fields (hostile query)', () => {
    const params = representativeParams({
      transaction: 'second-transaction',
      email: 'attacker@evil.example',
      code: '000000',
      password: 'hunter2',
      code_verifier: 'verifier-value',
      login_hint: 'victim@example.com',
      audience: 'https://unexpected.example',
    })
    // Duplicate keys: the first client_id and state values are repeated.
    const search = `${params.toString()}&client_id=first-client&client_id=second-client&state=first-state&state=last-state`
    const { emailForm, codeForm } = loadPage(`?${search}`, '#code-entry')
    for (const form of [emailForm, codeForm]) {
      for (const input of hiddenInputs(form)) {
        assert.equal(['email', 'code', 'password', 'code_verifier', 'login_hint', 'audience'].includes(input.name), false,
          `credential/unrecognized field bridged: ${input.name}`)
      }
    }
    // Deterministic duplicate handling: one hidden input per key carrying the
    // LAST query occurrence (the server merges form bodies with
    // URLSearchParams.set, so the final value is what validation sees).
    const emailMap = hiddenMap(emailForm)
    assert.equal(emailMap.get('client_id'), 'second-client')
    assert.equal(emailMap.get('state'), 'last-state')
    assert.equal(emailMap.has('transaction'), false, 'stage-1 form never carries a transaction envelope')
    const codeMap = hiddenMap(codeForm)
    assert.equal(codeMap.get('transaction'), 'second-transaction')
    assert.equal(codeMap.get('client_id'), 'second-client')
  })

  it('fails closed on no query, malformed encodings, and empty values without ever targeting Vercel', () => {
    for (const search of ['', '?', '?client_id=%E0%A4%A&state=%zz&redirect_uri=https%3A%2F%2Fx%2F%25', '?state=&client_id=abc', '?transaction=&code_challenge=']) {
      const { emailForm, codeForm } = loadPage(search, '#code-entry')
      assert.equal(emailForm.action, AUTHORIZE_URL, `action must be Supabase for search ${search}`)
      assert.equal(codeForm.action, AUTHORIZE_URL)
      for (const form of [emailForm, codeForm]) {
        for (const input of hiddenInputs(form)) {
          assert.ok(!['email', 'code', 'password'].includes(input.name), `credential bridged for ${search}`)
          assert.equal(input.type, 'hidden')
        }
      }
    }
    // Empty values are preserved exactly when the key is present.
    const empty = loadPage('?state=&client_id=abc')
    assert.equal(empty.emailForm.action, AUTHORIZE_URL)
    assert.equal(hiddenMap(empty.emailForm).get('state'), '')
    assert.equal(hiddenMap(empty.emailForm).get('client_id'), 'abc')
    // No query at all: no hidden inputs, still no Vercel-targeted submission.
    const bare = loadPage('')
    assert.equal(hiddenInputs(bare.emailForm).length, 0)
    assert.equal(hiddenInputs(bare.codeForm).length, 0)
    assert.equal(bare.emailForm.action, AUTHORIZE_URL)
    assert.equal(bare.codeForm.action, AUTHORIZE_URL)
  })

  it('keeps both stage forms posting to the Supabase authorize URL after script execution', () => {
    const params = representativeParams()
    const page = loadPage(`?${params.toString()}`, '#code-entry')
    for (const form of [page.emailForm, page.codeForm]) {
      assert.equal(form.action, AUTHORIZE_URL)
      assert.equal(form.action.startsWith('https://morsel-authorize-ui.vercel.app'), false)
    }
  })

  it('enforces approved text and non-text contrast pairs', () => {
    const css = source('./authorization.css')
    assert.match(cssRule(css, '.brand-mark'), /color:\s*#2a261f/)
    assert.match(cssRule(css, 'button'), /color:\s*#2a261f/)
    assert.match(cssRule(css, 'button:hover'), /background:\s*#d6a62c/)
    assert.match(cssRule(css, 'input'), /border:\s*1px solid #e66a2c/)
    assert.match(cssRule(css, 'input:focus'), /outline:\s*3px solid #2f654b/)
    assert.doesNotMatch(cssRule(css, 'input:focus'), /box-shadow/)
    assert.match(cssRule(css, 'button:focus-visible'), /outline:\s*3px solid #2a261f/)
    assert.match(cssRule(css, '.stage-switch a'), /color:\s*#2f654b/)

    for (const [name, foreground, background, minimum] of [
      ['brand/button text on accent', '#2a261f', '#e66a2c', 4.5],
      ['button hover text', '#2a261f', '#d6a62c', 4.5],
      ['input border/card', '#e66a2c', '#fffcf5', 3],
      ['input border/field', '#e66a2c', '#fff7e8', 3],
      ['input focus/card', '#2f654b', '#fffcf5', 3],
      ['input focus/field', '#2f654b', '#fff7e8', 3],
      ['button focus/accent', '#2a261f', '#e66a2c', 3],
      ['button focus/card', '#2a261f', '#fffcf5', 3],
      ['stage switch link on card', '#2f654b', '#fffcf5', 4.5],
      ['stage copy on card', '#655a4b', '#fffcf5', 4.5],
    ]) assertContrast(name, foreground, background, minimum)
  })

  it('documents the Vercel skin → direct POST consent flow and the human-gated restore in the README', () => {
    const readme = source('./README.md')
    assert.match(readme, /Connect to Morsel/)
    assert.match(readme, /params\.js/)
    assert.match(readme, /cross-origin form POST|direct.*POST|form POST/i)
    assert.match(readme, /no CORS|without CORS|no fetch/i)
    assert.match(readme, /text\/plain|HTML content is not supported|cannot serve HTML|shared domain/i)
    assert.match(readme, /#code-entry/)
    assert.match(readme, /human[- ]gate/i)
    assert.match(readme, /MORSEL_OAUTH_AUTHORIZATION_ENDPOINT/)
    assert.match(readme, /vercel\.json/)
    assert.doesNotMatch(readme, /proxies? [^.]*to (the |a )?[\w. -]*backend/i)
    assert.doesNotMatch(readme, /forwards? (the )?(form )?posts? (to|toward)/i)
    assert.doesNotMatch(readme, /Claude connection/)
    assert.doesNotMatch(readme, /no longer the OAuth consent surface|retired|archived|historical/i)
  })
})

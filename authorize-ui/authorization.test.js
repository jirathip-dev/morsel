import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { readdirSync } from 'node:fs'
import { describe, it } from 'vitest'

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

describe('static two-step authorization page (issue #60)', () => {
  it('uses neutral "Connect to Morsel" copy with no client-specific label anywhere', () => {
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

  it('is a no-JavaScript page: no script elements, no inline handlers, no runtime APIs', () => {
    const html = source('./index.html')
    const css = source('./authorization.css')
    assert.doesNotMatch(html, /<script/i)
    assert.doesNotMatch(html, /on(?:click|load|submit)=/i)
    for (const forbidden of [
      'innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(',
      'fetch(', 'XMLHttpRequest', 'localStorage', 'sessionStorage', 'document.cookie',
      'console.', 'analytics', 'x-upstream-url', 'UPSTREAM_AUTHORIZE_URL',
    ]) {
      assert.equal(`${html}\n${css}`.includes(forbidden), false, `forbidden runtime token: ${forbidden}`)
    }
    // The directory carries no runtime JavaScript at all, so the no-JS
    // contract cannot silently regress by re-adding a module.
    const files = readdirSync(new URL('.', import.meta.url)).filter((name) => name.endsWith('.js'))
    assert.deepEqual(files, ['authorization.test.js'])
  })

  it('keeps both stages as action-less method-preserving form posts that carry the current URL query', () => {
    const html = source('./index.html')
    const forms = [...html.matchAll(/<form\b[^>]*>/g)].map((match) => match[0])
    assert.equal(forms.length, 2)
    for (const form of forms) {
      // No action attribute: the browser posts to the document URL, so the
      // OAuth query parameters and the sealed transaction envelope travel
      // with every submission without JavaScript (verified in a real browser:
      // an action-less POST preserves the full query string).
      assert.doesNotMatch(form, /\baction=/)
      assert.match(form, /method="post"/)
    }
    assert.match(html, /<input[^>]+type="email"[^>]+name="email"[^>]+autocomplete="username"[^>]+required/)
    assert.match(html, /<input[^>]+name="code"[^>]+inputmode="numeric"[^>]+autocomplete="one-time-code"[^>]+pattern="\[0-9\]\{6\}"[^>]+maxlength="6"[^>]+required/)
  })

  it('switches stages with pure CSS on the #code-entry fragment and links back to the email stage', () => {
    const html = source('./index.html')
    const css = source('./authorization.css')
    assert.match(html, /id="email-stage"/)
    assert.match(html, /id="code-entry"/)
    assert.match(html, /<a[^>]+href="#email-stage"/)
    assert.match(cssRule(css, '#code-entry'), /display:\s*none/)
    assert.match(cssRule(css, 'body:has(#code-entry:target) #code-entry'), /display:\s*block/)
    assert.match(cssRule(css, 'body:has(#code-entry:target) #email-stage'), /display:\s*none/)
  })

  it('keeps the static CSP restrictive and script-free', () => {
    const html = source('./index.html')
    assert.match(html, /default-src 'none'/)
    assert.match(html, /style-src 'self'/)
    assert.match(html, /connect-src 'none'/)
    assert.match(html, /img-src 'none'/)
    assert.match(html, /font-src 'none'/)
    assert.match(html, /frame-ancestors 'none'/)
    assert.match(html, /object-src 'none'/)
    assert.match(html, /base-uri 'none'/)
    // Tighter than the pre-#60 page: script-src is gone because no script may
    // ever run. form-action stays absent so the validated 302 redirect chain
    // from the backend to each registered client callback is not blocked.
    assert.doesNotMatch(html, /script-src/)
    assert.doesNotMatch(html, /form-action/)
  })

  it('serves the archived page for /authorize with no form-post forwarding route (issue #66)', () => {
    const routing = JSON.parse(source('./vercel.json'))
    assert.equal(routing.routes.length, 1)
    assert.deepEqual(routing.routes[0], {
      src: '/authorize',
      dest: '/index.html',
    })
    // No legacy external-destination POST route may return: Vercel legacy
    // routes cannot forward to external hosts, so the route was inert and
    // the page is no longer the consent surface.
    assert.equal(routing.routes.some((route) => Array.isArray(route.methods)), false)
    assert.equal(JSON.stringify(routing).includes('supabase.co'), false)
    assert.equal(routing.$schema, 'https://openapi.vercel.sh/vercel.json')
  })

  it('keeps the archived-page HTML comment free of the stale POST-proxy claim (issue #66)', () => {
    const html = source('./index.html')
    // The page is an archived GET-only surface: the top comment may not
    // claim the static host routes form posts to the Supabase backend
    // (that claim died with the POST-proxy route in vercel.json).
    assert.doesNotMatch(html, /static host routes POST \/authorize to\s+the Supabase authorization backend/i)
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

  it('documents the retired page, the function-origin consent path, and the no-JS artifact in the README', () => {
    const readme = source('./README.md')
    assert.match(readme, /Connect to Morsel/)
    assert.match(readme, /no JavaScript|no-JS|without JavaScript/i)
    assert.match(readme, /action-less|omits? action|current URL/i)
    assert.match(readme, /#code-entry/)
    // Issue #66: the README must say the page is not the consent surface and
    // must not claim any form-post forwarding / active flow through this host.
    assert.match(readme, /no longer the OAuth consent surface|retired|archived|historical/i)
    assert.match(readme, /Supabase function origin|server-rendered|function origin/i)
    assert.match(readme, /vercel\.json/)
    assert.match(readme, /human[- ]gate|deploy|probe/i)
    assert.doesNotMatch(readme, /POST \/authorize/gi)
    assert.doesNotMatch(readme, /prox|forward.*POST|POST.*forward/i)
    assert.doesNotMatch(readme, /Claude connection/)
  })
})

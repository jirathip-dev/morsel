import assert from 'node:assert/strict'
import { describe, it } from 'vitest'
import { createAuthorizeHandler } from './handler.js'
import { createMorselApp } from '../server/app.js'
import { InMemoryRepository } from '../server/in-memory-repository.js'

const upstream = 'https://project.supabase.co/functions/v1/mcp/authorize'
const upstreamBase = 'https://project.supabase.co/functions/v1/mcp'
const rawQuery = 'state=a%20b&redirect_uri=https://c.example/cb&code_challenge=abc~def&flag&&empty=&state=two'
const upstreamForm = `<!doctype html><form method="post" action="${upstream}"><input name="email"></form>`

function fetchRecorder(responseFactory) {
  const requests = []
  const fetch = async (input, init) => {
    const request = new Request(input, init)
    requests.push(request)
    return responseFactory(request)
  }
  return { fetch, requests }
}

function realBackendHarness() {
  const backend = createMorselApp({
    basePath: '/mcp',
    authenticate: () => Promise.reject(new Error('not reached')),
    repositoryFactory: () => new InMemoryRepository(),
    oauth: {
      publicBaseUrl: upstreamBase,
      signingKey: 'synthetic-test-signing-key',
      service: {
        authenticate: () => Promise.reject(new Error('blank credentials must not authenticate')),
        refresh: () => Promise.reject(new Error('not reached')),
      },
      grantStore: {
        create: () => Promise.reject(new Error('not reached')),
        claim: () => Promise.resolve(undefined),
      },
    },
  })
  const fetch = async (input, init) => {
    const request = new Request(input, init)
    const url = new URL(request.url)
    assert.equal(url.origin, 'https://project.supabase.co')
    assert.equal(url.pathname.startsWith('/functions/v1/mcp/'), true)
    url.host = 'backend.internal'
    url.pathname = url.pathname.replace('/functions/v1/mcp/', '/mcp/')
    const body = request.method === 'GET' || request.method === 'HEAD'
      ? undefined
      : new Uint8Array(await request.arrayBuffer())
    return backend.fetch(new Request(url, {
      method: request.method,
      headers: request.headers,
      body,
      redirect: 'manual',
    }))
  }
  return { backend, handler: createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch }) }
}

describe('external authorization handler', () => {
  it('preserves the raw GET query and rewrites exactly one known form action', async () => {
    const recorder = fetchRecorder(() => new Response(upstreamForm, {
      status: 200,
      headers: {
        'content-type': 'text/plain; charset=utf-8',
        server: 'upstream-secret-server',
        'x-powered-by': 'upstream-runtime',
      },
    }))
    const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })

    const response = await handler(new Request(`https://auth.example/authorize?${rawQuery}`))

    assert.equal(recorder.requests.length, 1)
    assert.equal(recorder.requests[0].url, `${upstream}?${rawQuery}`)
    assert.equal(recorder.requests[0].method, 'GET')
    assert.equal(recorder.requests[0].redirect, 'manual')
    assert.equal(recorder.requests[0].headers.has('cookie'), false)
    assert.equal(recorder.requests[0].headers.has('authorization'), false)
    assert.equal(response.status, 200)
    assert.equal(response.headers.get('content-type'), 'text/html; charset=utf-8')
    assert.equal(response.headers.get('cache-control'), 'no-store')
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff')
    assert.equal(response.headers.get('content-security-policy'), "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
    assert.equal(response.headers.has('server'), false)
    assert.equal(response.headers.has('x-powered-by'), false)
    assert.equal(await response.text(), upstreamForm.replace(`action="${upstream}"`, 'action="/authorize"'))
  })

  it('preserves raw POST bytes, duplicate/unknown fields, content type, and a validated redirect', async () => {
    const rawBody = 'state=a b&redirect_uri=https://c.example/cb&code_challenge=abc~def&flag&&empty=&state=two&unknown=%252F'
    const recorder = fetchRecorder(() => new Response(null, {
      status: 302,
      headers: {
        location: 'https://client.example/callback?code=abc&state=one',
        'cache-control': 'no-store',
        server: 'hidden',
        'set-cookie': 'never=forward',
      },
    }))
    const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })

    const response = await handler(new Request('https://auth.example/authorize?resource=https%3A%2F%2Fmcp.example%2F', {
      method: 'POST',
      headers: {
        authorization: 'Bearer must-not-forward',
        cookie: 'session=must-not-forward',
        'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
        'x-upstream-url': 'https://evil.example/authorize',
      },
      body: new TextEncoder().encode(rawBody),
    }))

    assert.equal(recorder.requests[0].url, `${upstream}?resource=https%3A%2F%2Fmcp.example%2F`)
    assert.equal(recorder.requests[0].method, 'POST')
    assert.equal(recorder.requests[0].redirect, 'manual')
    assert.equal(recorder.requests[0].headers.get('content-type'), 'application/x-www-form-urlencoded; charset=utf-8')
    assert.equal(recorder.requests[0].headers.has('authorization'), false)
    assert.equal(recorder.requests[0].headers.has('cookie'), false)
    assert.equal(recorder.requests[0].headers.has('x-upstream-url'), false)
    assert.equal(await recorder.requests[0].text(), rawBody)
    assert.equal(response.status, 302)
    assert.equal(response.headers.get('location'), 'https://client.example/callback?code=abc&state=one')
    assert.equal(response.headers.get('cache-control'), 'no-store')
    assert.equal(response.headers.has('server'), false)
    assert.equal(response.headers.has('set-cookie'), false)
  })

  it('routes real-backend blank-credential POST rerenders back through the proxy', async () => {
    const { backend, handler } = realBackendHarness()
    const redirectUri = 'https://claude.ai/api/mcp/auth_callback'
    const registration = await backend.fetch(new Request('https://backend.internal/mcp/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: [redirectUri] }),
    }))
    assert.equal(registration.status, 201)
    const registered = await registration.json()
    assert.equal(typeof registered.client_id, 'string')
    const fields = {
      client_id: registered.client_id,
      code_challenge: 'pkce-challenge-abc~def',
      code_challenge_method: 'S256',
      redirect_uri: redirectUri,
      resource: 'https://project.supabase.co/functions/v1/mcp/mcp',
      response_type: 'code',
      scope: 'mcp profile',
      state: 'st/a+te==',
    }
    const response = await handler(new Request(`https://auth.example/authorize?${new URLSearchParams(fields)}`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: 'email=&password=',
    }))

    assert.equal(response.status, 200)
    assert.equal(response.headers.get('content-type'), 'text/html; charset=utf-8')
    assert.equal(response.headers.get('cache-control'), 'no-store')
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff')
    assert.equal(response.headers.get('content-security-policy'), "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
    assert.equal(response.headers.has('server'), false)
    const html = await response.text()
    assert.equal(html.includes('action="/authorize"'), true)
    assert.equal(html.includes(`action="${upstream}"`), false)
    assert.equal(html.includes('Email and password are required.'), true)
    for (const [name, value] of Object.entries(fields)) {
      assert.equal(html.includes(`name="${name}"`), true)
      assert.equal(html.includes(`value="${value}"`), true)
    }
  })

  it('validates every non-redirect POST document before emitting HTML', async () => {
    for (const [contentType, body] of [
      ['text/html', '<script>attacker()</script>'],
      ['text/plain', '<form action="https://evil.example/authorize"></form>'],
      ['text/html', `${upstreamForm}${upstreamForm}`],
    ]) {
      const recorder = fetchRecorder(() => new Response(body, { status: 400, headers: { 'content-type': contentType, server: 'hidden' } }))
      const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
      const response = await handler(new Request('https://auth.example/authorize', {
        method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'email=&password=',
      }))
      assert.equal(response.status, 502)
      assert.equal(response.headers.has('server'), false)
      const rejectedBody = await response.text()
      assert.equal(rejectedBody.includes('attacker'), false)
      assert.equal(rejectedBody.includes('evil.example'), false)
      assert.equal(rejectedBody.includes(upstream), false)
    }
  })

  it('preserves non-redirect POST OAuth JSON errors exactly', async () => {
    const body = '{"error":"invalid_request","error_description":"client_id is required"}'
    const recorder = fetchRecorder(() => new Response(body, {
      status: 400,
      headers: { 'content-type': 'application/json; charset=utf-8', server: 'hidden' },
    }))
    const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
    const response = await handler(new Request('https://auth.example/authorize', {
      method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'email=',
    }))
    assert.equal(response.status, 400)
    assert.equal(response.headers.get('content-type'), 'application/json; charset=utf-8')
    assert.equal(response.headers.has('server'), false)
    assert.equal(await response.text(), body)
  })

  it('preserves upstream OAuth JSON errors without relabeling them as HTML', async () => {
    const body = '{"error":"invalid_request","error_description":"redirect_uri is not registered"}'
    const recorder = fetchRecorder(() => new Response(body, {
      status: 400,
      headers: { 'content-type': 'application/json', server: 'hidden' },
    }))
    const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
    const response = await handler(new Request('https://auth.example/authorize?client_id=bad'))
    assert.equal(response.status, 400)
    assert.equal(response.headers.get('content-type'), 'application/json')
    assert.equal(response.headers.has('server'), false)
    assert.equal(await response.text(), body)
  })

  it('fails closed for unsupported or missing upstream content types on GET and POST', async () => {
    const encodedForm = new TextEncoder().encode(upstreamForm)
    const unsupported = [
      { headers: { 'content-type': 'text/xml' }, body: encodedForm },
      { headers: { 'content-type': 'multipart/form-data; boundary=x' }, body: encodedForm },
      { headers: { 'content-type': 'not-a-media-type' }, body: encodedForm },
      { headers: {}, body: encodedForm },
    ]
    for (const spec of unsupported) {
      for (const method of ['GET', 'POST']) {
        const recorder = fetchRecorder(() => new Response(spec.body, { status: 200, headers: spec.headers }))
        const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
        const response = await handler(new Request('https://auth.example/authorize', {
          method,
          ...(method === 'POST' ? { headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'x=1' } : {}),
        }))
        assert.equal(response.status, 502, `${method} must reject ${spec.headers['content-type'] ?? 'missing content-type'}`)
        assert.equal((await response.text()).includes('<form'), false)
      }
    }
  })

  it('pins the actual requested origin and path despite attacker headers and query', async () => {
    const recorder = fetchRecorder(() => new Response(upstreamForm, { headers: { 'content-type': 'text/plain' } }))
    const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
    const response = await handler(new Request('https://auth.example/authorize?upstream=https://evil.example/authorize&@evil.example/path', {
      headers: {
        authorization: 'Bearer attacker',
        cookie: 'upstream=evil',
        host: 'evil.example',
        'x-forwarded-host': 'evil.example',
        'x-upstream-url': 'https://evil.example/authorize',
      },
    }))
    assert.equal(response.status, 200)
    assert.equal(recorder.requests.length, 1)
    const requested = new URL(recorder.requests[0].url)
    assert.equal(requested.origin, 'https://project.supabase.co')
    assert.equal(requested.pathname, '/functions/v1/mcp/authorize')
    assert.equal(requested.search, '?upstream=https://evil.example/authorize&@evil.example/path')
    assert.equal([...recorder.requests[0].headers].length, 0)
  })

  it('handles HEAD without returning a body', async () => {
    const recorder = fetchRecorder(() => new Response(null, { status: 200, headers: { 'content-type': 'text/plain; charset=utf-8' } }))
    const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
    const response = await handler(new Request('https://auth.example/authorize?state=x%2Fy', { method: 'HEAD' }))
    assert.equal(recorder.requests[0].method, 'HEAD')
    assert.equal(recorder.requests[0].url, `${upstream}?state=x%2Fy`)
    assert.equal(response.status, 200)
    assert.equal(response.headers.get('content-type'), 'text/html; charset=utf-8')
    assert.equal(await response.text(), '')
  })

  it('fails closed when the known form action is missing or ambiguous', async () => {
    for (const body of ['<form method="post" action="https://evil.example/authorize"></form>', `${upstreamForm}${upstreamForm}`]) {
      const recorder = fetchRecorder(() => new Response(body, { headers: { 'content-type': 'text/plain' } }))
      const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
      const response = await handler(new Request('https://auth.example/authorize'))
      assert.equal(response.status, 502)
      assert.equal((await response.text()).includes(upstream), false)
    }
  })

  it('preserves both successful and OAuth-error redirect Locations exactly', async () => {
    for (const location of [
      'https://client.example/callback?code=abc&state=a%2Fb',
      'https://client.example/callback?error=access_denied&state=a%2Fb',
    ]) {
      const recorder = fetchRecorder(() => new Response(null, { status: 302, headers: { location } }))
      const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
      const response = await handler(new Request('https://auth.example/authorize', {
        method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'x=1',
      }))
      assert.equal(response.status, 302)
      assert.equal(response.headers.get('location'), location)
    }
  })

  it('rejects unsafe redirect locations instead of becoming an open redirect', async () => {
    for (const location of ['javascript:alert(1)', '//evil.example/callback', 'http://evil.example/callback']) {
      const recorder = fetchRecorder(() => new Response(null, { status: 302, headers: { location } }))
      const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
      const response = await handler(new Request('https://auth.example/authorize', {
        method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'x=1',
      }))
      assert.equal(response.status, 502)
      assert.equal(response.headers.has('location'), false)
    }
  })

  it('uses only a validated fixed HTTPS upstream and fails closed for paths and methods', async () => {
    for (const invalid of [
      'http://project.supabase.co/functions/v1/mcp/authorize',
      'https://user:pass@project.supabase.co/authorize',
      'https://project.supabase.co/authorize?upstream=evil',
      'https://project.supabase.co/token',
    ]) {
      assert.throws(() => createAuthorizeHandler({ upstreamAuthorizeUrl: invalid, fetch: async () => new Response() }), /UPSTREAM_AUTHORIZE_URL/)
    }
    const recorder = fetchRecorder(() => new Response(upstreamForm, { headers: { 'content-type': 'text/plain' } }))
    const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
    const fixedUpstreamResponse = await handler(new Request('https://auth.example/authorize?upstream=https%3A%2F%2Fevil.example%2Fauthorize'))
    assert.equal(fixedUpstreamResponse.status, 200)
    assert.equal(recorder.requests[0].url, `${upstream}?upstream=https%3A%2F%2Fevil.example%2Fauthorize`)
    const notFound = await handler(new Request('https://auth.example/token?upstream=https://evil.example'))
    const notAllowed = await handler(new Request('https://auth.example/authorize', { method: 'PUT', body: 'secret' }))
    assert.equal(notFound.status, 404)
    assert.equal(notAllowed.status, 405)
    assert.equal(recorder.requests.length, 1)
  })

  it('answers OPTIONS without credential mode and never logs sensitive data', async () => {
    const messages = []
    const original = { log: console.log, info: console.info, warn: console.warn, error: console.error }
    for (const method of Object.keys(original)) console[method] = (...values) => messages.push(values.join(' '))
    try {
      const recorder = fetchRecorder(() => new Response(null, {
        status: 302, headers: { location: 'https://client.example/callback?code=secret-code&state=secret-state' },
      }))
      const handler = createAuthorizeHandler({ upstreamAuthorizeUrl: upstream, fetch: recorder.fetch })
      const preflight = await handler(new Request('https://auth.example/authorize?client_id=secret-client&redirect_uri=https%3A%2F%2Fclient.example', { method: 'OPTIONS' }))
      assert.equal(preflight.status, 204)
      assert.equal(preflight.headers.get('access-control-allow-methods'), 'GET,HEAD,POST,OPTIONS')
      assert.equal(preflight.headers.has('access-control-allow-credentials'), false)
      await handler(new Request('https://auth.example/authorize?state=secret-state&client_id=secret-client', {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: 'email=user%40example.com&password=secret-password&code=secret-code&token=secret-token&redirect_uri=https%3A%2F%2Fclient.example',
      }))
      assert.deepEqual(messages, [])
    } finally {
      Object.assign(console, original)
    }
  })
})

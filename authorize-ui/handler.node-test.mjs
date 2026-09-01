import assert from 'node:assert/strict'
import { afterEach, describe, it } from 'node:test'
import { createAuthorizeHandler } from './handler.mjs'

const upstream = 'https://project.supabase.co/functions/v1/mcp/authorize'
const rawQuery = 'scope=mcp&scope=profile&state=a%2Fb%3D%3D&unknown=%252F'
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
    const rawBody = 'client_id=a&state=one&state=two&unknown=%252F&email=user%40example.com&password=p%2B%25'
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

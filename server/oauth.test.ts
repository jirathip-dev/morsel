import { describe, expect, it, vi } from 'vitest'
import type { Hono } from 'hono'
import { createMorselApp } from './app.js'
import { InMemoryRepository } from './in-memory-repository.js'
import type { EmailCodeRequestPolicy, OAuthAuthorizationGrant, OAuthGrantStore, OAuthIdentityService, OAuthUserSession } from './oauth.js'
import { createSupabaseOAuthGrantStore, createSupabaseOAuthService } from './oauth.js'

const userSession = (email: string, accessToken = 'supabase-access-token'): OAuthUserSession => ({
  userId: '00000000-0000-4000-8000-000000000002',
  email,
  accessToken,
  refreshToken: 'supabase-refresh-token',
  expiresIn: 3600,
})

// The route never sees credentials or Supabase behavior: a stubbed identity
// service issues a code per requested email, verifies each code once, and
// rejects everything else (wrong, reused, or codes for emails that were never
// requested, which models unknown accounts).
interface StubIdentityService extends OAuthIdentityService {
  sentEmails: string[]
}

function createStubIdentityService(validCodes: string[] = ['123456']): StubIdentityService {
  const sentEmails: string[] = []
  const consumed = new Set<string>()
  const service: StubIdentityService = {
    sentEmails,
    requestCode(email: string): Promise<void> {
      sentEmails.push(email)
      return Promise.resolve()
    },
    verifyCode(email: string, code: string): Promise<OAuthUserSession> {
      const key = `${email}\u0000${code}`
      if (!validCodes.includes(code) || !sentEmails.includes(email) || consumed.has(key)) {
        return Promise.reject(new Error('invalid or already used code'))
      }
      consumed.add(key)
      return Promise.resolve(userSession(email))
    },
    refresh(): Promise<OAuthUserSession> {
      return Promise.resolve(userSession('test@example.com', 'supabase-access-token-rotated'))
    },
  }
  return service
}

// An identity service whose code requests always fail provider-side: step 1
// must answer exactly like the successful case so account existence is never
// disclosed, and step 2 can never succeed because no code was ever issued.
function createRejectingCodeRequestService(): OAuthIdentityService {
  return {
    requestCode(): Promise<void> {
      return Promise.reject(new Error('Supabase Auth could not send an email code'))
    },
    verifyCode(): Promise<OAuthUserSession> {
      return Promise.reject(new Error('no code was ever issued for this email'))
    },
    refresh(): Promise<OAuthUserSession> {
      return Promise.resolve(userSession('test@example.com', 'supabase-access-token-rotated'))
    },
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function stringProperty(value: unknown, name: string): string {
  if (!isRecord(value) || typeof value[name] !== 'string') {
    throw new Error(`missing string property: ${name}`)
  }
  return value[name]
}

function transactionValue(html: string): string {
  const match = /name="transaction" value="([^"]+)"/.exec(html)
  if (match?.[1] === undefined) {
    throw new Error('missing transaction envelope')
  }
  return match[1]
}

// Byte-compare two code-stage pages after masking the random envelope value:
// the pages must be externally uniform for existing and unknown accounts.
function normalizedFormPage(html: string): string {
  return html.replace(/name="transaction" value="[^"]+"/g, 'name="transaction" value="<envelope>"')
}

interface TestGrantStore extends OAuthGrantStore {
  grants: Map<string, OAuthAuthorizationGrant>
}

function createTestGrantStore(): TestGrantStore {
  const grants = new Map<string, OAuthAuthorizationGrant>()
  return {
    grants,
    create: (grant, accessToken) => {
      void accessToken
      grants.set(grant.codeHash, grant)
      return Promise.resolve()
    },
    claim: (codeHash, clientId) => {
      const grant = grants.get(codeHash)
      if (grant === undefined || grant.clientId !== clientId || grant.expiresAt <= Math.floor(Date.now() / 1000)) {
        return Promise.resolve(undefined)
      }
      grants.delete(codeHash)
      return Promise.resolve(grant)
    },
  }
}

function createTestApp(
  basePath?: string,
  grantStore: TestGrantStore = createTestGrantStore(),
  publicBaseUrl?: string,
  authorizationEndpoint?: string,
  service: OAuthIdentityService = createStubIdentityService(),
  emailCodeRequests?: EmailCodeRequestPolicy,
  now?: () => number,
) {
  const oauthOptions = Object.assign({
    grantStore,
    publicBaseUrl,
    signingKey: 'oauth-test-signing-key',
    service,
    emailCodeRequests,
    now,
  }, authorizationEndpoint === undefined ? {} : { authorizationEndpoint })
  return createMorselApp({
    basePath,
    authenticate: () => Promise.reject(new Error('not reached')),
    repositoryFactory: () => new InMemoryRepository(),
    oauth: oauthOptions,
  })
}

const TEST_REDIRECT_URI = 'https://client.example/callback'

async function registerTestClient(app: Hono, redirectUris: string[] = [TEST_REDIRECT_URI]): Promise<string> {
  const registrationResponse = await app.fetch(new Request('https://morsel.test/register', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ redirect_uris: redirectUris }),
  }))
  expect(registrationResponse.status).toBe(201)
  return stringProperty(await registrationResponse.json(), 'client_id')
}

function oauthParams(clientId: string, overrides: Record<string, string> = {}): URLSearchParams {
  const params = new URLSearchParams({
    client_id: clientId,
    code_challenge: 'prefix-challenge',
    code_challenge_method: 'S256',
    redirect_uri: TEST_REDIRECT_URI,
    response_type: 'code',
  })
  for (const [name, value] of Object.entries(overrides)) {
    params.set(name, value)
  }
  return params
}

function formPostRequest(url: string, body: URLSearchParams): Request {
  return new Request(url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: body.toString(),
  })
}

// Step 1 of the email-code flow: request a code for the email and return the
// rendered code stage plus the sealed transaction envelope.
async function requestCode(app: Hono, params: URLSearchParams, email: string): Promise<{ html: string; transaction: string }> {
  const stepOne = await app.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
    ...Object.fromEntries(params),
    email,
  })))
  expect(stepOne.status).toBe(200)
  const html = await stepOne.text()
  return { html, transaction: transactionValue(html) }
}

// Step 2 of the email-code flow: submit the code and return the response.
async function submitCode(app: Hono, params: URLSearchParams, transaction: string, code: string): Promise<Response> {
  return await app.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
    ...Object.fromEntries(params),
    transaction,
    code,
  })))
}

function expectCodeStage(html: string, ...fragments: string[]): void {
  expect(html).toContain('Connect to Morsel')
  expect(html).toContain('name="code"')
  expect(html).toContain('name="transaction"')
  expect(html).not.toContain('type="password"')
  for (const fragment of fragments) {
    expect(html).toContain(fragment)
  }
}

function expectEmailStage(html: string, ...fragments: string[]): void {
  expect(html).toContain('Connect to Morsel')
  expect(html).toContain('name="email"')
  expect(html).not.toContain('type="password"')
  expect(html).not.toContain('name="transaction"')
  for (const fragment of fragments) {
    expect(html).toContain(fragment)
  }
}

function expectRejectedBeforeUrlParsing(authorizationEndpoint: string): void {
  const urlConstructor = vi.spyOn(globalThis, 'URL')
  try {
    expect(() => createTestApp('/mcp', createTestGrantStore(), undefined, authorizationEndpoint)).toThrow(/authorization endpoint/)
    expect(urlConstructor).not.toHaveBeenCalled()
  } finally {
    urlConstructor.mockRestore()
  }
}

describe('OAuth discovery and MCP authentication', () => {
  // Issue #57: the canonical client-facing MCP transport is the Edge Function
  // ROOT (public https://<host>/functions/v1/mcp; runtime /mcp because the
  // hosted gateway strips /functions/v1). The pre-#57 nested /mcp/mcp path is
  // a compatibility alias only: it must keep serving old clients but must
  // never advertise its own metadata. Every new or updated user-facing
  // surface publishes the root URL.
  describe('canonical root transport (#57)', () => {
    it('serves the MCP transport at the function root and keeps the nested path as a compatibility alias', async () => {
      const app = createTestApp('/mcp')
      const initialize = {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
      }

      // Root: reaches transport authentication (401 challenge), not a 404.
      const rootResponse = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp', initialize))
      expect(rootResponse.status).toBe(401)
      expect(rootResponse.headers.get('content-type')).toBe('application/json')
      expect(rootResponse.headers.get('www-authenticate')).toContain('Bearer resource_metadata=')
      expect(rootResponse.headers.get('access-control-allow-origin')).toBe('*')
      expect(rootResponse.headers.get('access-control-expose-headers')).toBe('WWW-Authenticate')

      // Alias: same transport contract, same challenge, no separate identity.
      const aliasResponse = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/mcp', initialize))
      expect(aliasResponse.status).toBe(401)
      expect(aliasResponse.headers.get('content-type')).toBe('application/json')
      expect(aliasResponse.headers.get('www-authenticate')).toBe(rootResponse.headers.get('www-authenticate'))

      // Load-bearing alias check: the alias must actually reach transport
      // authentication (a stubbed 404 must fail this test), so it is a real
      // compatibility path rather than a dead route.
      const unauthenticatedGet = { headers: { accept: 'application/json, text/event-stream' } }
      const aliasGet = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/mcp', unauthenticatedGet))
      expect(aliasGet.status).toBe(401)

      // The alias serves no discovery of its own.
      const aliasDiscovery = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/mcp/.well-known/oauth-authorization-server'))
      expect(aliasDiscovery.status).toBe(404)
    })

    it('keeps an MCP client session usable across the root transport and the alias', async () => {
      // Session continuity is what makes the alias a true compatibility path:
      // a client that initializes at the root may continue over the nested
      // path (and vice versa) because both serve the same session store.
      const app = createMorselApp({
        basePath: '/mcp',
        authenticate: (receivedToken) => Promise.resolve({
          userId: '00000000-0000-4000-8000-000000000002',
          email: 'test@example.com',
          token: receivedToken,
          authInfo: {
            token: receivedToken,
            clientId: 'test-client',
            scopes: [],
            extra: { userId: '00000000-0000-4000-8000-000000000002' },
          },
        }),
        repositoryFactory: () => new InMemoryRepository(),
        enableJsonResponse: true,
      })
      const initializeBody = {
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: {
          protocolVersion: '2025-03-26',
          capabilities: {},
          clientInfo: { name: 'morsel-alias-test-client', version: '1.0.0' },
        },
      }
      const request = (path: string, sessionId?: string, body: unknown = initializeBody): Request => new Request(`https://morsel.test${path}`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: 'Bearer session-bearer-token',
          // The MCP SDK requires clients to accept both response shapes.
          accept: 'application/json, text/event-stream',
          ...(sessionId === undefined ? {} : { 'mcp-session-id': sessionId }),
        },
        body: JSON.stringify(body),
      })

      const initializeResponse = await app.fetch(request('/mcp'))
      expect(initializeResponse.status).toBe(200)
      const sessionId = initializeResponse.headers.get('mcp-session-id') ?? ''
      expect(sessionId).not.toBe('')
      expect(sessionId).toEqual(expect.any(String))

      // A legacy client keeps its initialized session when it keeps talking
      // to the nested alias URL.
      const aliasListResponse = await app.fetch(request('/mcp/mcp', sessionId, { jsonrpc: '2.0', id: 2, method: 'tools/list' }))
      expect(aliasListResponse.status).toBe(200)

      // And a client initialized at the alias may continue at the root.
      const rootListResponse = await app.fetch(request('/mcp', sessionId, { jsonrpc: '2.0', id: 3, method: 'tools/list' }))
      expect(rootListResponse.status).toBe(200)
    })

    it('advertises the canonical root URL consistently across metadata, challenge, form action, and endpoints', async () => {
      const app = createTestApp('/mcp', createTestGrantStore(), 'https://connector.example/functions/v1/mcp')
      const [authorizationServer, protectedResource] = await Promise.all([
        app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/oauth-authorization-server')),
        app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/oauth-protected-resource/mcp')),
      ])
      const authorizationServerMetadata = await authorizationServer.json()
      const protectedResourceMetadata = await protectedResource.json()

      const canonical = 'https://connector.example/functions/v1/mcp'
      expect(authorizationServerMetadata).toMatchObject({
        issuer: canonical,
        authorization_endpoint: `${canonical}/authorize`,
        token_endpoint: `${canonical}/token`,
        registration_endpoint: `${canonical}/register`,
      })
      expect(protectedResourceMetadata).toMatchObject({
        resource: canonical,
        authorization_servers: [canonical],
      })
      // No canonical advertisement may present the nested alias as a resource
      // or issuer (the alias is transport-only compatibility).
      expect(JSON.stringify(authorizationServerMetadata)).not.toContain(`${canonical}/mcp`)
      expect(JSON.stringify(protectedResourceMetadata)).not.toContain(`${canonical}/mcp`)

      const registrationResponse = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/register', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ redirect_uris: ['https://client.example/callback'] }),
      }))
      expect(registrationResponse.status).toBe(201)
      const clientId = stringProperty(await registrationResponse.json(), 'client_id')
      const authorizationResponse = await app.fetch(new Request(`http://supabase-edge-runtime:8081/mcp/authorize?${new URLSearchParams({
        client_id: clientId,
        code_challenge: 'prefix-challenge',
        code_challenge_method: 'S256',
        redirect_uri: 'https://client.example/callback',
        response_type: 'code',
      }).toString()}`))
      expect(authorizationResponse.status).toBe(200)
      const html = await authorizationResponse.text()
      expect(html).toContain(`<form method="post" action="${canonical}/authorize">`)
      expect(html).not.toContain(`${canonical}/mcp/authorize`)
    })
  })

  it('serves browser-readable CORS headers on all discovery responses', async () => {
    const app = createTestApp()
    const responses = await Promise.all([
      app.fetch(new Request('https://morsel.test/.well-known/oauth-protected-resource')),
      app.fetch(new Request('https://morsel.test/.well-known/oauth-protected-resource/mcp')),
      app.fetch(new Request('https://morsel.test/.well-known/oauth-authorization-server')),
    ])
    for (const response of responses) {
      expect(response.headers.get('access-control-allow-origin')).toBe('*')
    }
  })

  it('serves an MCP OPTIONS preflight', async () => {
    const app = createTestApp()
    const response = await app.fetch(new Request('https://morsel.test/mcp', { method: 'OPTIONS' }))

    expect(response.status).toBe(204)
    expect(response.headers.get('access-control-allow-origin')).toBe('*')
    expect(response.headers.get('access-control-allow-headers')).toContain('authorization')
    expect(response.headers.get('access-control-allow-methods')).toBe('GET,POST,DELETE,OPTIONS')
    expect(response.headers.get('access-control-max-age')).toBe('86400')
  })

  it('makes the unauthenticated MCP 401 challenge browser-readable', async () => {
    const app = createTestApp()
    const response = await app.fetch(new Request('https://morsel.test/mcp', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    }))

    expect(response.status).toBe(401)
    expect(response.headers.get('access-control-allow-origin')).toBe('*')
    expect(response.headers.get('access-control-expose-headers')).toBe('WWW-Authenticate')
    expect(response.headers.get('www-authenticate')).toContain('Bearer resource_metadata=')
  })

  it('serves the authorization form as HTML with charset utf-8', async () => {
    const app = createTestApp()
    const redirectUri = 'https://client.example/callback'
    const registrationResponse = await app.fetch(new Request('https://morsel.test/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: [redirectUri] }),
    }))
    expect(registrationResponse.status).toBe(201)
    const clientId = stringProperty(await registrationResponse.json(), 'client_id')
    const authorizationResponse = await app.fetch(new Request(`https://morsel.test/authorize?${new URLSearchParams({
      client_id: clientId,
      code_challenge: 'prefix-challenge',
      code_challenge_method: 'S256',
      redirect_uri: redirectUri,
      response_type: 'code',
    }).toString()}`))

    expect(authorizationResponse.status).toBe(200)
    expect(authorizationResponse.headers.get('content-type')).toBe('text/html; charset=utf-8')
    expect(await authorizationResponse.text()).toContain('<!doctype html>')
  })

  it('serves protected-resource metadata at both standard path forms', async () => {
    const app = createTestApp()
    const responses = await Promise.all([
      app.fetch(new Request('https://morsel.test/.well-known/oauth-protected-resource')),
      app.fetch(new Request('https://morsel.test/.well-known/oauth-protected-resource/mcp')),
      app.fetch(new Request('https://morsel.test/.well-known/oauth-authorization-server')),
    ])

    expect(responses.map((response) => response.status)).toEqual([200, 200, 200])
    const protectedResource = await responses[0].json()
    const pathSpecificProtectedResource = await responses[1].json()
    const authorizationServer = await responses[2].json()
    expect(pathSpecificProtectedResource).toEqual(protectedResource)
    // Issue #57: the advertised resource is the canonical transport URL — the
    // base/issuer itself — with no nested /mcp suffix appended anywhere.
    expect(protectedResource).toMatchObject({
      resource: 'https://morsel.test',
      authorization_servers: ['https://morsel.test'],
    })
    expect(JSON.stringify(protectedResource)).not.toContain('/mcp/mcp')
    expect(authorizationServer).toMatchObject({
      issuer: 'https://morsel.test',
      authorization_endpoint: 'https://morsel.test/authorize',
      token_endpoint: 'https://morsel.test/token',
      registration_endpoint: 'https://morsel.test/register',
      code_challenge_methods_supported: ['S256'],
      grant_types_supported: ['authorization_code', 'refresh_token'],
    })
  })

  it('uses the forwarded public origin for Edge metadata', async () => {
    const app = createTestApp('/mcp')
    const response = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/oauth-protected-resource/mcp', {
      headers: {
        'x-forwarded-host': 'connector.example',
        'x-forwarded-port': '443',
        'x-forwarded-prefix': '/functions/v1/',
        'x-forwarded-proto': 'https',
      },
    }))

    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({
      resource: 'https://connector.example/functions/v1/mcp',
      authorization_servers: ['https://connector.example/functions/v1/mcp'],
    })
  })

  it('advertises the explicit public prefix when the gateway strips /functions/v1', async () => {
    const app = createTestApp('/mcp', createTestGrantStore(), 'https://connector.example/functions/v1/mcp')
    const [authorizationServer, protectedResource] = await Promise.all([
      app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/oauth-authorization-server')),
      app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/oauth-protected-resource/mcp')),
    ])

    expect(authorizationServer.status).toBe(200)
    expect(await authorizationServer.json()).toMatchObject({
      issuer: 'https://connector.example/functions/v1/mcp',
      authorization_endpoint: 'https://connector.example/functions/v1/mcp/authorize',
      token_endpoint: 'https://connector.example/functions/v1/mcp/token',
      registration_endpoint: 'https://connector.example/functions/v1/mcp/register',
      code_challenge_methods_supported: ['S256'],
      grant_types_supported: ['authorization_code', 'refresh_token'],
    })
    expect(protectedResource.status).toBe(200)
    expect(await protectedResource.json()).toMatchObject({
      resource: 'https://connector.example/functions/v1/mcp',
      authorization_servers: ['https://connector.example/functions/v1/mcp'],
    })

    // Issue #57: the canonical transport is the function ROOT — the unauthenticated
    // initialize at https://<host>/functions/v1/mcp must reach transport auth and get
    // the 401 challenge, and the WWW-Authenticate resource_metadata URL must equal the
    // root's protected-resource discovery URL.
    const rootChallengeResponse = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    }))
    expect(rootChallengeResponse.status).toBe(401)
    expect(rootChallengeResponse.headers.get('www-authenticate')).toBe(
      'Bearer resource_metadata="https://connector.example/functions/v1/mcp/.well-known/oauth-protected-resource/mcp"',
    )

    const challengeResponse = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/mcp', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    }))
    expect(challengeResponse.status).toBe(401)
    expect(challengeResponse.headers.get('www-authenticate')).toBe(
      'Bearer resource_metadata="https://connector.example/functions/v1/mcp/.well-known/oauth-protected-resource/mcp"',
    )
  })

  it('advertises only the configured external authorization endpoint', async () => {
    const canonical = 'https://connector.example/functions/v1/mcp'
    const externalAuthorizationEndpoint = 'https://morsel-authorize-ui.vercel.app/authorize'
    const app = createTestApp('/mcp', createTestGrantStore(), canonical, externalAuthorizationEndpoint)
    const [authorizationServer, protectedResource] = await Promise.all([
      app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/oauth-authorization-server')),
      app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/oauth-protected-resource/mcp')),
    ])

    expect(authorizationServer.status).toBe(200)
    const authorizationServerMetadata = await authorizationServer.json()
    expect(authorizationServerMetadata).toMatchObject({
      issuer: canonical,
      authorization_endpoint: externalAuthorizationEndpoint,
      token_endpoint: `${canonical}/token`,
      registration_endpoint: `${canonical}/register`,
    })
    expect(stringProperty(authorizationServerMetadata, 'authorization_endpoint')).toBe(externalAuthorizationEndpoint)
    expect(protectedResource.status).toBe(200)
    expect(await protectedResource.json()).toMatchObject({
      resource: canonical,
      authorization_servers: [canonical],
    })

    const challengeResponse = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    }))
    expect(challengeResponse.status).toBe(401)
    expect(challengeResponse.headers.get('www-authenticate')).toBe(
      `Bearer resource_metadata="${canonical}/.well-known/oauth-protected-resource/mcp"`,
    )

    const registrationResponse = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: ['https://client.example/callback'] }),
    }))
    const clientId = stringProperty(await registrationResponse.json(), 'client_id')
    const authorizationResponse = await app.fetch(new Request(`http://supabase-edge-runtime:8081/mcp/authorize?${new URLSearchParams({
      client_id: clientId,
      code_challenge: 'prefix-challenge',
      code_challenge_method: 'S256',
      redirect_uri: 'https://client.example/callback',
      response_type: 'code',
    }).toString()}`))
    expect(authorizationResponse.status).toBe(200)
    expect(await authorizationResponse.text()).toContain(`<form method="post" action="${canonical}/authorize">`)
  })

  it('falls back to the Supabase authorization route when the external endpoint is unset', async () => {
    const canonical = 'https://connector.example/functions/v1/mcp'
    const app = createTestApp('/mcp', createTestGrantStore(), canonical)
    const response = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/oauth-authorization-server'))

    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({
      issuer: canonical,
      authorization_endpoint: `${canonical}/authorize`,
      token_endpoint: `${canonical}/token`,
      registration_endpoint: `${canonical}/register`,
    })
  })

  const backslashEndpoint = `https://morsel-authorize-ui.vercel.app/auth${String.fromCharCode(0x5c)}orize`
  const malformedEndpointCases = [
    ['blank', ''],
    ['leading whitespace', ' https://morsel-authorize-ui.vercel.app/authorize'],
    ['trailing whitespace', 'https://morsel-authorize-ui.vercel.app/authorize '],
    ['non-HTTPS', 'http://morsel-authorize-ui.vercel.app/authorize'],
    ['relative', '/authorize'],
    ['query', 'https://morsel-authorize-ui.vercel.app/authorize?state=ambiguous'],
    ['fragment', 'https://morsel-authorize-ui.vercel.app/authorize#fragment'],
    ['userinfo', 'https://user:password@morsel-authorize-ui.vercel.app/authorize'],
    ['empty userinfo', 'https://@morsel-authorize-ui.vercel.app/authorize'],
    ['extra-slash scheme', 'https:////morsel-authorize-ui.vercel.app/authorize'],
    ['backslash', backslashEndpoint],
    ['embedded whitespace', 'https://morsel-authorize-ui.vercel.app/auth orize'],
    ['explicit default port', 'https://morsel-authorize-ui.vercel.app:443/authorize'],
    ['dot segment', 'https://morsel-authorize-ui.vercel.app/a/../authorize'],
    ['canonical host case', 'https://MORSEL-AUTHORIZE-UI.VERCEL.APP/authorize'],
  ] as const

  const controlEndpointCases = [
    ['embedded tab', 0x09, `https://morsel-authorize-ui.vercel.app/auth${String.fromCharCode(0x09)}orize`],
    ['embedded newline', 0x0a, `https://morsel-authorize-ui.vercel.app/auth${String.fromCharCode(0x0a)}orize`],
    ['embedded carriage return', 0x0d, `https://morsel-authorize-ui.vercel.app/auth${String.fromCharCode(0x0d)}orize`],
    ['embedded NUL', 0x00, `https://morsel-authorize-ui.vercel.app/auth${String.fromCharCode(0x00)}orize`],
    ['embedded DEL', 0x7f, `https://morsel-authorize-ui.vercel.app/auth${String.fromCharCode(0x7f)}orize`],
  ] as const

  it.each(malformedEndpointCases)('fails closed for malformed external authorization endpoint: %s', (_label, authorizationEndpoint) => {
    expect(() => createTestApp('/mcp', createTestGrantStore(), 'https://connector.example/functions/v1/mcp', authorizationEndpoint)).toThrow(/authorization endpoint/)
  })

  it('rejects a runtime backslash before URL parsing', () => {
    expectRejectedBeforeUrlParsing(backslashEndpoint)
  })

  it.each(controlEndpointCases)('fails closed for malformed external authorization endpoint: %s', (_label, codePoint, authorizationEndpoint) => {
    const controlPrefix = 'https://morsel-authorize-ui.vercel.app/auth'
    expect(authorizationEndpoint.codePointAt(controlPrefix.length)).toBe(codePoint)
    expectRejectedBeforeUrlParsing(authorizationEndpoint)
  })

  it('derives metadata from the request when no public prefix is configured', async () => {
    const app = createTestApp('/mcp')
    const response = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/oauth-authorization-server'))

    expect(response.status).toBe(200)
    expect(await response.json()).toMatchObject({
      issuer: 'http://supabase-edge-runtime:8081/mcp',
      authorization_endpoint: 'http://supabase-edge-runtime:8081/mcp/authorize',
      token_endpoint: 'http://supabase-edge-runtime:8081/mcp/token',
      registration_endpoint: 'http://supabase-edge-runtime:8081/mcp/register',
    })
  })

  it('rejects a malformed explicit public base URL', () => {
    expect(() => createTestApp('/mcp', createTestGrantStore(), 'not-a-url')).toThrow(/public base URL/)
    expect(() => createTestApp('/mcp', createTestGrantStore(), 'ftp://connector.example/mcp')).toThrow(/public base URL/)
    expect(() => createTestApp('/mcp', createTestGrantStore(), 'https://connector.example/mcp#fragment')).toThrow(/public base URL/)
  })

  it('posts the authorization form to the public callable URL when a public base is configured', async () => {
    const app = createTestApp('/mcp', createTestGrantStore(), 'https://connector.example/functions/v1/mcp')
    const redirectUri = 'https://client.example/callback'
    const registrationResponse = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: [redirectUri] }),
    }))
    expect(registrationResponse.status).toBe(201)
    const clientId = stringProperty(await registrationResponse.json(), 'client_id')

    const authorizationResponse = await app.fetch(new Request(`http://supabase-edge-runtime:8081/mcp/authorize?${new URLSearchParams({
      client_id: clientId,
      code_challenge: 'prefix-challenge',
      code_challenge_method: 'S256',
      redirect_uri: redirectUri,
      response_type: 'code',
      state: 'state-123',
    }).toString()}`))
    expect(authorizationResponse.status).toBe(200)
    const html = await authorizationResponse.text()
    expect(html).toContain('<form method="post" action="https://connector.example/functions/v1/mcp/authorize">')
    expect(html).toContain('name="client_id"')
    expect(html).toContain('name="state"')
    expect(html).not.toContain('action="/mcp/authorize"')
  })

  it('keeps the local authorization form action when no public base is configured', async () => {
    const app = createTestApp('/mcp')
    const redirectUri = 'https://client.example/callback'
    const registrationResponse = await app.fetch(new Request('https://morsel.test/mcp/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: [redirectUri] }),
    }))
    expect(registrationResponse.status).toBe(201)
    const clientId = stringProperty(await registrationResponse.json(), 'client_id')

    const authorizationResponse = await app.fetch(new Request(`https://morsel.test/mcp/authorize?${new URLSearchParams({
      client_id: clientId,
      code_challenge: 'prefix-challenge',
      code_challenge_method: 'S256',
      redirect_uri: redirectUri,
      response_type: 'code',
      state: 'state-123',
    }).toString()}`))
    expect(authorizationResponse.status).toBe(200)
    expect(await authorizationResponse.text()).toContain('<form method="post" action="/mcp/authorize">')
  })

  it('keeps discovery and the MCP challenge working below the Edge Function prefix', async () => {
    const app = createTestApp('/mcp')
    const [rootMetadata, metadata] = await Promise.all([
      app.fetch(new Request('https://morsel.test/mcp/.well-known/oauth-protected-resource')),
      app.fetch(new Request('https://morsel.test/mcp/.well-known/oauth-protected-resource/mcp')),
    ])
    expect(rootMetadata.status).toBe(200)
    expect(metadata.status).toBe(200)
    expect(await rootMetadata.json()).toEqual(await metadata.clone().json())
    expect(await metadata.json()).toMatchObject({
      resource: 'https://morsel.test/mcp',
      authorization_servers: ['https://morsel.test/mcp'],
    })

    const registrationResponse = await app.fetch(new Request('https://morsel.test/mcp/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: ['https://client.example/callback'] }),
    }))
    expect(registrationResponse.status).toBe(201)
    const clientId = stringProperty(await registrationResponse.json(), 'client_id')
    const authorizeResponse = await app.fetch(new Request(`https://morsel.test/mcp/authorize?${new URLSearchParams({
      client_id: clientId,
      code_challenge: 'prefix-challenge',
      code_challenge_method: 'S256',
      redirect_uri: 'https://client.example/callback',
      response_type: 'code',
    }).toString()}`))
    expect(authorizeResponse.status).toBe(200)

    const mcpResponse = await app.fetch(new Request('https://morsel.test/mcp/mcp', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    }))
    expect(mcpResponse.status).toBe(401)
    expect(mcpResponse.headers.get('www-authenticate')).toBe(
      'Bearer resource_metadata="https://morsel.test/mcp/.well-known/oauth-protected-resource/mcp"',
    )
  })

  describe('OIDC discovery at the issuer path (#59)', () => {
    // Issue #59: spec-compliant MCP clients (Hermes, Claude, ChatGPT) build
    // discovery URLs by appending to the issuer. Attempts 1-2 (host-root
    // .well-known prefixes carrying the issuer path) die at the Supabase
    // gateway before reaching the function; the third attempt -
    // <issuer>/.well-known/openid-configuration - is the one that reaches
    // Morsel, so the authorization-server document must be served there.
    it('serves the authorization-server document at the OIDC discovery path with identical behavior', async () => {
      const app = createTestApp('/mcp')
      const [oidc, authorizationServer] = await Promise.all([
        app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/openid-configuration')),
        app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/oauth-authorization-server')),
      ])
      expect(oidc.status).toBe(200)
      expect(authorizationServer.status).toBe(200)

      // Same document, byte-for-byte: the OIDC route reuses the AS metadata
      // builder rather than duplicating it.
      const oidcText = await oidc.clone().text()
      const asText = await authorizationServer.clone().text()
      expect(oidcText).toBe(asText)
      const metadata = await oidc.clone().json()
      const asMetadata = await authorizationServer.clone().json()
      expect(metadata).toEqual(asMetadata)
      expect(metadata).toMatchObject({
        issuer: 'http://supabase-edge-runtime:8081/mcp',
        authorization_endpoint: 'http://supabase-edge-runtime:8081/mcp/authorize',
        token_endpoint: 'http://supabase-edge-runtime:8081/mcp/token',
        registration_endpoint: 'http://supabase-edge-runtime:8081/mcp/register',
        response_types_supported: ['code'],
        code_challenge_methods_supported: ['S256'],
        token_endpoint_auth_methods_supported: ['none'],
        grant_types_supported: ['authorization_code', 'refresh_token'],
        scopes_supported: ['mcp'],
      })

      // Only claims the provider can back: no invented OIDC fields on the
      // discovery surface (jwks_uri / subject_types_supported would be
      // unbacked).
      expect(metadata).not.toHaveProperty('jwks_uri')
      expect(metadata).not.toHaveProperty('subject_types_supported')
      expect(metadata).not.toHaveProperty('userinfo_endpoint')

      // Same wire behavior as the existing AS metadata route.
      const behaviorHeaders = [
        ['cache-control', 'no-store'],
        ['content-type', 'application/json'],
        ['access-control-allow-origin', '*'],
        ['access-control-allow-methods', 'GET,POST,OPTIONS'],
        ['access-control-allow-headers', 'content-type'],
        ['access-control-expose-headers', 'WWW-Authenticate'],
      ] as const
      for (const [name, expected] of behaviorHeaders) {
        expect(oidc.headers.get(name)).toBe(expected)
        expect(oidc.headers.get(name)).toBe(authorizationServer.headers.get(name))
      }
    })

    it('keeps the issuer byte-equal to the production public base on the OIDC route', async () => {
      const productionIssuer = 'https://anuerofnnewbsumukhqq.supabase.co/functions/v1/mcp'
      const app = createTestApp('/mcp', createTestGrantStore(), productionIssuer)
      const response = await app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/.well-known/openid-configuration'))

      expect(response.status).toBe(200)
      expect(response.headers.get('cache-control')).toBe('no-store')
      expect(response.headers.get('content-type')).toBe('application/json')
      expect(response.headers.get('access-control-allow-origin')).toBe('*')
      expect(await response.json()).toMatchObject({
        issuer: productionIssuer,
        authorization_endpoint: `${productionIssuer}/authorize`,
        token_endpoint: `${productionIssuer}/token`,
        registration_endpoint: `${productionIssuer}/register`,
      })
    })

    it('serves no OIDC discovery outside the canonical issuer path', async () => {
      const app = createTestApp('/mcp')
      const [hostRoot, alias] = await Promise.all([
        // Host-root .well-known prefixes (spec attempts 1-2) are gateway
        // territory and must not be registered by Morsel.
        app.fetch(new Request('http://supabase-edge-runtime:8081/.well-known/openid-configuration')),
        // The nested /mcp/mcp compatibility alias advertises no discovery of
        // its own (issue #57 rule), OIDC included.
        app.fetch(new Request('http://supabase-edge-runtime:8081/mcp/mcp/.well-known/openid-configuration')),
      ])
      expect(hostRoot.status).toBe(404)
      expect(alias.status).toBe(404)
    })
  })

  it('runs a PKCE authorization-code flow and rejects cross-instance code replay', async () => {
    const grantStore = createTestGrantStore()
    const app = createTestApp(undefined, grantStore)
    const redirectUri = 'https://client.example/callback'
    const verifier = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-._~'
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))
    const challenge = btoa(String.fromCharCode(...new Uint8Array(digest)))
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
    const registrationResponse = await app.fetch(new Request('https://morsel.test/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        client_name: 'Test connector',
        redirect_uris: [redirectUri],
        response_types: ['code'],
        grant_types: ['authorization_code', 'refresh_token'],
        token_endpoint_auth_method: 'none',
      }),
    }))
    expect(registrationResponse.status).toBe(201)
    const registration = await registrationResponse.json()
    const clientId = stringProperty(registration, 'client_id')
    expect(clientId).toEqual(expect.any(String))

    const authorizationParams = new URLSearchParams({
      client_id: clientId,
      code_challenge: challenge,
      code_challenge_method: 'S256',
      redirect_uri: redirectUri,
      response_type: 'code',
      state: 'state-123',
    })
    const loginPage = await app.fetch(new Request(`https://morsel.test/authorize?${authorizationParams.toString()}`))
    expect(loginPage.status).toBe(200)
    const loginHtml = await loginPage.text()
    expect(loginHtml).toContain('Connect to Morsel')
    expect(loginHtml).toContain('name="email"')
    expect(loginHtml).not.toContain('type="password"')

    // Step 1: email only. The route requests a code and returns the code
    // stage with the full transaction preserved as hidden fields.
    const stepOne = await app.fetch(new Request('https://morsel.test/authorize', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        ...Object.fromEntries(authorizationParams),
        email: 'test@example.com',
      }),
    }))
    expect(stepOne.status).toBe(200)
    const stepOneHtml = await stepOne.text()
    expectCodeStage(stepOneHtml, 'name="state"')
    const transaction = transactionValue(stepOneHtml)
    expect(stepOneHtml).not.toContain('test@example.com')

    // Step 2: the correct code continues the existing stored-grant path and
    // redirects to the registered client callback with the authorization code.
    const stepTwo = await app.fetch(new Request('https://morsel.test/authorize', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        ...Object.fromEntries(authorizationParams),
        transaction,
        code: '123456',
      }),
    }))
    expect(stepTwo.status).toBe(302)
    const callback = new URL(stepTwo.headers.get('location') ?? '')
    expect(callback.origin + callback.pathname).toBe(redirectUri)
    expect(callback.searchParams.get('state')).toBe('state-123')
    const code = callback.searchParams.get('code') ?? ''
    expect(code).toEqual(expect.any(String))
    expect(code).not.toContain('supabase-access-token')

    const tokenResponse = await app.fetch(new Request('https://morsel.test/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code,
        code_verifier: verifier,
        grant_type: 'authorization_code',
        redirect_uri: redirectUri,
      }),
    }))
    expect(tokenResponse.status).toBe(200)
    const tokens = await tokenResponse.json()
    const refreshToken = stringProperty(tokens, 'refresh_token')
    expect(tokens).toMatchObject({
      access_token: 'supabase-access-token-rotated',
      token_type: 'Bearer',
    })
    expect(refreshToken).toEqual(expect.any(String))

    const secondAppInstance = createTestApp(undefined, grantStore)
    const replayResponse = await secondAppInstance.fetch(new Request('https://morsel.test/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code,
        code_verifier: verifier,
        grant_type: 'authorization_code',
        redirect_uri: redirectUri,
      }),
    }))
    expect(replayResponse.status).toBe(400)
    expect(await replayResponse.json()).toMatchObject({ error: 'invalid_grant' })

    const refreshResponse = await app.fetch(new Request('https://morsel.test/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        grant_type: 'refresh_token',
        refresh_token: refreshToken,
      }),
    }))
    expect(refreshResponse.status).toBe(200)
    expect(await refreshResponse.json()).toMatchObject({
      access_token: 'supabase-access-token-rotated',
      token_type: 'Bearer',
    })
  })

  it('requires redirect_uri when the authorization request included one', async () => {
    const app = createTestApp()
    const redirectUri = 'https://client.example/callback'
    const verifier = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-._~'
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))
    const challenge = btoa(String.fromCharCode(...new Uint8Array(digest)))
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
    const registrationResponse = await app.fetch(new Request('https://morsel.test/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: [redirectUri] }),
    }))
    const clientId = stringProperty(await registrationResponse.json(), 'client_id')
    // Step 1: email only, then Step 2: the code, matching the flow a browser
    // follows when the client sent a redirect_uri in the authorization request.
    const stepOne = await app.fetch(new Request('https://morsel.test/authorize', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code_challenge: challenge,
        code_challenge_method: 'S256',
        email: 'test@example.com',
        redirect_uri: redirectUri,
        response_type: 'code',
      }),
    }))
    expect(stepOne.status).toBe(200)
    const transaction = transactionValue(await stepOne.text())
    const stepTwo = await app.fetch(new Request('https://morsel.test/authorize', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code_challenge: challenge,
        code_challenge_method: 'S256',
        transaction,
        code: '123456',
        redirect_uri: redirectUri,
        response_type: 'code',
      }),
    }))
    expect(stepTwo.status).toBe(302)
    const callback = new URL(stepTwo.headers.get('location') ?? '')
    const tokenResponse = await app.fetch(new Request('https://morsel.test/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code: callback.searchParams.get('code') ?? '',
        code_verifier: verifier,
        grant_type: 'authorization_code',
      }),
    }))

    expect(tokenResponse.status).toBe(400)
    expect(await tokenResponse.json()).toMatchObject({ error: 'invalid_grant' })
  })

  it('rejects plain PKCE and a mismatched verifier', async () => {
    const app = createTestApp()
    const registrationResponse = await app.fetch(new Request('https://morsel.test/register', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: ['https://client.example/callback'] }),
    }))
    const registration = await registrationResponse.json()
    const clientId = stringProperty(registration, 'client_id')
    const plainResponse = await app.fetch(new Request(`https://morsel.test/authorize?${new URLSearchParams({
      client_id: clientId,
      code_challenge: 'plain-challenge',
      code_challenge_method: 'plain',
      redirect_uri: 'https://client.example/callback',
      response_type: 'code',
    }).toString()}`))
    expect(plainResponse.status).toBe(400)
    expect(await plainResponse.json()).toMatchObject({ error: 'invalid_request' })

    const verifier = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-._~'
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))
    const challenge = btoa(String.fromCharCode(...new Uint8Array(digest)))
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
    // Complete the two-step email-code flow so a real authorization code exists.
    const stepOne = await app.fetch(new Request('https://morsel.test/authorize', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code_challenge: challenge,
        code_challenge_method: 'S256',
        email: 'test@example.com',
        redirect_uri: 'https://client.example/callback',
        response_type: 'code',
      }),
    }))
    expect(stepOne.status).toBe(200)
    const transaction = transactionValue(await stepOne.text())
    const stepTwo = await app.fetch(new Request('https://morsel.test/authorize', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code_challenge: challenge,
        code_challenge_method: 'S256',
        transaction,
        code: '123456',
        redirect_uri: 'https://client.example/callback',
        response_type: 'code',
      }),
    }))
    expect(stepTwo.status).toBe(302)
    const callback = new URL(stepTwo.headers.get('location') ?? '')
    const invalidTokenResponse = await app.fetch(new Request('https://morsel.test/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code: callback.searchParams.get('code') ?? '',
        code_verifier: 'wrong-verifier',
        grant_type: 'authorization_code',
        redirect_uri: 'https://client.example/callback',
      }),
    }))
    expect(invalidTokenResponse.status).toBe(400)
    expect(await invalidTokenResponse.json()).toMatchObject({ error: 'invalid_grant' })
  })
})

describe('email one-time-code authorization (issue #60)', () => {
  it('accepts email only on the first step and carries every OAuth parameter as a hidden field', async () => {
    const app = createTestApp()
    const clientId = await registerTestClient(app)
    const params = oauthParams(clientId, { state: 'state-123', scope: 'mcp', resource: 'https://morsel.test/mcp' })
    const loginPage = await app.fetch(new Request(`https://morsel.test/authorize?${params.toString()}`))

    expect(loginPage.status).toBe(200)
    const html = await loginPage.text()
    expectEmailStage(html, 'An MCP client is requesting access to your Morsel account')
    for (const name of ['client_id', 'redirect_uri', 'code_challenge', 'code_challenge_method', 'state', 'scope', 'resource', 'response_type']) {
      expect(html).toContain(`name="${name}"`)
    }
    expect(html).not.toContain('type="password"')
  })

  it('answers uniformly for existing and unknown accounts and never requests user creation', async () => {
    const knownApp = createTestApp(undefined, createTestGrantStore(), undefined, undefined, createStubIdentityService())
    const unknownApp = createTestApp(undefined, createTestGrantStore(), undefined, undefined, createRejectingCodeRequestService())
    const knownClientId = await registerTestClient(knownApp)
    const unknownClientId = await registerTestClient(unknownApp)
    const email = 'uniform@example.com'

    const knownStepOne = await knownApp.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
      ...Object.fromEntries(oauthParams(knownClientId)),
      email,
    })))
    const unknownStepOne = await unknownApp.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
      ...Object.fromEntries(oauthParams(unknownClientId)),
      email,
    })))
    expect(knownStepOne.status).toBe(200)
    expect(unknownStepOne.status).toBe(200)
    const knownHtml = normalizedFormPage(await knownStepOne.text())
    const unknownRawHtml = await unknownStepOne.text()
    const unknownHtml = normalizedFormPage(unknownRawHtml)
    expect(knownHtml).toBe(unknownHtml)
    expect(knownHtml).not.toContain(email)
    expect(knownHtml).not.toContain('unknown')
    expect(knownHtml).not.toContain('not found')
    // User creation is disabled at the service wire (create_user: false is
    // asserted in the Supabase service test); the route only ever asks for a
    // code and never completes step 2 for an account that received none.
    const unknownStepTwo = await unknownApp.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
      ...Object.fromEntries(oauthParams(unknownClientId)),
      transaction: transactionValue(unknownRawHtml),
      code: '123456',
    })))
    expect(unknownStepTwo.status).toBe(200)
    expectCodeStage(await unknownStepTwo.text(), 'invalid or has expired')
  })

  it('rate-limits code requests per email without revealing existence or the email', async () => {
    const service = createStubIdentityService()
    const grantStore = createTestGrantStore()
    const app = createTestApp(undefined, grantStore, undefined, undefined, service, { maxRequests: 2, windowSeconds: 600 })
    const clientId = await registerTestClient(app)
    const params = oauthParams(clientId)
    const email = 'limited@example.com'

    const first = await app.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
      ...Object.fromEntries(params), email,
    })))
    const second = await app.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
      ...Object.fromEntries(params), email,
    })))
    expect(first.status).toBe(200)
    expect(second.status).toBe(200)
    expect(normalizedFormPage(await first.text())).toBe(normalizedFormPage(await second.text()))

    // The bounded repeated request is deferred: no code is requested, the
    // email is never echoed, and the response stays on the email stage.
    const deferred = await app.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
      ...Object.fromEntries(params), email,
    })))
    expect(deferred.status).toBe(200)
    const deferredHtml = await deferred.text()
    expectEmailStage(deferredHtml, 'Too many code requests')
    expect(deferredHtml).not.toContain(email)
    expect(service.sentEmails).toEqual(['limited@example.com', 'limited@example.com'])
    expect(grantStore.grants.size).toBe(0)

    // A different email has its own budget: the limit is per email.
    const other = await app.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
      ...Object.fromEntries(params), email: 'other@example.com',
    })))
    expect(other.status).toBe(200)
    expectCodeStage(await other.text())
    expect(service.sentEmails).toEqual(['limited@example.com', 'limited@example.com', 'other@example.com'])
  })

  it('keeps a wrong code in the code stage with the transaction intact and allows a retry', async () => {
    const app = createTestApp()
    const clientId = await registerTestClient(app)
    const params = oauthParams(clientId, { state: 'state-123' })
    const { html, transaction } = await requestCode(app, params, 'test@example.com')
    expectCodeStage(html, 'name="state"')

    const wrong = await submitCode(app, params, transaction, '000000')
    expect(wrong.status).toBe(200)
    const wrongHtml = await wrong.text()
    expectCodeStage(wrongHtml, 'That code is invalid or has expired')
    expect(transactionValue(wrongHtml)).toBe(transaction)

    const retry = await submitCode(app, params, transaction, '123456')
    expect(retry.status).toBe(302)
    const callback = new URL(retry.headers.get('location') ?? '')
    expect(callback.searchParams.get('state')).toBe('state-123')
  })

  it('rejects a reused code after a successful grant without a second redirect', async () => {
    const grantStore = createTestGrantStore()
    const app = createTestApp(undefined, grantStore)
    const clientId = await registerTestClient(app)
    const params = oauthParams(clientId)
    const { transaction } = await requestCode(app, params, 'test@example.com')

    const success = await submitCode(app, params, transaction, '123456')
    expect(success.status).toBe(302)
    expect(grantStore.grants.size).toBe(1)

    const replay = await submitCode(app, params, transaction, '123456')
    expect(replay.status).toBe(200)
    expectCodeStage(await replay.text(), 'That code is invalid or has expired')
    expect(grantStore.grants.size).toBe(1)
    expect(replay.headers.get('location')).toBeNull()
  })

  it('fails closed on a malformed code shape and keeps the code stage usable', async () => {
    const app = createTestApp()
    const clientId = await registerTestClient(app)
    const params = oauthParams(clientId)
    const { html, transaction } = await requestCode(app, params, 'test@example.com')
    expectCodeStage(html)

    for (const malformed of ['12345', '12ab56', '1234567', '']) {
      const response = await submitCode(app, params, transaction, malformed)
      expect(response.status).toBe(200)
      const attemptHtml = await response.text()
      expectCodeStage(attemptHtml, 'Enter the 6-digit code')
      expect(transactionValue(attemptHtml)).toBe(transaction)
    }

    const retry = await submitCode(app, params, transaction, '123456')
    expect(retry.status).toBe(302)
  })

  it('fails closed when the transaction envelope expires, keeping every OAuth field', async () => {
    const grantStore = createTestGrantStore()
    let currentMs = 1_800_000_000_000
    const app = createTestApp(undefined, grantStore, undefined, undefined, undefined, undefined, () => currentMs)
    const clientId = await registerTestClient(app)
    const params = oauthParams(clientId, { state: 'state-123', scope: 'mcp' })
    const stepOne = await app.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
      ...Object.fromEntries(params), email: 'test@example.com',
    })))
    expect(stepOne.status).toBe(200)
    const transaction = transactionValue(await stepOne.text())

    currentMs += (10 * 60 + 1) * 1_000
    const expired = await submitCode(app, params, transaction, '123456')
    expect(expired.status).toBe(200)
    const expiredHtml = await expired.text()
    expectEmailStage(expiredHtml, 'expired or is no longer valid')
    expect(expiredHtml).toContain('name="state"')
    expect(expiredHtml).toContain('name="scope"')
    expect(expired.headers.get('location')).toBeNull()
    expect(grantStore.grants.size).toBe(0)
  })

  it('fails closed on missing or tampered envelopes and on cross-transaction field swaps', async () => {
    const grantStore = createTestGrantStore()
    const app = createTestApp(undefined, grantStore)
    const clientId = await registerTestClient(app, [TEST_REDIRECT_URI, 'https://client.example/other-callback'])
    const primary = oauthParams(clientId, { state: 'state-a' })
    const other = oauthParams(clientId, { state: 'state-b', redirect_uri: 'https://client.example/other-callback' })
    const { transaction } = await requestCode(app, primary, 'test@example.com')

    // Missing envelope: no code can be judged, no grant is created.
    const missing = await app.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
      ...Object.fromEntries(primary), code: '123456',
    })))
    expect(missing.status).toBe(200)
    expectEmailStage(await missing.text(), 'expired or is no longer valid')

    // Tampered envelope: integrity check fails closed.
    const tampered = transaction.slice(0, -1) + (transaction.endsWith('a') ? 'b' : 'a')
    const tamperedResponse = await submitCode(app, primary, tampered, '123456')
    expect(tamperedResponse.status).toBe(200)
    expectEmailStage(await tamperedResponse.text(), 'expired or is no longer valid')

    // Cross-transaction: a valid envelope bound to another redirect_uri/state
    // combination must not authorize this request.
    const swapped = await submitCode(app, other, transaction, '123456')
    expect(swapped.status).toBe(200)
    const swappedHtml = await swapped.text()
    expectEmailStage(swappedHtml, 'expired or is no longer valid')
    expect(swappedHtml).toContain('name="state"')
    expect(swappedHtml).toContain('value="state-b"')
    expect(grantStore.grants.size).toBe(0)
    expect(swapped.headers.get('location')).toBeNull()

    // The original transaction is untouched by the hostile attempts.
    const recovery = await submitCode(app, primary, transaction, '123456')
    expect(recovery.status).toBe(302)
    const callback = new URL(recovery.headers.get('location') ?? '')
    expect(callback.searchParams.get('state')).toBe('state-a')
    expect(grantStore.grants.size).toBe(1)
  })

  it('survives duplicate and hostile extra fields while preserving scope and state', async () => {
    const grantStore = createTestGrantStore()
    const app = createTestApp(undefined, grantStore)
    const clientId = await registerTestClient(app)
    const params = oauthParams(clientId, { state: 'one', scope: 'mcp' })
    // Duplicate state and an unknown field travel with the request; the
    // documented backend semantics are last-wins for duplicate names.
    const login = await app.fetch(new Request(`https://morsel.test/authorize?${params.toString()}&state=two&hostile=junk`))
    const loginHtml = await login.text()
    expect(loginHtml).toContain('name="state"')
    expect(loginHtml).toContain('name="hostile"')

    const stepOne = await app.fetch(formPostRequest('https://morsel.test/authorize', new URLSearchParams({
      ...Object.fromEntries(params),
      state: 'two',
      hostile: 'junk',
      email: 'test@example.com',
    })))
    expect(stepOne.status).toBe(200)
    const stepOneHtml = await stepOne.text()
    expect(stepOneHtml).toContain('name="hostile"')
    expect(stepOneHtml).toContain('value="two"')
    const transaction = transactionValue(stepOneHtml)

    const stepTwo = await submitCode(app, new URLSearchParams({
      ...Object.fromEntries(params),
      state: 'two',
      hostile: 'junk',
    }), transaction, '123456')
    expect(stepTwo.status).toBe(302)
    const callback = new URL(stepTwo.headers.get('location') ?? '')
    expect(callback.searchParams.get('state')).toBe('two')
    const grant = [...grantStore.grants.values()][0]
    expect(grant?.scopes).toEqual(['mcp'])
  })

  it('never leaks email, code, or token values into responses or logs', async () => {
    const app = createTestApp()
    const clientId = await registerTestClient(app)
    const params = oauthParams(clientId, { state: 'state-123' })
    const email = 'sentinels@example.com'
    const { html, transaction } = await requestCode(app, params, email)
    expect(html).not.toContain(email)

    const wrong = await submitCode(app, params, transaction, '000000')
    const wrongHtml = await wrong.text()
    expect(wrongHtml).not.toContain(email)
    expect(wrongHtml).not.toContain('000000')

    const success = await submitCode(app, params, transaction, '123456')
    const location = success.headers.get('location') ?? ''
    expect(location).not.toContain(email)
    expect(location).not.toContain('123456')
    expect(location).not.toContain('supabase-access-token')
    expect(location).not.toContain('supabase-refresh-token')
  })

  it('contains no password flow, no logging, and neutral copy in the server sources', async () => {
    const { readFileSync } = await import('node:fs')
    const source = readFileSync(new URL('./oauth.ts', import.meta.url), 'utf8')
    expect(source).not.toContain('signInWithPassword')
    expect(source).not.toContain('console.')
    expect(source).toContain('requestCode')
    expect(source).toContain('verifyCode')
    const appSource = readFileSync(new URL('./app.ts', import.meta.url), 'utf8')
    expect(appSource).not.toContain('console.')
  })

  describe('external static page mode', () => {
    const externalEndpoint = 'https://morsel-authorize-ui.vercel.app/authorize'

    it('redirects step 1 to the static page with the envelope and returns code failures to the code stage', async () => {
      const grantStore = createTestGrantStore()
      const app = createTestApp(undefined, grantStore, undefined, externalEndpoint)
      const clientId = await registerTestClient(app)
      const params = oauthParams(clientId, { state: 'state-123', scope: 'mcp' })

      // Direct visits still render the server-side email stage (fallback).
      const direct = await app.fetch(new Request(`https://morsel.test/authorize?${params.toString()}`))
      expect(direct.status).toBe(200)
      expectEmailStage(await direct.text())

      // Step 1 from the static page: the OAuth parameters ride in the query
      // (an action-less form posts the current URL) and email only in the body.
      const stepOne = await app.fetch(new Request(`https://morsel.test/authorize?${params.toString()}`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ email: 'test@example.com' }).toString(),
      }))
      expect(stepOne.status).toBe(302)
      const codeStageUrl = new URL(stepOne.headers.get('location') ?? '')
      expect(codeStageUrl.origin + codeStageUrl.pathname).toBe(externalEndpoint)
      expect(codeStageUrl.hash).toBe('#code-entry')
      for (const name of ['client_id', 'redirect_uri', 'code_challenge', 'code_challenge_method', 'state', 'scope', 'response_type']) {
        expect(codeStageUrl.searchParams.get(name)).toBe(params.get(name))
      }
      expect(codeStageUrl.searchParams.get('email')).toBeNull()
      expect(codeStageUrl.searchParams.get('code')).toBeNull()
      const transaction = codeStageUrl.searchParams.get('transaction') ?? ''
      expect(transaction).not.toBe('')

      // Wrong code from the static code stage returns to the code stage with
      // the same envelope; no grant and no client redirect.
      const codeStageQuery = codeStageUrl.searchParams.toString()
      const wrong = await app.fetch(new Request(`https://morsel.test/authorize?${codeStageQuery}`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ code: '000000' }).toString(),
      }))
      expect(wrong.status).toBe(302)
      const retryUrl = new URL(wrong.headers.get('location') ?? '')
      expect(retryUrl.origin + retryUrl.pathname).toBe(externalEndpoint)
      expect(retryUrl.hash).toBe('#code-entry')
      expect(retryUrl.searchParams.get('transaction')).toBe(transaction)
      expect(grantStore.grants.size).toBe(0)

      // Correct code completes the existing authorization-code redirect.
      const success = await app.fetch(new Request(`https://morsel.test/authorize?${codeStageQuery}`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ code: '123456' }).toString(),
      }))
      expect(success.status).toBe(302)
      const callback = new URL(success.headers.get('location') ?? '')
      expect(callback.origin + callback.pathname).toBe(TEST_REDIRECT_URI)
      expect(callback.searchParams.get('state')).toBe('state-123')
      expect(grantStore.grants.size).toBe(1)
    })

    it('returns an invalid or expired envelope to the email stage without the fragment', async () => {
      const app = createTestApp(undefined, createTestGrantStore(), undefined, externalEndpoint)
      const clientId = await registerTestClient(app)
      const params = oauthParams(clientId)
      const stepOne = await app.fetch(new Request(`https://morsel.test/authorize?${params.toString()}`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ email: 'test@example.com' }).toString(),
      }))
      const codeStageUrl = new URL(stepOne.headers.get('location') ?? '')

      const tampered = codeStageUrl.searchParams.get('transaction')?.slice(0, -2) ?? ''
      const attempt = await app.fetch(new Request(`https://morsel.test/authorize?${params.toString()}`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ transaction: tampered, code: '123456' }).toString(),
      }))
      expect(attempt.status).toBe(302)
      const emailStageUrl = new URL(attempt.headers.get('location') ?? '')
      expect(emailStageUrl.origin + emailStageUrl.pathname).toBe(externalEndpoint)
      expect(emailStageUrl.hash).toBe('')
      expect(emailStageUrl.searchParams.get('transaction')).toBeNull()
      expect(emailStageUrl.searchParams.get('client_id')).toBe(params.get('client_id'))
      expect(emailStageUrl.searchParams.get('state')).toBeNull() // state was not sent on this attempt
    })
  })
})

describe('Supabase OAuth service', () => {
  it('requests email codes with user creation disabled and verifies them through Supabase Auth', async () => {
    const requests: Request[] = []
    const fetchMock = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      const request = input instanceof Request
        ? new Request(input, init)
        : new Request(input.toString(), init)
      requests.push(request)
      if (request.url.includes('/auth/v1/otp')) {
        return Promise.resolve(new Response(JSON.stringify({}), { headers: { 'content-type': 'application/json' } }))
      }
      if (request.url.includes('/auth/v1/verify')) {
        return Promise.resolve(new Response(JSON.stringify({
          access_token: 'issued-access-token',
          expires_in: 3600,
          refresh_token: 'issued-refresh-token',
          token_type: 'bearer',
          user: { id: '00000000-0000-4000-8000-000000000002', email: 'test@example.com' },
        }), { headers: { 'content-type': 'application/json' } }))
      }
      return Promise.resolve(new Response(JSON.stringify({
        id: '00000000-0000-4000-8000-000000000002',
        email: 'test@example.com',
      }), { headers: { 'content-type': 'application/json' } }))
    }
    fetchMock.preconnect = (): void => undefined
    const service = createSupabaseOAuthService({
      anonKey: 'test-anon-key',
      fetch: fetchMock,
      supabaseUrl: 'https://morsel.test',
    })

    await expect(service.requestCode('test@example.com')).resolves.toBeUndefined()
    const otpRequest = requests.find((request) => request.url.includes('/auth/v1/otp'))
    expect(otpRequest).toBeDefined()
    const otpBody: unknown = JSON.parse(await otpRequest?.clone().text() ?? '{}')
    expect(otpBody).toMatchObject({ email: 'test@example.com', create_user: false })

    await expect(service.verifyCode('test@example.com', '123456')).resolves.toMatchObject({
      accessToken: 'issued-access-token',
      userId: '00000000-0000-4000-8000-000000000002',
    })
    const verifyRequest = requests.find((request) => request.url.includes('/auth/v1/verify'))
    expect(verifyRequest).toBeDefined()
    const verifyBody: unknown = JSON.parse(await verifyRequest?.clone().text() ?? '{}')
    expect(verifyBody).toMatchObject({ type: 'email', email: 'test@example.com', token: '123456' })
    expect(requests.some((request) => request.url.endsWith('/auth/v1/user') && request.headers.get('authorization') === 'Bearer issued-access-token')).toBe(true)
  })
})

describe('Supabase OAuth grant store', () => {
  it('inserts grants with the user token and claims through the RPC', async () => {
    const requests: Request[] = []
    const expiresAt = Math.floor(Date.now() / 1000) + 300
    const grant: OAuthAuthorizationGrant = {
      codeHash: 'code-hash',
      clientId: 'client-id',
      redirectUri: 'https://client.example/callback',
      codeChallenge: 'code-challenge',
      userId: '00000000-0000-4000-8000-000000000002',
      refreshToken: 'server-refresh-token',
      scopes: ['mcp'],
      resource: 'https://morsel.test/mcp',
      expiresAt,
    }
    const fetchMock = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      const request = input instanceof Request
        ? new Request(input, init)
        : new Request(input.toString(), init)
      requests.push(request)
      if (request.url.endsWith('/rest/v1/oauth_authorization_grants')) {
        return Promise.resolve(new Response(null, { status: 201 }))
      }
      return Promise.resolve(new Response(JSON.stringify([{
        code_hash: grant.codeHash,
        client_id: grant.clientId,
        redirect_uri: grant.redirectUri,
        code_challenge: grant.codeChallenge,
        scopes: grant.scopes,
        resource: grant.resource,
        user_id: grant.userId,
        refresh_token: grant.refreshToken,
        expires_at: new Date(expiresAt * 1000).toISOString(),
      }]), { headers: { 'content-type': 'application/json' } }))
    }
    fetchMock.preconnect = (): void => undefined
    const store = createSupabaseOAuthGrantStore({
      anonKey: 'test-anon-key',
      fetch: fetchMock,
      supabaseUrl: 'https://morsel.test',
    })

    await store.create(grant, 'issued-access-token')
    await expect(store.claim(grant.codeHash, grant.clientId)).resolves.toEqual(grant)
    expect(requests).toHaveLength(2)
    expect(requests[0]?.headers.get('authorization')).toBe('Bearer issued-access-token')
    expect(requests[1]?.url).toContain('/rest/v1/rpc/claim_oauth_authorization_grant')
    expect(requests[1]?.headers.get('authorization')).toBe('Bearer test-anon-key')
  })
})

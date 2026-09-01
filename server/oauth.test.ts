import { describe, expect, it } from 'vitest'
import { createMorselApp } from './app.js'
import { InMemoryRepository } from './in-memory-repository.js'
import type { OAuthAuthorizationGrant, OAuthGrantStore } from './oauth.js'
import { createSupabaseOAuthGrantStore, createSupabaseOAuthService } from './oauth.js'

const oauthService = {
  authenticate: () => Promise.resolve({
    userId: '00000000-0000-4000-8000-000000000002',
    email: 'test@example.com',
    accessToken: 'supabase-access-token',
    refreshToken: 'supabase-refresh-token',
    expiresIn: 3600,
  }),
  refresh: () => Promise.resolve({
    userId: '00000000-0000-4000-8000-000000000002',
    email: 'test@example.com',
    accessToken: 'supabase-access-token-rotated',
    refreshToken: 'supabase-refresh-token-rotated',
    expiresIn: 3600,
  }),
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

function createTestGrantStore(): OAuthGrantStore {
  const grants = new Map<string, OAuthAuthorizationGrant>()
  return {
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

function createTestApp(basePath?: string, grantStore = createTestGrantStore(), publicBaseUrl?: string) {
  return createMorselApp({
    basePath,
    authenticate: () => Promise.reject(new Error('not reached')),
    repositoryFactory: () => new InMemoryRepository(),
    oauth: {
      grantStore,
      publicBaseUrl,
      signingKey: 'oauth-test-signing-key',
      service: oauthService,
    },
  })
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
    expect(await loginPage.text()).toContain('Connect Morsel')

    const authorizationResponse = await app.fetch(new Request('https://morsel.test/authorize', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        ...Object.fromEntries(authorizationParams),
        email: 'test@example.com',
        password: 'correct-password',
      }),
    }))
    expect(authorizationResponse.status).toBe(302)
    const callback = new URL(authorizationResponse.headers.get('location') ?? '')
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
    const authorizationResponse = await app.fetch(new Request('https://morsel.test/authorize', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code_challenge: challenge,
        code_challenge_method: 'S256',
        email: 'test@example.com',
        password: 'correct-password',
        redirect_uri: redirectUri,
        response_type: 'code',
      }),
    }))
    const callback = new URL(authorizationResponse.headers.get('location') ?? '')
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
    const authorizationResponse = await app.fetch(new Request('https://morsel.test/authorize', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code_challenge: challenge,
        code_challenge_method: 'S256',
        email: 'test@example.com',
        password: 'correct-password',
        redirect_uri: 'https://client.example/callback',
        response_type: 'code',
      }),
    }))
    const callback = new URL(authorizationResponse.headers.get('location') ?? '')
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

describe('Supabase OAuth service', () => {
  it('validates the Supabase session access token before returning it', async () => {
    const requests: Request[] = []
    const fetchMock = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      const request = input instanceof Request
        ? new Request(input, init)
        : new Request(input.toString(), init)
      requests.push(request)
      if (request.url.includes('/token?grant_type=password')) {
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

    await expect(service.authenticate('test@example.com', 'password')).resolves.toMatchObject({
      accessToken: 'issued-access-token',
      userId: '00000000-0000-4000-8000-000000000002',
    })
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

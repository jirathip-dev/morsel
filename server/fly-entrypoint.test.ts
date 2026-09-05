import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createFlyEntrypointApp, type FlyEntrypointDependencies, type FlyEntrypointEnv } from './fly-entrypoint.js'
import type { Authenticate } from './auth.js'
import { InMemoryRepository } from './in-memory-repository.js'
import type { OAuthAuthorizationGrant, OAuthGrantStore, OAuthIdentityService, OAuthUserSession } from './oauth.js'

// Synthetic, non-secret values: the canonical public base (the
// mcp.morselfood.app custom domain since #130) and the Vercel consent page
// URL are the values production docs will configure. No request in this
// suite ever leaves the process (Supabase hosts use .invalid).
const CANONICAL = 'https://mcp.morselfood.app/mcp'
const AUTHORIZE_PAGE = 'https://morsel-authorize-ui.vercel.app/authorize'
const TEST_USER_ID = '00000000-0000-4000-8000-000000000002'

function baseEnv(overrides: Record<string, string | undefined> = {}): FlyEntrypointEnv {
  return {
    SUPABASE_URL: 'https://supabase.invalid',
    SUPABASE_ANON_KEY: 'test-anon-key',
    MORSEL_OAUTH_SIGNING_KEY: 'test-signing-key',
    MORSEL_PUBLIC_BASE_URL: CANONICAL,
    ...overrides,
  }
}

const neverReached: Authenticate = () => Promise.reject(new Error('authentication should not be reached'))

function stubIdentityService(): OAuthIdentityService {
  return {
    requestCode(): Promise<void> {
      return Promise.resolve()
    },
    verifyCode(email: string, code: string): Promise<OAuthUserSession> {
      if (code !== '123456') {
        return Promise.reject(new Error('invalid code'))
      }
      return Promise.resolve({
        userId: TEST_USER_ID,
        email,
        accessToken: 'supabase-access-token',
        refreshToken: 'supabase-refresh-token',
        expiresIn: 3600,
      })
    },
    refresh(): Promise<OAuthUserSession> {
      return Promise.resolve({
        userId: TEST_USER_ID,
        email: 'test@example.com',
        accessToken: 'supabase-access-token-rotated',
        refreshToken: 'supabase-refresh-token',
        expiresIn: 3600,
      })
    },
  }
}

// An in-memory grant store that never has grants: enough to prove the /token
// route exists over the Fly shape without contacting Supabase (claim of a
// made-up code returns undefined -> invalid_grant 400).
function emptyGrantStore(): OAuthGrantStore {
  return {
    create(): Promise<void> {
      return Promise.resolve()
    },
    claim(): Promise<OAuthAuthorizationGrant | undefined> {
      return Promise.resolve(undefined)
    },
  }
}

function flyDependencies(): FlyEntrypointDependencies {
  return {
    authenticate: neverReached,
    repositoryFactory: () => new InMemoryRepository(),
    oauth: {
      service: stubIdentityService(),
      grantStore: emptyGrantStore(),
    },
  }
}

function createFlyApp(env: FlyEntrypointEnv = baseEnv(), deps: FlyEntrypointDependencies = flyDependencies()) {
  return createFlyEntrypointApp({ env, deps })
}

function jsonRequest(path: string, init: RequestInit = {}): Request {
  return new Request(`https://fly.test${path}`, {
    headers: { 'content-type': 'application/json' },
    ...init,
  })
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

async function registerClient(app: ReturnType<typeof createFlyApp>['app']): Promise<string> {
  const response = await app.fetch(jsonRequest('/mcp/register', {
    method: 'POST',
    body: JSON.stringify({ redirect_uris: ['https://client.example/callback'] }),
  }))
  expect(response.status).toBe(201)
  return stringProperty(await response.json(), 'client_id')
}

describe('Fly entry point environment validation (fail closed)', () => {
  it('requires every production environment value to be present and nonblank', () => {
    for (const name of ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'MORSEL_OAUTH_SIGNING_KEY', 'MORSEL_PUBLIC_BASE_URL']) {
      const env = Object.fromEntries(Object.entries(baseEnv()).filter(([key]) => key !== name))
      expect(() => createFlyApp(env), name).toThrow(/missing server configuration/)
    }
    expect(() => createFlyApp(baseEnv({ SUPABASE_URL: '   ' }))).toThrow(/missing server configuration: SUPABASE_URL/)
  })

  it('rejects surrounding whitespace on required values', () => {
    expect(() => createFlyApp(baseEnv({ SUPABASE_ANON_KEY: ' padded-key ' }))).toThrow(/must not contain surrounding whitespace/)
  })

  it('rejects non-HTTPS public bases except on loopback hosts', () => {
    expect(() => createFlyApp(baseEnv({ MORSEL_PUBLIC_BASE_URL: 'http://mcp.morselfood.app/mcp' })))
      .toThrow(/absolute HTTPS \(http is allowed only for loopback hosts\)/)
    const loopback = createFlyApp(baseEnv({ MORSEL_PUBLIC_BASE_URL: 'http://127.0.0.1:8080/mcp' }))
    expect(loopback.config.publicBaseUrl).toBe('http://127.0.0.1:8080/mcp')
    const localhost = createFlyApp(baseEnv({ MORSEL_PUBLIC_BASE_URL: 'http://localhost:3000/mcp' }))
    expect(localhost.config.publicBaseUrl).toBe('http://localhost:3000/mcp')
  })

  it('rejects userinfo, query strings, fragments, and whitespace in the public base', () => {
    const cases: Array<[string, RegExp]> = [
      ['https://user:secret@mcp.morselfood.app/mcp', /must not include userinfo/],
      ['https://mcp.morselfood.app/mcp?region=nrt', /must not include a query string or fragment/],
      ['https://mcp.morselfood.app/mcp#consent', /must not include a query string or fragment/],
      ['https://mcp.morselfood.app/m cp', /must not contain whitespace or control characters/],
    ]
    for (const [value, message] of cases) {
      expect(() => createFlyApp(baseEnv({ MORSEL_PUBLIC_BASE_URL: value })), value).toThrow(message)
    }
  })

  it('rejects unstable or doubled public-base path shapes', () => {
    // A doubled prefix (/mcp/mcp) or any other path than the canonical
    // transport would make metadata advertise routes that are not served, so
    // the entry point refuses to start instead of serving a broken origin.
    const cases: Array<[string, RegExp]> = [
      ['https://mcp.morselfood.app', /path must be exactly \/mcp/],
      ['https://mcp.morselfood.app/', /path must be exactly \/mcp/],
      ['https://mcp.morselfood.app/mcp/', /path must be exactly \/mcp/],
      ['https://mcp.morselfood.app/mcp/mcp', /path must be exactly \/mcp/],
      ['https://mcp.morselfood.app/mcp/mcp/', /path must be exactly \/mcp/],
      ['https://mcp.morselfood.app/functions/v1/mcp', /path must be exactly \/mcp/],
      ['https://mcp.morselfood.app/mcp-extra', /path must be exactly \/mcp/],
    ]
    for (const [value, message] of cases) {
      expect(() => createFlyApp(baseEnv({ MORSEL_PUBLIC_BASE_URL: value })), value).toThrow(message)
    }
  })

  it('rejects invalid PORT values and defaults to 8080', () => {
    expect(createFlyApp().config.port).toBe(8080)
    expect(createFlyApp(baseEnv({ PORT: '9090' })).config.port).toBe(9090)
    for (const port of ['0', '-1', '70000', 'not-a-port']) {
      expect(() => createFlyApp(baseEnv({ PORT: port })), port).toThrow(/PORT must be an integer between 1 and 65535/)
    }
  })

  it('accepts the production-style canonical HTTPS base unchanged', () => {
    const { config } = createFlyApp()
    expect(config.publicBaseUrl).toBe(CANONICAL)
    expect(config.basePath).toBe('/mcp')
    expect(config.authorizationEndpoint).toBeUndefined()
  })

  it('accepts an optional external authorization endpoint (Vercel consent page)', () => {
    const { config } = createFlyApp(baseEnv({ MORSEL_OAUTH_AUTHORIZATION_ENDPOINT: AUTHORIZE_PAGE }))
    expect(config.authorizationEndpoint).toBe(AUTHORIZE_PAGE)
  })
})

describe('Fly origin route and metadata contract', () => {
  it('serves the health check at the origin root and nowhere under /mcp', async () => {
    const { app } = createFlyApp()
    const health = await app.fetch(new Request('https://fly.test/health'))
    expect(health.status).toBe(200)
    expect(await health.json()).toEqual({ ok: true })
    const prefixed = await app.fetch(new Request('https://fly.test/mcp/health'))
    expect(prefixed.status).toBe(404)
  })

  it('serves the MCP transport exactly at /mcp with no doubled-prefix routes', async () => {
    const { app } = createFlyApp()
    // The canonical transport lives at /mcp; without credentials the bearer
    // challenge (401), not a 404, proves the transport route is registered.
    const transport = await app.fetch(jsonRequest('/mcp', {
      method: 'POST',
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
    }))
    expect(transport.status).toBe(401)
    expect(transport.headers.get('www-authenticate')).toContain(
      `resource_metadata="${CANONICAL}/.well-known/oauth-protected-resource/mcp"`,
    )

    // No pre-#57 alias on a fresh origin: the nested path must be dead.
    for (const method of ['POST', 'OPTIONS']) {
      const nested = await app.fetch(jsonRequest('/mcp/mcp', { method }))
      expect(nested.status, method).toBe(404)
    }
    // No transport at the origin root either.
    const root = await app.fetch(jsonRequest('/', { method: 'POST' }))
    expect(root.status).toBe(404)
  })

  it('advertises issuer, endpoints, resource, and challenge all on the canonical Fly base', async () => {
    const { app } = createFlyApp(baseEnv({ MORSEL_OAUTH_AUTHORIZATION_ENDPOINT: AUTHORIZE_PAGE }))
    const authorizationServer = await app.fetch(new Request('https://fly.test/mcp/.well-known/oauth-authorization-server'))
    expect(authorizationServer.status).toBe(200)
    expect(authorizationServer.headers.get('access-control-allow-origin')).toBe('*')
    const metadata = await authorizationServer.json()
    expect(metadata).toMatchObject({
      issuer: CANONICAL,
      authorization_endpoint: AUTHORIZE_PAGE,
      token_endpoint: `${CANONICAL}/token`,
      registration_endpoint: `${CANONICAL}/register`,
      code_challenge_methods_supported: ['S256'],
      grant_types_supported: ['authorization_code', 'refresh_token'],
    })

    const protectedResource = await app.fetch(new Request('https://fly.test/mcp/.well-known/oauth-protected-resource/mcp'))
    expect(protectedResource.status).toBe(200)
    const protectedResourceDocument = await protectedResource.json()
    expect(protectedResourceDocument).toMatchObject({
      resource: CANONICAL,
      authorization_servers: [CANONICAL],
      scopes_supported: ['mcp'],
    })

    // No gateway artifacts, no doubled prefix, no nested-alias advertisement.
    for (const document of [JSON.stringify(metadata), JSON.stringify(protectedResourceDocument)]) {
      expect(document).not.toContain('/functions/v1')
      expect(document).not.toContain('/mcp/mcp')
    }
  })

  it('serves the OIDC-named discovery document at the issuer-appended path', async () => {
    // Issue #59: spec clients append /.well-known/openid-configuration to the
    // path issuer; on the Fly origin that is .../mcp/.well-known/openid-configuration.
    const { app } = createFlyApp()
    const openId = await app.fetch(new Request('https://fly.test/mcp/.well-known/openid-configuration'))
    expect(openId.status).toBe(200)
    const authorizationServer = await app.fetch(new Request('https://fly.test/mcp/.well-known/oauth-authorization-server'))
    expect(await openId.json()).toEqual(await authorizationServer.json())
  })

  it('serves no discovery at the origin root (metadata never duplicated)', async () => {
    const { app } = createFlyApp()
    for (const path of [
      '/.well-known/oauth-authorization-server',
      '/.well-known/openid-configuration',
      '/.well-known/oauth-protected-resource',
      '/.well-known/oauth-protected-resource/mcp',
    ]) {
      const response = await app.fetch(new Request(`https://fly.test${path}`))
      expect(response.status, path).toBe(404)
    }
  })

  it('serves /register, /authorize, and /token at the advertised Fly routes', async () => {
    const { app } = createFlyApp(baseEnv({ MORSEL_OAUTH_AUTHORIZATION_ENDPOINT: AUTHORIZE_PAGE }))
    const clientId = await registerClient(app)
    const params = new URLSearchParams({
      client_id: clientId,
      code_challenge: 'challenge-value',
      code_challenge_method: 'S256',
      redirect_uri: 'https://client.example/callback',
      response_type: 'code',
    })

    // Direct visits still render the server-side email stage (fallback).
    const authorize = await app.fetch(new Request(`https://fly.test/mcp/authorize?${params.toString()}`))
    expect(authorize.status).toBe(200)
    expect(authorize.headers.get('content-type')).toBe('text/html; charset=utf-8')

    // Stage 1 from the configured consent page: bodyless 302 back to it.
    const stageOne = await app.fetch(new Request(`https://fly.test/mcp/authorize?${params.toString()}`, {
      method: 'POST',
      body: new URLSearchParams({ email: 'consent@example.com' }),
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
    }))
    expect(stageOne.status).toBe(302)
    const location = stageOne.headers.get('location') ?? ''
    expect(location.startsWith(`${AUTHORIZE_PAGE}?`)).toBe(true)
    expect(location).toContain('transaction=')

    // Token exchange with an unknown code fails as invalid_grant (400), which
    // proves the route is the OAuth token endpoint and not a 404.
    const token = await app.fetch(new Request('https://fly.test/mcp/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        code: 'made-up-code',
        code_verifier: 'challenge-value',
        grant_type: 'authorization_code',
        redirect_uri: 'https://client.example/callback',
      }),
    }))
    expect(token.status).toBe(400)
    expect(stringProperty(await token.json(), 'error')).toBe('invalid_grant')
  })

  it('derives metadata from the configured public base, never from the request host', async () => {
    // The request host below is deliberately NOT the canonical host; issuer
    // and challenge URLs must still be the configured Fly base.
    const { app } = createFlyApp()
    const discovery = await app.fetch(new Request('http://127.0.0.1:39999/mcp/.well-known/oauth-authorization-server'))
    expect(discovery.status).toBe(200)
    expect(stringProperty(await discovery.json(), 'issuer')).toBe(CANONICAL)
  })

  it('keeps the server-rendered consent fallback when the endpoint env is unset', async () => {
    const { app } = createFlyApp()
    const metadata = await (await app.fetch(new Request('https://fly.test/mcp/.well-known/oauth-authorization-server'))).json()
    expect(metadata).toMatchObject({
      issuer: CANONICAL,
      authorization_endpoint: `${CANONICAL}/authorize`,
    })
  })
})

describe('Fly entry point wiring pins', () => {
  it('wires the real Supabase factories and the Fly origin route flags in source', () => {
    // Runtime construction of the default wiring is network-free (Supabase
    // clients are lazy), but the wiring only executes per request against
    // live Supabase Auth, which tests cannot safely contact. The committed
    // behavioral suites inject stubs through the narrow seams; this source
    // pin proves the DEFAULT wiring still mirrors the Edge Function entry
    // point (supabase/functions/mcp/index.ts) and keeps the Fly route shape.
    const source = readFileSync(new URL('./fly-entrypoint.ts', import.meta.url), 'utf8')
    expect(source).toContain('createSupabaseAuthenticator({ supabaseUrl, anonKey })')
    expect(source).toContain('createSupabaseRepository(supabaseUrl, anonKey)')
    expect(source).toContain('basePath: FLY_BASE_PATH')
    expect(source).toContain('originHealth: true')
    expect(source).toContain('legacyTransportAlias: false')
    for (const name of ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'MORSEL_OAUTH_SIGNING_KEY', 'MORSEL_PUBLIC_BASE_URL']) {
      expect(source).toContain(name)
    }
    expect(source).toContain('MORSEL_OAUTH_AUTHORIZATION_ENDPOINT')
    // Never log configuration, credentials, or tokens.
    expect(source).not.toContain('console.')
    expect(source).not.toContain('process.env.SUPABASE')
  })

  it('guards the opt-in nature of the new route options in the shared app', () => {
    // The Edge Function shape (basePath: '/mcp' only) must stay exactly as it
    // is: originHealth and the alias toggle must default to the historical
    // behavior or every existing basePath test would break.
    const source = readFileSync(new URL('./app.ts', import.meta.url), 'utf8')
    expect(source).toContain('originHealth === true && routes !== app')
    expect(source).toContain('legacyTransportAlias !== false')
  })
})

describe('Fly deploy materials static contract', () => {
  const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

  it('fly.toml describes one always-on nrt machine with a /health check and no scaling', () => {
    const fly = readFileSync(join(repoRoot, 'fly.toml'), 'utf8')
    expect(fly).toContain('app = "morsel-mcp"')
    expect(fly).toContain('primary_region = "nrt"')
    expect(fly).toContain('[http_service]')
    expect(fly).toContain('internal_port = 8080')
    expect(fly).toContain('force_https = true')
    expect(fly).toContain('auto_stop_machines = false')
    expect(fly).toContain('auto_start_machines = true')
    expect(fly).toContain('min_machines_running = 1')
    expect(fly).toContain('[[http_service.checks]]')
    expect(fly).toContain('path = "/health"')
    // No multi-process or autoscaling shapes.
    expect(fly).not.toContain('[[services]]')
    expect(fly).not.toContain('[processes]')
    expect(fly).not.toContain('auto_destroy')
    expect(fly).not.toContain('max_machines_running')
    // No environment/secret values live in the manifest.
    expect(fly).not.toContain('[env]')
    expect(fly).not.toContain('SUPABASE')
    expect(fly).not.toContain('MORSEL_OAUTH_SIGNING_KEY')
  })

  it('Dockerfile pins oven/bun, installs from the lockfile, runs non-root on 8080', () => {
    const dockerfile = readFileSync(join(repoRoot, 'Dockerfile'), 'utf8')
    expect(dockerfile).toMatch(/^FROM oven\/bun:1\.2\.\d+-debian$/m)
    expect(dockerfile).toContain('bun install --no-progress')
    expect(dockerfile).toContain('COPY package.json package-lock.json ./')
    expect(dockerfile).toContain('COPY server ./server')
    expect(dockerfile).toContain('COPY packages ./packages')
    expect(dockerfile).toContain('EXPOSE 8080')
    expect(dockerfile).toContain('USER bun')
    expect(dockerfile).toContain('CMD ["bun", "server/fly-entrypoint.ts"]')
    // No secret values in image config.
    expect(dockerfile).not.toContain('SUPABASE_URL=')
    expect(dockerfile).not.toContain('ANON_KEY=')
    expect(dockerfile).not.toContain('SIGNING_KEY=')
  })

  it('.dockerignore excludes secrets, git, and build noise', () => {
    const ignore = readFileSync(join(repoRoot, '.dockerignore'), 'utf8')
    expect(ignore).toContain('.git')
    expect(ignore).toContain('node_modules')
    expect(ignore).toContain('.env*')
    expect(ignore).toContain('docs')
    expect(ignore).toContain('app')
    expect(ignore).not.toMatch(/^server$/m)
    expect(ignore).not.toMatch(/^packages$/m)
  })
})

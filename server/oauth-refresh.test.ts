import { afterEach, describe, expect, it, vi } from 'vitest'
import type { Hono } from 'hono'
import { createMorselApp } from './app.js'
import { InMemoryRepository } from './in-memory-repository.js'
import type { OAuthAuthorizationGrant, OAuthGrantStore, OAuthIdentityService } from './oauth.js'
import { createSupabaseOAuthService } from './oauth.js'

// Issue #120 refresh-grant scenarios. The identity service is the REAL
// createSupabaseOAuthService wired to a Supabase-shaped fetch harness that
// emulates GoTrue Auth refresh-token semantics: every successful refresh
// rotates the session (the old refresh token becomes dead), a reused
// rotated-out token fails with invalid_grant unless the project reuse
// interval allows it (then the CURRENT session is returned), and a revoked
// session fails with the upstream "Refresh Token Not Found" message. This is
// the repo's established Supabase integration style (see the Supabase OAuth
// service describe block in oauth.test.ts) — no live project is touched.

const USER_ID = '00000000-0000-4000-8000-000000000002'
const USER_EMAIL = 'test@example.com'
const TEST_REDIRECT_URI = 'https://client.example/callback'
const SUPABASE_BASE = 'https://morsel.test'
const REFRESH_NOT_FOUND_MESSAGE = 'Invalid Refresh Token: Refresh Token Not Found'
const TOKEN_ENDPOINT_FAILURE_PREFIX = 'oauth token endpoint failure'
const TOKEN_ENDPOINT_SUCCESS_PREFIX = 'oauth token endpoint success'
const CLIENT_REBOUND_PREFIX = 'oauth refresh token client rebound'

interface SupabaseShapedHarness {
  service: OAuthIdentityService
  fetchMock: typeof fetch
  refreshCalls(): number
  revokeSession(): void
}

// GoTrue-shaped session/error bodies understood by @supabase/auth-js.
function authSessionBody(accessToken: string, refreshToken: string): Record<string, unknown> {
  return {
    access_token: accessToken,
    expires_in: 3600,
    refresh_token: refreshToken,
    token_type: 'bearer',
    user: { id: USER_ID, email: USER_EMAIL },
  }
}

function authErrorBody(message: string): Record<string, unknown> {
  return { code: 400, error_code: 'refresh_token_not_found', msg: message }
}

function createSupabaseShapedHarness(reuseIntervalMs = 0): SupabaseShapedHarness {
  interface SupabaseSession {
    accessToken: string
    refreshToken: string
  }
  const superseded: { token: string; rotatedAtMs: number }[] = []
  let revoked = false
  let current: SupabaseSession = { accessToken: 'access-token-0', refreshToken: 'refresh-token-0' }
  let refreshCount = 0
  let sequence = 0

  const rotate = (): SupabaseSession => {
    superseded.push({ token: current.refreshToken, rotatedAtMs: Date.now() })
    sequence += 1
    current = { accessToken: `access-token-${String(sequence)}`, refreshToken: `refresh-token-${String(sequence)}` }
    return current
  }

  const fetchMock = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const request = input instanceof Request ? new Request(input, init) : new Request(input.toString(), init)
    const body = request.method === 'GET' ? undefined : await request.text()
    const url = new URL(request.url)
    const headers = { 'content-type': 'application/json' }
    const json = (value: unknown, status = 200): Response => new Response(JSON.stringify(value), { status, headers })
    if (url.pathname === '/auth/v1/token' && url.searchParams.get('grant_type') === 'refresh_token') {
      refreshCount += 1
      const parsed: unknown = body === undefined ? undefined : JSON.parse(body)
      const presented = isRecord(parsed) && typeof parsed.refresh_token === 'string' ? parsed.refresh_token : ''
      if (revoked) {
        return json(authErrorBody(REFRESH_NOT_FOUND_MESSAGE), 400)
      }
      if (presented === current.refreshToken) {
        const rotatedSession = rotate()
        return json(authSessionBody(rotatedSession.accessToken, rotatedSession.refreshToken))
      }
      const reused = superseded.find((entry) => entry.token === presented)
      if (reused !== undefined && reuseIntervalMs > 0 && Date.now() - reused.rotatedAtMs <= reuseIntervalMs) {
        // GoTrue reuse-interval semantics: the rotated-out token still maps to
        // the CURRENT session of the family within the interval.
        return json(authSessionBody(current.accessToken, current.refreshToken))
      }
      return json(authErrorBody(REFRESH_NOT_FOUND_MESSAGE), 400)
    }
    if (url.pathname === '/auth/v1/otp') {
      return json({})
    }
    if (url.pathname === '/auth/v1/verify') {
      return json(authSessionBody(current.accessToken, current.refreshToken))
    }
    if (url.pathname === '/auth/v1/user') {
      return json({ id: USER_ID, email: USER_EMAIL })
    }
    return json(authErrorBody(`unexpected Supabase request: ${request.method} ${url.pathname}`), 404)
  }
  fetchMock.preconnect = (): void => undefined

  return {
    service: createSupabaseOAuthService({ anonKey: 'test-anon-key', fetch: fetchMock, supabaseUrl: SUPABASE_BASE }),
    fetchMock,
    refreshCalls: () => refreshCount,
    revokeSession: () => {
      revoked = true
    },
  }
}

interface TestGrantStore extends OAuthGrantStore {
  grants: Map<string, OAuthAuthorizationGrant>
}

function createTestGrantStore(): TestGrantStore {
  const grants = new Map<string, OAuthAuthorizationGrant>()
  return {
    grants,
    create: (grant) => {
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

interface TestClock {
  now: () => number
  tick: (ms: number) => void
}

function createTestClock(): TestClock {
  let value = 1_800_000_000_000
  return {
    now: () => value,
    tick: (ms) => {
      value += ms
    },
  }
}

function createApp(service: OAuthIdentityService, clock?: TestClock): Hono {
  const oauthOptions = Object.assign({
    grantStore: createTestGrantStore(),
    signingKey: 'oauth-refresh-test-signing-key',
    service,
  }, clock === undefined ? {} : { now: clock.now })
  return createMorselApp({
    authenticate: () => Promise.reject(new Error('not reached')),
    repositoryFactory: () => new InMemoryRepository(),
    oauth: oauthOptions,
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

function transactionValue(html: string): string {
  const match = /name="transaction" value="([^"]+)"/.exec(html)
  if (match?.[1] === undefined) {
    throw new Error('missing transaction envelope')
  }
  return match[1]
}

async function s256Challenge(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))
  return btoa(String.fromCharCode(...new Uint8Array(digest))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

async function registerClient(app: Hono, redirectUris: string[] = [TEST_REDIRECT_URI], clientName?: string): Promise<string> {
  const body: Record<string, unknown> = { redirect_uris: redirectUris }
  if (clientName !== undefined) {
    body.client_name = clientName
  }
  const response = await app.fetch(new Request(`${SUPABASE_BASE}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  }))
  expect(response.status).toBe(201)
  return stringProperty(await response.json(), 'client_id')
}

interface TokenPair {
  accessToken: string
  refreshToken: string
}

async function responseTokens(response: Response): Promise<TokenPair> {
  expect(response.status).toBe(200)
  const body: unknown = await response.json()
  return { accessToken: stringProperty(body, 'access_token'), refreshToken: stringProperty(body, 'refresh_token') }
}

const TEST_VERIFIER = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-._~'

async function exchangeTokenRequest(
  app: Hono,
  clientId: string,
  code: string,
  redirectUri: string,
  resource?: string,
): Promise<Response> {
  const params: Record<string, string> = {
    client_id: clientId,
    code,
    code_verifier: TEST_VERIFIER,
    grant_type: 'authorization_code',
    redirect_uri: redirectUri,
  }
  if (resource !== undefined) {
    params.resource = resource
  }
  return await app.fetch(new Request(`${SUPABASE_BASE}/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params).toString(),
  }))
}

// Runs the full email-code authorization + PKCE token exchange and returns the
// first OAuth refresh token for the given client, optionally carrying the
// RFC 8707 resource through the whole authorization.
async function completeAuthorization(
  app: Hono,
  clientId: string,
  redirectUri = TEST_REDIRECT_URI,
  resource?: string,
): Promise<TokenPair> {
  const challenge = await s256Challenge(TEST_VERIFIER)
  const authorizationParams = new URLSearchParams({
    client_id: clientId,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    redirect_uri: redirectUri,
    response_type: 'code',
  })
  if (resource !== undefined) {
    authorizationParams.set('resource', resource)
  }
  const stepOne = await app.fetch(new Request(`${SUPABASE_BASE}/authorize`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      ...Object.fromEntries(authorizationParams),
      email: USER_EMAIL,
    }).toString(),
  }))
  expect(stepOne.status).toBe(200)
  const transaction = transactionValue(await stepOne.text())
  const stepTwo = await app.fetch(new Request(`${SUPABASE_BASE}/authorize`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      ...Object.fromEntries(authorizationParams),
      transaction,
      code: '123456',
    }).toString(),
  }))
  expect(stepTwo.status).toBe(302)
  const callback = new URL(stepTwo.headers.get('location') ?? '')
  expect(callback.origin + callback.pathname).toBe(redirectUri)
  const code = callback.searchParams.get('code') ?? ''
  expect(code).not.toBe('')
  const tokenResponse = await exchangeTokenRequest(app, clientId, code, redirectUri, resource)
  return await responseTokens(tokenResponse)
}

async function refreshRequest(app: Hono, clientId: string, refreshToken: string, resource?: string): Promise<Response> {
  const params: Record<string, string> = {
    client_id: clientId,
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
  }
  if (resource !== undefined) {
    params.resource = resource
  }
  return await app.fetch(new Request(`${SUPABASE_BASE}/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params).toString(),
  }))
}

function logCalls(spy: ReturnType<typeof vi.spyOn>, prefix: string): string[] {
  return spy.mock.calls
    .map((call) => (typeof call[0] === 'string' ? call[0] : ''))
    .filter((line) => line.startsWith(prefix))
}

function parsedLogPayload(line: string, prefix: string): Record<string, unknown> {
  const payload: unknown = JSON.parse(line.slice(prefix.length).trim())
  if (!isRecord(payload)) {
    throw new Error('log line payload is not an object')
  }
  return payload
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('OAuth refresh grant hardening (issue #120)', () => {
  it('scenario (b): three consecutive refreshes with correctly rotated tokens succeed', async () => {
    const harness = createSupabaseShapedHarness()
    const app = createApp(harness.service)
    const clientId = await registerClient(app)
    const first = await completeAuthorization(app, clientId)
    const expectedRefreshTokens = new Set<string>([first.refreshToken])

    const second = await responseTokens(await refreshRequest(app, clientId, first.refreshToken))
    expect(second.accessToken).toBe('access-token-2')
    const third = await responseTokens(await refreshRequest(app, clientId, second.refreshToken))
    expect(third.accessToken).toBe('access-token-3')
    const fourth = await responseTokens(await refreshRequest(app, clientId, third.refreshToken))
    expect(fourth.accessToken).toBe('access-token-4')

    expectedRefreshTokens.add(second.refreshToken)
    expectedRefreshTokens.add(third.refreshToken)
    expectedRefreshTokens.add(fourth.refreshToken)
    // Every response rotated the Supabase session: all four wrappers differ.
    expect(expectedRefreshTokens.size).toBe(4)
    // The authorization-code exchange plus three refreshes = four upstream calls.
    expect(harness.refreshCalls()).toBe(4)
  })

  it('scenario (a): a duplicate refresh with the same OAuth refresh token inside the reuse window returns the current session instead of 400', async () => {
    const harness = createSupabaseShapedHarness()
    const app = createApp(harness.service)
    const clientId = await registerClient(app)
    const first = await completeAuthorization(app, clientId)

    // First use rotates the session (exchange + this refresh = two upstream calls).
    const rotated = await responseTokens(await refreshRequest(app, clientId, first.refreshToken))
    expect(rotated.accessToken).toBe('access-token-2')
    expect(harness.refreshCalls()).toBe(2)

    // Duplicate use of the SAME wrapper within the reuse window: the server
    // answers from the in-memory flight cache with the current session instead
    // of presenting the already-rotated Supabase token again (which 400s).
    const duplicate = await refreshRequest(app, clientId, first.refreshToken)
    expect(duplicate.status).toBe(200)
    const duplicateBody = await responseTokens(duplicate)
    expect(duplicateBody.accessToken).toBe('access-token-2')
    expect(duplicateBody.refreshToken).not.toBe(first.refreshToken)
    expect(harness.refreshCalls()).toBe(2)
  })

  it('scenario (a): concurrent duplicate refreshes share one upstream refresh (single-flight)', async () => {
    const harness = createSupabaseShapedHarness()
    const app = createApp(harness.service)
    const clientId = await registerClient(app)
    const first = await completeAuthorization(app, clientId)

    const [left, right] = await Promise.all([
      refreshRequest(app, clientId, first.refreshToken),
      refreshRequest(app, clientId, first.refreshToken),
    ])
    expect(left.status).toBe(200)
    expect(right.status).toBe(200)
    const leftTokens = await responseTokens(left)
    const rightTokens = await responseTokens(right)
    expect(leftTokens.accessToken).toBe(rightTokens.accessToken)
    expect(leftTokens.accessToken).toBe('access-token-2')
    // Exchange plus exactly ONE refresh call: the duplicates were single-flighted.
    expect(harness.refreshCalls()).toBe(2)
  })

  it('scenario (c): a refresh that omits resource after a resource-bearing authorization matches (RFC 8707)', async () => {
    const resource = `${SUPABASE_BASE}/mcp`
    const harness = createSupabaseShapedHarness()
    const app = createApp(harness.service)
    const clientId = await registerClient(app)
    const first = await completeAuthorization(app, clientId, TEST_REDIRECT_URI, resource)

    // Omitting resource on refresh is allowed (RFC 8707 section 3).
    const omitted = await responseTokens(await refreshRequest(app, clientId, first.refreshToken))
    expect(omitted.accessToken).toBe('access-token-2')

    // The rotation chain continues with resource still omitted.
    const chained = await responseTokens(await refreshRequest(app, clientId, omitted.refreshToken))
    expect(chained.accessToken).toBe('access-token-3')

    // Two explicit URLs that differ stay a hard mismatch.
    const mismatched = await refreshRequest(app, clientId, chained.refreshToken, `${SUPABASE_BASE}/other`)
    expect(mismatched.status).toBe(400)
    const mismatchBody: unknown = await mismatched.json()
    expect(mismatchBody).toMatchObject({ error: 'invalid_grant', error_description: 'resource does not match authorization request' })
  })

  it('scenario (d): refresh with a client_id from a later identical re-registration is accepted, logged, and re-sealed to the new client', async () => {
    const harness = createSupabaseShapedHarness()
    const app = createApp(harness.service)
    const firstClientId = await registerClient(app)
    const first = await completeAuthorization(app, firstClientId)

    // The client re-registers with identical metadata after a token was sealed
    // to the first client id (the field pattern behind every hourly failure).
    // Client ids embed a second-granular issuedAt, so the re-registration must
    // cross a second boundary to mint a DIFFERENT id for the same metadata.
    await new Promise((resolve) => setTimeout(resolve, 1_100))
    const secondClientId = await registerClient(app)
    expect(secondClientId).not.toBe(firstClientId)
    const warnSpy = vi.spyOn(console, 'warn')

    const rebound = await refreshRequest(app, secondClientId, first.refreshToken)
    expect(rebound.status).toBe(200)
    const reboundTokens = await responseTokens(rebound)
    expect(reboundTokens.accessToken).toBe('access-token-2')

    const reboundLogs = logCalls(warnSpy, CLIENT_REBOUND_PREFIX)
    expect(reboundLogs).toHaveLength(1)
    const reboundPayload = parsedLogPayload(reboundLogs[0] ?? '', CLIENT_REBOUND_PREFIX)
    expect(reboundPayload.client_id).toEqual(expect.any(String))
    expect(reboundPayload.previous_client_id).toEqual(expect.any(String))
    expect(reboundPayload.client_id).not.toBe(reboundPayload.previous_client_id)

    // The wrapper is re-sealed to the presenting (new) client id, so the chain
    // continues strictly on the new registration.
    const chained = await refreshRequest(app, secondClientId, reboundTokens.refreshToken)
    expect(chained.status).toBe(200)
    const chainedTokens = await responseTokens(chained)
    expect(chainedTokens.accessToken).toBe('access-token-3')
  })

  it('keeps the strict client check when a later re-registration changes redirect_uris', async () => {
    const harness = createSupabaseShapedHarness()
    const app = createApp(harness.service)
    const firstClientId = await registerClient(app)
    const first = await completeAuthorization(app, firstClientId)
    const differentClientId = await registerClient(app, ['https://other.example/callback'])
    const warnSpy = vi.spyOn(console, 'warn')

    const attempt = await refreshRequest(app, differentClientId, first.refreshToken)
    expect(attempt.status).toBe(400)
    const body: unknown = await attempt.json()
    expect(body).toMatchObject({ error: 'invalid_grant', error_description: 'refresh token is invalid' })
    expect(logCalls(warnSpy, CLIENT_REBOUND_PREFIX)).toHaveLength(0)
  })

  it('fix-1: logs one structured failure line per token-endpoint failure with a fingerprint and no token material', async () => {
    const harness = createSupabaseShapedHarness()
    const app = createApp(harness.service)
    const clientId = await registerClient(app)
    const minted = await completeAuthorization(app, clientId)
    const errorSpy = vi.spyOn(console, 'error')

    const response = await refreshRequest(app, clientId, 'not-a-real-sealed-token-xyz')
    expect(response.status).toBe(400)
    const body: unknown = await response.json()
    expect(body).toMatchObject({ error: 'invalid_grant', error_description: 'token is invalid' })

    const failureLogs = logCalls(errorSpy, TOKEN_ENDPOINT_FAILURE_PREFIX)
    expect(failureLogs).toHaveLength(1)
    const payload = parsedLogPayload(failureLogs[0] ?? '', TOKEN_ENDPOINT_FAILURE_PREFIX)
    expect(payload.grant_type).toBe('refresh_token')
    expect(payload.error).toBe('invalid_grant')
    expect(payload.error_description).toBe('token is invalid')
    expect(payload.resource).toBe(false)
    expect(typeof payload.client_id).toBe('string')
    expect(String(payload.client_id)).toMatch(/^[A-Za-z0-9_-]{8}$/)
    // The client fingerprint, never the raw client id or any token value.
    const logText = failureLogs[0] ?? ''
    expect(logText).not.toContain(clientId)
    expect(logText).not.toContain(minted.accessToken)
    expect(logText).not.toContain(minted.refreshToken)
    expect(logText).not.toContain('not-a-real-sealed-token-xyz')
  })

  it('fix-1: logs successful refreshes at debug level with the same client fingerprint', async () => {
    const harness = createSupabaseShapedHarness()
    const app = createApp(harness.service)
    const clientId = await registerClient(app)
    const first = await completeAuthorization(app, clientId)
    const debugSpy = vi.spyOn(console, 'debug')

    const refreshed = await refreshRequest(app, clientId, first.refreshToken)
    expect(refreshed.status).toBe(200)

    const successLogs = logCalls(debugSpy, TOKEN_ENDPOINT_SUCCESS_PREFIX)
    expect(successLogs).toHaveLength(1)
    const payload = parsedLogPayload(successLogs[0] ?? '', TOKEN_ENDPOINT_SUCCESS_PREFIX)
    expect(payload.grant_type).toBe('refresh_token')
    expect(payload.resource).toBe(false)
    expect(String(payload.client_id)).toMatch(/^[A-Za-z0-9_-]{8}$/)
    expect(successLogs[0] ?? '').not.toContain(clientId)
  })

  it('a stale duplicate after the reuse window fails with a precise invalid_grant when upstream reuse is disabled', async () => {
    const clock = createTestClock()
    const harness = createSupabaseShapedHarness()
    const app = createApp(harness.service, clock)
    const clientId = await registerClient(app)
    const first = await completeAuthorization(app, clientId)
    await refreshRequest(app, clientId, first.refreshToken)

    // Past the server reuse window the same wrapper is presented again; with
    // the Supabase reuse interval still 0 the rotated-out token is truly dead.
    clock.tick(11_000)
    const errorSpy = vi.spyOn(console, 'error')
    const stale = await refreshRequest(app, clientId, first.refreshToken)
    expect(stale.status).toBe(400)
    const body: unknown = await stale.json()
    expect(body).toMatchObject({ error: 'invalid_grant' })
    // Precise description carries the upstream GoTrue message, not a generic one.
    expect(stringProperty(body, 'error_description')).toContain(REFRESH_NOT_FOUND_MESSAGE)

    const failureLogs = logCalls(errorSpy, TOKEN_ENDPOINT_FAILURE_PREFIX)
    expect(failureLogs).toHaveLength(1)
    const payload = parsedLogPayload(failureLogs[0] ?? '', TOKEN_ENDPOINT_FAILURE_PREFIX)
    expect(String(payload.error_description)).toContain(REFRESH_NOT_FOUND_MESSAGE)
  })

  it('a stale duplicate inside the upstream reuse interval still returns the current session', async () => {
    const clock = createTestClock()
    const harness = createSupabaseShapedHarness(10_000)
    const app = createApp(harness.service, clock)
    const clientId = await registerClient(app)
    const first = await completeAuthorization(app, clientId)
    const rotated = await responseTokens(await refreshRequest(app, clientId, first.refreshToken))
    expect(rotated.accessToken).toBe('access-token-2')

    // Past the server-side window, but inside the Supabase Auth reuse interval:
    // GoTrue answers the rotated-out token with the CURRENT session, so the
    // client heals instead of losing the connection.
    clock.tick(11_000)
    const healed = await refreshRequest(app, clientId, first.refreshToken)
    expect(healed.status).toBe(200)
    const healedBody = await responseTokens(healed)
    expect(healedBody.accessToken).toBe('access-token-2')
  })

  it('a truly revoked session returns invalid_grant with a precise error_description', async () => {
    const harness = createSupabaseShapedHarness()
    const app = createApp(harness.service)
    const clientId = await registerClient(app)
    const first = await completeAuthorization(app, clientId)
    harness.revokeSession()

    const attempt = await refreshRequest(app, clientId, first.refreshToken)
    expect(attempt.status).toBe(400)
    const body: unknown = await attempt.json()
    expect(body).toMatchObject({ error: 'invalid_grant' })
    expect(stringProperty(body, 'error_description')).toContain(REFRESH_NOT_FOUND_MESSAGE)
  })
})

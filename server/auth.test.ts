import { describe, expect, it } from 'vitest'
import { bearerToken, createSupabaseAuthenticator } from './auth.js'

const userId = '00000000-0000-4000-8000-000000000006'

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

describe('bearer authentication', () => {
  it('parses bearer tokens and rejects malformed authorization values', () => {
    expect(bearerToken('Bearer rotated-token')).toBe('rotated-token')
    expect(bearerToken('bearer another-token')).toBe('another-token')
    expect(() => bearerToken(undefined)).toThrowError(/bearer token is required/)
    expect(() => bearerToken('Basic credentials')).toThrowError(/bearer token is required/)
  })

  it('preserves the validated bearer token when calling Supabase Auth', async () => {
    const authorizations: Array<string | null> = []
    const fetchMock = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      const request = input instanceof Request
        ? new Request(input, init)
        : new Request(input.toString(), init)
      authorizations.push(request.headers.get('authorization'))
      return Promise.resolve(jsonResponse({ id: userId, email: 'test@example.com' }))
    }
    fetchMock.preconnect = (): void => undefined
    const authenticate = createSupabaseAuthenticator({
      supabaseUrl: 'https://morsel.test',
      anonKey: 'test-anon-key',
      fetch: fetchMock,
    })

    await expect(authenticate('rotated-token')).resolves.toMatchObject({
      userId,
      email: 'test@example.com',
      token: 'rotated-token',
      authInfo: { token: 'rotated-token' },
    })
    expect(authorizations).toContain('Bearer rotated-token')
  })

  it('maps Supabase auth failures and missing emails to authentication_failed', async () => {
    const failingFetch = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      void input
      void init
      return Promise.resolve(jsonResponse({ error: 'invalid_token', error_description: 'expired token' }, 401))
    }
    failingFetch.preconnect = (): void => undefined
    const failingAuthenticate = createSupabaseAuthenticator({
      supabaseUrl: 'https://morsel.test',
      anonKey: 'test-anon-key',
      fetch: failingFetch,
    })
    await expect(failingAuthenticate('expired-token')).rejects.toMatchObject({ code: 'authentication_failed' })

    const missingEmailFetch = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      void input
      void init
      return Promise.resolve(jsonResponse({ id: userId }))
    }
    missingEmailFetch.preconnect = (): void => undefined
    const missingEmailAuthenticate = createSupabaseAuthenticator({
      supabaseUrl: 'https://morsel.test',
      anonKey: 'test-anon-key',
      fetch: missingEmailFetch,
    })
    await expect(missingEmailAuthenticate('valid-without-email')).rejects.toMatchObject({ code: 'authentication_failed' })
  })
})

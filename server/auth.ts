import { createClient } from '@supabase/supabase-js'
import type { AuthInfo } from '@modelcontextprotocol/sdk/server/auth/types.js'
import { MorselError } from './errors.js'

export interface AuthenticatedUser {
  userId: string
  email: string
  token: string
  authInfo: AuthInfo
}

export type Authenticate = (token: string) => Promise<AuthenticatedUser>

export function bearerToken(authorization: string | undefined): string {
  if (authorization === undefined) {
    throw new MorselError('authentication_failed', 'a bearer token is required')
  }
  const match = /^Bearer\s+(\S+)$/i.exec(authorization.trim())
  if (match?.[1] === undefined) {
    throw new MorselError('authentication_failed', 'a bearer token is required')
  }
  return match[1]
}

export interface SupabaseAuthenticatorOptions {
  supabaseUrl: string
  anonKey: string
  fetch?: typeof fetch
}

export function createSupabaseAuthenticator(options: SupabaseAuthenticatorOptions): Authenticate {
  return async (token: string): Promise<AuthenticatedUser> => {
    const client = createClient(options.supabaseUrl, options.anonKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
        detectSessionInUrl: false,
      },
      global: {
        headers: {
          Authorization: `Bearer ${token}`,
        },
        fetch: options.fetch,
      },
    })
    const result = await client.auth.getUser(token)
    if (result.error !== null) {
      throw new MorselError('authentication_failed', 'bearer token could not be validated', result.error)
    }
    const userId = result.data.user.id
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)) {
      throw new MorselError('authentication_failed', 'validated user id is not a UUID')
    }
    const email = result.data.user.email
    if (typeof email !== 'string' || email.trim() === '') {
      throw new MorselError('authentication_failed', 'validated user has no email')
    }
    return {
      userId,
      email: email.trim(),
      token,
      authInfo: {
        token,
        clientId: 'morsel-bearer',
        scopes: [],
        extra: { userId },
      },
    }
  }
}
